#!/bin/bash
#
# mount-watchdog.sh — keep an SMB NAS share and one or more local SSD volumes mounted for a
# Docker media stack, and self-heal when any of them drops (router/NAS reboot, USB sleep/wake).
#
# Driven by a per-user LaunchAgent on a 60s interval. Each run:
#   * verifies the NAS SMB mount is present AND responsive (stat probe; `ls` is TCC-blocked),
#   * verifies each configured local SSD volume is mounted,
#   * remounts whatever is lost, respectfully (TCP pre-check + exponential backoff),
#   * after a mount is restored, restarts only the containers that bind THAT mount, so their
#     binds re-attach — each container at most once per run, after all mounts are settled,
#   * notifies via Notification Center + logs to ~/Library/Logs/mount-watchdog.log.
#
# Site-specific values (NAS host/user/share, SSD volumes, per-target container lists, etc.)
# come from config.env next to this script. The NAS password is never here: it lives in the
# Keychain item named by KEYCHAIN_SERVICE and is read at mount time, passed to AppleScript
# via env.
#
# Runs under macOS /bin/bash 3.2: no associative arrays, no mapfile, no ${x,,}.
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
SSD_VOLUMES=()   # pre-declare so `${#SSD_VOLUMES[@]}` is safe under `set -u` if config omits it
# shellcheck source=/dev/null
. "$CONFIG_FILE"
: "${NAS_HOST:?set in config.env}" "${NAS_PORT:?}" "${NAS_USER:?}" "${NAS_SHARE:?}" \
  "${NAS_MOUNT:?}" "${KEYCHAIN_SERVICE:?}"

# NAS containers: NAS_CONTAINERS, or the legacy global DEPENDENT_CONTAINERS if it's unset.
NAS_CONTAINERS="${NAS_CONTAINERS-${DEPENDENT_CONTAINERS:-}}"

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
# <target> is a state key such as NAS or SSD-skydeo.xyz; it's only ever used in filenames.
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

mark_fail() {  # mark_fail <target> [log-tag] — bump failure count, schedule next try (capped, jittered)
  local target="$1" tag="${2:-$1}" fc delay i j
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
  log "[$tag] attempt failed (fail #$fc); next try in ${delay}s"
}

due() {  # is the target past its backoff window?
  local next; next=$(state_get "$1" next 0)
  [ "$(now)" -ge "$next" ]
}

mounted_at() {  # is something mounted exactly at this path?
  mount | grep -qF " on $1 "
}

# ---------------------------------------------------------------------------- SSD config
# SSD_VOLUMES entries are "volname|mountpoint|container container ...". Parsed into
# parallel indexed arrays (bash 3.2 has no associative arrays).
SSD_NAMES=(); SSD_MOUNTS=(); SSD_CTRS=()

if [ "${#SSD_VOLUMES[@]}" -eq 0 ] && [ -n "${SSD_VOL:-}" ] && [ -n "${SSD_MOUNT:-}" ]; then
  # Legacy single-SSD config: SSD_VOL / SSD_MOUNT, restarting DEPENDENT_CONTAINERS.
  SSD_VOLUMES=("$SSD_VOL|$SSD_MOUNT|${DEPENDENT_CONTAINERS:-}")
fi

