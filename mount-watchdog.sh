#!/bin/bash
#
# mount-watchdog.sh — keep an SMB NAS share and a local SSD mounted for a Docker media stack,
# and self-heal when either drops (router/NAS reboot, USB sleep/wake).
#
# Driven by a per-user LaunchAgent on a 60s interval. Each run:
#   * verifies the NAS SMB mount is present AND responsive (stat probe; `ls` is TCC-blocked),
#   * verifies the local SSD volume is mounted,
#   * remounts whatever is lost, respectfully (TCP pre-check + exponential backoff),
#   * after a mount is restored, restarts the dependent containers so their binds re-attach,
#   * notifies via Notification Center + logs to ~/Library/Logs/mount-watchdog.log.
#
# Site-specific values (NAS host/user/share, SSD volume, container list, etc.) come from
# config.env next to this script. The NAS password is never here: it lives in the Keychain
# item named by KEYCHAIN_SERVICE and is read at mount time, passed to AppleScript via env.
#
set -u
export PATH=/usr/bin:/bin:/usr/sbin:/sbin

# ---- site config (see config.env / config.env.example) ----------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/config.env"
if [ ! -f "$CONFIG_FILE" ]; then
  echo "mount-watchdog: missing $CONFIG_FILE (copy config.env.example -> config.env and edit)" >&2
  exit 78   # EX_CONFIG
fi
# shellcheck source=/dev/null
. "$CONFIG_FILE"
: "${NAS_HOST:?set in config.env}" "${NAS_PORT:?}" "${NAS_USER:?}" "${NAS_SHARE:?}" \
  "${NAS_MOUNT:?}" "${SSD_VOL:?}" "${SSD_MOUNT:?}" "${DEPENDENT_CONTAINERS:?}" "${KEYCHAIN_SERVICE:?}"

# ---- behavioral constants ---------------------------------------------------------
BASE_BACKOFF=30                      # seconds
CAP_BACKOFF=600                      # seconds (10 min)

STATE_DIR="$HOME/Library/Application Support/mount-watchdog"
LOG="$HOME/Library/Logs/mount-watchdog.log"
LOG_MAX_BYTES=$((5 * 1024 * 1024))   # rotate at 5 MB

# docker (OrbStack) — LaunchAgent PATH won't include it, so resolve explicitly.
DOCKER=""
for d in /usr/local/bin/docker "$HOME/.orbstack/bin/docker" /opt/homebrew/bin/docker; do
  [ -x "$d" ] && { DOCKER="$d"; break; }
done

# ---------------------------------------------------------------------------- helpers
mkdir -p "$STATE_DIR" "$(dirname "$LOG")" 2>/dev/null
chmod 700 "$STATE_DIR" 2>/dev/null

now() { date +%s; }

log() {
  # rotate if the log has grown too large
  if [ -f "$LOG" ]; then
    local sz
    sz=$(stat -f%z "$LOG" 2>/dev/null || echo 0)
    [ "$sz" -gt "$LOG_MAX_BYTES" ] && mv -f "$LOG" "$LOG.1" 2>/dev/null
  fi
  printf '%s  %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$*" >> "$LOG"
}

notify() {  # notify <subtitle> <message>
  /usr/bin/osascript -e "display notification \"$2\" with title \"Mount Watchdog\" subtitle \"$1\"" \
    >/dev/null 2>&1 || true
}

# Run a command with a hard timeout (macOS has no coreutils `timeout`).
with_timeout() {  # with_timeout <seconds> <cmd> [args...]
  local secs="$1"; shift
  /usr/bin/perl -e 'alarm shift; exec @ARGV or exit 127' "$secs" "$@"
}

# --- per-target state (small files under STATE_DIR) -------------------------------
state_get() {  # state_get <target> <key> <default>
  local f="$STATE_DIR/$1.$2"
  if [ -f "$f" ]; then cat "$f"; else printf '%s' "$3"; fi
}
state_set() {  # state_set <target> <key> <value>
  printf '%s' "$3" > "$STATE_DIR/$1.$2"
}

