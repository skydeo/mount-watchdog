# drive-mounter — keep a NAS share + local SSD mounted for a Docker media stack

A per-user macOS LaunchAgent that keeps two mounts alive and self-heals when they drop
(router/NAS reboot, USB sleep/wake):

- **NAS (SMB):** `//$NAS_USER@$NAS_HOST/$NAS_SHARE` → `$NAS_MOUNT`
- **Local SSD (APFS):** volume `$SSD_VOL` → `$SSD_MOUNT`

When either is restored, the containers in `$DEPENDENT_CONTAINERS` are restarted so their
binds re-attach (OrbStack doesn't re-attach a replaced mount on its own).

## Configuration — where the site-specific values live
All host/user/share/volume names, the container list, the Keychain item name, and the
LaunchAgent label live in **`config.env`**, which is **gitignored**. The repo ships only
**`config.env.example`** with placeholders.

```sh
cp config.env.example config.env
$EDITOR config.env          # set NAS_HOST/NAS_USER/NAS_SHARE, SSD_VOL, containers, etc.
```

`install.sh` deploys `config.env` next to the script and **generates** the LaunchAgent plist
from `$HOME` + `AGENT_LABEL` — so nothing in the tree hardcodes your username or paths.

## Files
| File | Committed? | Role |
|---|---|---|
| `mount-watchdog.sh` | yes | the watchdog (deployed to `~/Library/Application Support/mount-watchdog/`) |
| `config.env.example` | yes | template for site config |
| `config.env` | **no (gitignored)** | your real site config |
| `setup-once.sh` | yes | one-time: stores the NAS password in the Keychain |
| `install.sh` | yes | deploy script+config, generate plist, (re)load the agent — **re-run after edits** |

> The executable must live under `~/Library`, **not** `~/Documents` — macOS TCC blocks
> launchd from executing scripts in `~/Documents`/`~/Desktop`/`~/Downloads`.

## Install / update
```sh
cp config.env.example config.env && $EDITOR config.env   # once
bash setup-once.sh                                        # once: type NAS password (hidden). No sudo.
bash install.sh                                           # deploy + load. Re-run after editing script or config.
```

## How it works (and why it's built this way)
- **Mount method = Finder-style DiskArbitration** (`osascript … mount volume … with password`),
  not `mount_smbfs`. macOS then manages the mountpoint (created on mount, removed on unmount) —
  no sudo and no "mountpoint reaped on unmount" problem; the mount is visible to OrbStack.
- **Password = dedicated Keychain item** (`$KEYCHAIN_SERVICE`, account `$NAS_USER`, created
  with `-A`). Read at mount time and passed to AppleScript via the `NAS_PW` env var — never in
  `ps`/argv, never on disk. (The login-Keychain GUI auto-mount path does not authenticate
  silently from an agent, so a dedicated item is used.)
- **Health probe = `stat` on the mountpoint, not `ls`.** A background launchd agent is **not
  permitted by TCC to read network-volume directory contents** (`ls` → "Operation not
  permitted"), which would falsely read as unhealthy and cause an unmount/remount churn loop.
  `stat` does a metadata round-trip (allowed by TCC) that still times out on a stale mount.
- **Respectful retry:** TCP pre-check before any mount; per-target exponential backoff
  (30 s·2ⁿ, cap 600 s, ±20 % jitter); notifications only on state transitions.

## Operate
```sh
LABEL=$(. ./config.env; echo "$AGENT_LABEL")

launchctl print gui/$(id -u)/$LABEL | grep -E 'state|runs|last exit'   # status
tail -f ~/Library/Logs/mount-watchdog.log                              # watch it work
launchctl kickstart -k gui/$(id -u)/$LABEL                             # force a check
launchctl bootout   gui/$(id -u)/$LABEL                                # stop

# set / update the NAS password later (account = NAS_USER, service = KEYCHAIN_SERVICE)
security add-generic-password -U -A -s "$KEYCHAIN_SERVICE" -a "$NAS_USER" -w
```

State is in `~/Library/Application Support/mount-watchdog/{NAS,SSD}.{status,fail,next}`;
logs in `~/Library/Logs/mount-watchdog*.log` (auto-rotated at 5 MB).

## Tested
- NAS unmount → remounted in ~4 s, dependent containers restarted, `/data` repopulated.
- SSD force-unmount (simulated USB drop) → remounted in ~1 s, containers restarted.
- Steady state: no churn; both targets `up`.