for ((i = 0; i < ${#SSD_VOLUMES[@]}; i++)); do
  entry="${SSD_VOLUMES[$i]}"
  vol=""; mnt=""; ctrs=""
  IFS='|' read -r vol mnt ctrs <<< "$entry"
  if [ -z "$vol" ] || [ -z "$mnt" ]; then
    log "[config] skipping malformed SSD_VOLUMES entry #$((i + 1)): '$entry' (need volname|mountpoint|containers)"
    continue
  fi
  SSD_NAMES+=("$vol"); SSD_MOUNTS+=("$mnt"); SSD_CTRS+=("$ctrs")
done
unset entry vol mnt ctrs

if [ "${#SSD_NAMES[@]}" -eq 0 ]; then
  log "[config] no valid SSD volume configured (set SSD_VOLUMES, or legacy SSD_VOL + SSD_MOUNT)"
  echo "mount-watchdog: no valid SSD volume in $CONFIG_FILE (set SSD_VOLUMES)" >&2
  exit 78   # EX_CONFIG
fi

# ---------------------------------------------------------------------------- docker
# Restarts are deferred: targets that recover call queue_recovery, and run_recoveries restarts
# containers only after every mount has been reconciled. Otherwise a container shared by two
# targets that recover in the same run (e.g. fetch on Obsidian + Borealis) could be restarted
# after the first remount but before the second, and dedup would then skip it — leaving its
# second bind stale.
REC_TAGS=(); REC_CTRS=(); REC_SUBJ=(); REC_MSG=()

queue_recovery() {  # queue_recovery <tag> <containers> <notify-subtitle> <notify-message-prefix>
  REC_TAGS+=("$1"); REC_CTRS+=("$2"); REC_SUBJ+=("$3"); REC_MSG+=("$4")
}

RESTARTED=" "        # space-padded set of containers restarted this run
DOCKER_READY=""      # "" = not checked yet, 1 = ready, 0 = unavailable (cached for the run)
RESTART_RESULT=""    # set by restart_containers: human summary for the notification

docker_ready() {  # docker_ready <tag>
  if [ -z "$DOCKER_READY" ]; then
    if [ -z "$DOCKER" ]; then
      log "[$1] docker binary not found; skipping container restarts"
      DOCKER_READY=0
    elif ! with_timeout 15 "$DOCKER" info >/dev/null 2>&1; then
      log "[$1] OrbStack/docker not ready; skipping container restarts"
      DOCKER_READY=0
    else
      DOCKER_READY=1
    fi
  fi
  [ "$DOCKER_READY" = 1 ]
}

restart_containers() {  # restart_containers <tag> <space-separated containers>
  local tag="$1" list="$2" c done_list="" failed_list=""
  if [ -z "${list// /}" ]; then
    RESTART_RESULT="no containers to restart"
    return 0
  fi
  if ! docker_ready "$tag"; then
    RESTART_RESULT="containers not restarted (docker unavailable)"
    return 1
  fi
  for c in $list; do
    case "$RESTARTED" in
      *" $c "*)   # already restarted this run for another target — counts as done
        log "[$tag] container '$c' already restarted this run"
        done_list="$done_list $c"
        continue ;;
    esac
    if with_timeout 60 "$DOCKER" restart "$c" >/dev/null 2>&1; then
      log "[$tag] restarted container '$c'"
      RESTARTED="$RESTARTED$c "
      done_list="$done_list $c"
    else
      log "[$tag] could not restart container '$c' (absent or failed)"
      failed_list="$failed_list $c"
    fi
  done
  done_list="${done_list# }"; failed_list="${failed_list# }"
  if [ -n "$done_list" ]; then
    RESTART_RESULT="restarted ${done_list// /, }"
  else
    RESTART_RESULT="no containers restarted"
  fi
  [ -n "$failed_list" ] && RESTART_RESULT="$RESTART_RESULT; failed: ${failed_list// /, }"
  return 0
}

run_recoveries() {
  local i
  for ((i = 0; i < ${#REC_TAGS[@]}; i++)); do
    restart_containers "${REC_TAGS[$i]}" "${REC_CTRS[$i]}"
    notify "${REC_SUBJ[$i]}" "${REC_MSG[$i]}; $RESTART_RESULT."
  done
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
      queue_recovery NAS "$NAS_CONTAINERS" "NAS restored" "Remounted $NAS_MOUNT"
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
    queue_recovery NAS "$NAS_CONTAINERS" "NAS restored" "Remounted $NAS_MOUNT"
  else
    log "[NAS] remount did not become healthy (server reachable — possible auth/SMB issue)"
    mark_fail NAS
  fi
}

# ---------------------------------------------------------------------------- SSD
ssd_attached() {  # ssd_attached <volname>
  with_timeout 10 diskutil info "$1" >/dev/null 2>&1
}

reconcile_ssd() {  # reconcile_ssd <volname> <mountpoint> <containers>
  local vol="$1" mnt="$2" ctrs="$3"
  local key="SSD-$vol" tag="SSD:$vol"
  local prev; prev=$(state_get "$key" status unknown)

  if mounted_at "$mnt"; then
    if [ "$prev" = "down" ]; then
      log "[$tag] mounted again at $mnt"
      queue_recovery "$tag" "$ctrs" "SSD restored" "Volume '$vol' is mounted again at $mnt"
    fi
    mark_ok "$key"
    state_set "$key" status up
    return
  fi

  if [ "$prev" != "down" ]; then
    log "[$tag] not mounted at $mnt"
    state_set "$key" status down
  fi

  due "$key" || return

  if ! ssd_attached "$vol"; then
    log "[$tag] volume '$vol' not attached; backing off"
    [ "$prev" != "down" ] && notify "SSD missing" "Volume '$vol' is not attached."
    mark_fail "$key" "$tag"
    return
  fi

  log "[$tag] mounting volume '$vol'"
  if with_timeout 30 diskutil mount "$vol" >/dev/null 2>&1 && mounted_at "$mnt"; then
    log "[$tag] mounted successfully at $mnt"
    mark_ok "$key"
    state_set "$key" status up
    queue_recovery "$tag" "$ctrs" "SSD restored" "Volume '$vol' is mounted again at $mnt"
  else
    log "[$tag] mount attempt failed"
    mark_fail "$key" "$tag"
  fi
}

# ---------------------------------------------------------------------------- main
reconcile_nas
for ((i = 0; i < ${#SSD_NAMES[@]}; i++)); do
  reconcile_ssd "${SSD_NAMES[$i]}" "${SSD_MOUNTS[$i]}" "${SSD_CTRS[$i]}"
done
run_recoveries