mark_ok() {  # clear backoff for a target
  state_set "$1" fail 0
  state_set "$1" next 0
}

mark_fail() {  # increment failure count and schedule the next attempt (capped, jittered)
  local target="$1" fc delay i j
  fc=$(state_get "$target" fail 0)
  fc=$((fc + 1))
  delay=$BASE_BACKOFF
  for ((i = 1; i < fc; i++)); do
    delay=$((delay * 2))
    if [ "$delay" -ge "$CAP_BACKOFF" ]; then delay=$CAP_BACKOFF; break; fi
  done
  j=$(( (RANDOM % 41) - 20 ))            # -20%..+20% jitter
  delay=$(( delay + delay * j / 100 ))
  state_set "$target" fail "$fc"
  state_set "$target" next "$(( $(now) + delay ))"
  log "[$target] attempt failed (fail #$fc); next try in ${delay}s"
}

due() {  # is the target past its backoff window?
  local next; next=$(state_get "$1" next 0)
  [ "$(now)" -ge "$next" ]
}

mounted_at() {  # is something mounted exactly at this path?
  mount | grep -qF " on $1 "
}

# ---------------------------------------------------------------------------- docker
restart_dependents() {
  [ -n "${DEPENDENTS_RESTARTED:-}" ] && return 0   # at most once per run (NAS+SSD may both recover)
  if [ -z "$DOCKER" ]; then
    log "[NAS] docker binary not found; skipping container restarts"
    return 1
  fi
  if ! with_timeout 15 "$DOCKER" info >/dev/null 2>&1; then
    log "[NAS] OrbStack/docker not ready; skipping container restarts"
    return 1
  fi
  local c
  for c in $DEPENDENT_CONTAINERS; do
    if with_timeout 60 "$DOCKER" restart "$c" >/dev/null 2>&1; then
      log "[NAS] restarted container '$c'"
    else
      log "[NAS] could not restart container '$c' (absent or failed)"
    fi
  done
  DEPENDENTS_RESTARTED=1
}

# ---------------------------------------------------------------------------- NAS
nas_healthy() {
  mounted_at "$NAS_MOUNT" || return 1
  # TCC-safe liveness probe. A background launchd agent is NOT permitted to read
  # network-volume directory contents (`ls` => "Operation not permitted"), which would
  # falsely read as "unhealthy" and cause an unmount/remount churn loop. `stat` of the
  # mountpoint does a metadata round-trip to the server instead: it's allowed by TCC, and
  # a stale/hung session makes it time out (=> unhealthy) while a live mount returns at once.
  with_timeout 8 /usr/bin/stat -f '%N' "$NAS_MOUNT" >/dev/null 2>&1
}

tcp_up() {
  with_timeout 5 nc -z -G 2 -w 2 "$NAS_HOST" "$NAS_PORT" >/dev/null 2>&1
}

# Mount the SMB share the same way Finder does (DiskArbitration), so macOS auto-manages
# the /Volumes/xenolith mountpoint (created on mount, removed on unmount — no sudo, no
# reaping problem) and the mount is visible to the GUI session / OrbStack.
# The password is read from the dedicated Keychain item at runtime and handed to
# AppleScript via an environment variable — it never appears on the command line or on disk.
nas_mount() {
  local pw
  pw=$(security find-generic-password -w -s "$KEYCHAIN_SERVICE" -a "$NAS_USER" 2>/dev/null)
  if [ -z "$pw" ]; then
    log "[NAS] Keychain item '$KEYCHAIN_SERVICE' not found/readable — run setup-once.sh"
    notify "NAS setup needed" "Keychain credential missing; run setup-once.sh."
    return 1
  fi
  NAS_PW="$pw" with_timeout 30 /usr/bin/osascript \
    -e "mount volume \"smb://$NAS_HOST/$NAS_SHARE\" as user name \"$NAS_USER\" with password (system attribute \"NAS_PW\")" \
    >/dev/null 2>&1
  local rc=$?
  pw=""; unset pw
  return $rc
}

reconcile_nas() {
  local prev; prev=$(state_get NAS status unknown)

  if nas_healthy; then
    if [ "$prev" = "down" ]; then
      log "[NAS] healthy again at $NAS_MOUNT"
      restart_dependents
      notify "NAS restored" "Remounted $NAS_MOUNT; restarted media containers."
    fi
    mark_ok NAS
    state_set NAS status up
    return
  fi

  # Not healthy.
  if [ "$prev" != "down" ]; then
    log "[NAS] lost or stale at $NAS_MOUNT"
    notify "NAS lost" "$NAS_MOUNT is unavailable; attempting to remount."
    state_set NAS status down
  fi

  due NAS || return                       # respect backoff window

  if ! tcp_up; then
    log "[NAS] $NAS_HOST:$NAS_PORT not reachable yet; backing off"
    mark_fail NAS
    return
  fi

  # Server answers — clear any stale mount via DiskArbitration (keeps the /Volumes
  # mountpoint lifecycle managed by macOS), then remount Finder-style.
  if mounted_at "$NAS_MOUNT"; then
    log "[NAS] clearing stale mount at $NAS_MOUNT"
    with_timeout 20 diskutil unmount "$NAS_MOUNT" >/dev/null 2>&1 \
      || with_timeout 20 diskutil unmount force "$NAS_MOUNT" >/dev/null 2>&1
  fi

  log "[NAS] mounting smb://$NAS_HOST/$NAS_SHARE -> $NAS_MOUNT"
  nas_mount

  local i
  for ((i = 0; i < 20; i++)); do
    nas_healthy && break
    sleep 1
  done

  if nas_healthy; then
    log "[NAS] remounted successfully at $NAS_MOUNT"
    mark_ok NAS
    state_set NAS status up
    restart_dependents
    notify "NAS restored" "Remounted $NAS_MOUNT; restarted media containers."
  else
    log "[NAS] remount did not become healthy (server reachable — possible auth/SMB issue)"
    mark_fail NAS
  fi
}

# ---------------------------------------------------------------------------- SSD
ssd_attached() {
  with_timeout 10 diskutil info "$SSD_VOL" >/dev/null 2>&1
}

reconcile_ssd() {
  local prev; prev=$(state_get SSD status unknown)

  if mounted_at "$SSD_MOUNT"; then
    if [ "$prev" = "down" ]; then
      log "[SSD] mounted again at $SSD_MOUNT"
      restart_dependents
      notify "SSD restored" "$SSD_MOUNT is mounted again; restarted media containers."
    fi
    mark_ok SSD
    state_set SSD status up
    return
  fi

  if [ "$prev" != "down" ]; then
    log "[SSD] not mounted at $SSD_MOUNT"
    state_set SSD status down
  fi

  due SSD || return

  if ! ssd_attached; then
    log "[SSD] volume '$SSD_VOL' not attached; backing off"
    [ "$prev" != "down" ] && notify "SSD missing" "Volume '$SSD_VOL' is not attached."
    mark_fail SSD
    return
  fi

  log "[SSD] mounting volume '$SSD_VOL'"
  if with_timeout 30 diskutil mount "$SSD_VOL" >/dev/null 2>&1 && mounted_at "$SSD_MOUNT"; then
    log "[SSD] mounted successfully at $SSD_MOUNT"
    mark_ok SSD
    state_set SSD status up
    restart_dependents
    notify "SSD restored" "$SSD_MOUNT is mounted again; restarted media containers."
  else
    log "[SSD] mount attempt failed"
    mark_fail SSD
  fi
}

# ---------------------------------------------------------------------------- main
reconcile_nas
reconcile_ssd
