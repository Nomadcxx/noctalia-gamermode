# GamerMode Hardening — Design

Date: 2026-07-30
Repo: https://github.com/Nomadcxx/noctalia-gamermode
Builds on: `docs/plans/2026-07-30-gamermode-design.md` (v1 design), implemented in commits
`b474faa`..`3f0579a`.

## Problem

v1 shipped with defaults drawn from one developer's machine (`gslapper`, `kokoro-tts`,
`spotifyd.service`, `sonarr.service`, `radarr.service`, `adb`) and three structural gaps:

1. **No protection against catastrophic targets.** Nothing stops
   `{"match":"niri","kind":"process"}` from running `pkill -x niri` and killing the
   session, or a `pipewire` entry from killing audio, or a `steam` entry from killing the
   game gamer mode exists to serve.
2. **`kind: process` + stop is unrecoverable.** There is no start command for a bare
   process, so the shipped `gslapper` and `adb` defaults were killed and never restored.
3. **Scheduled work is untouchable.** Stopping `foo.service` does not stop `foo.timer`
   from re-firing it minutes later. On the development machine `fstrim.timer`,
   `smartd.timer`, `paccache`-class timers and `pamac-cleancache.timer` are all enabled —
   every one of them a mid-game I/O stall the plugin cannot currently prevent.

A fourth defect surfaced from prior art: **the session never goes stale.** `session.json`
survives a reboot, enabled units come back on their own, and the panel then reports gamer
mode as ON indefinitely over a suspend list of processes that are all running.

## Prior art considered

| Source | What it does | What we take |
|---|---|---|
| Feral GameMode | CPU governor, platform profile, renice, ioprio, SCHED_ISO, split-lock, GPU perf level, core parking, X3D cache. **Never stops a process** — priority only. Requires `gamemode` group for renice. | Its refusal to kill is the right instinct. We adopt a reversible middle path (freeze) rather than its renice, because renice is not reversible for us (below). |
| JaKooLit `Hyprland-Dots` `GameMode.sh` | Compositor eye candy (animations, blur, shadows, gaps, rounding, forced opacity). Its one process action is `swww kill`. Restores via `hyprctl reload`. | Two things: wallpaper daemons are a legitimate target class, and deriving state from the live system means it can never get stuck — which exposed our stale-session defect. |
| Hyprland/niri community gamemodes | Eye candy only. | Confirms v1's decision to leave compositor effects alone. |
| `ananicy-cpp`, `scx_loader`, `supergfxd` | Auto-nice daemon, sched_ext scheduler switching, GPU mode switching — all present on the dev machine. | Out of scope. Noted as future integration surface, not built here. |

### Why not renice

Measured on the target machine:

```
ulimit -e (RLIMIT_NICE) = 0
renice -n 15 -p PID   → old priority 1, new priority 15    ✓
renice -n 0  -p PID   → Permission denied                  ✗
final nice = 15 (permanent for the life of the process)
```

With `RLIMIT_NICE=0` an unprivileged process may lower priority but never raise it back.
Noctalia runs as the user. renice would therefore permanently degrade every process it
touched, violating the plugin's central promise — restore exactly what was changed.
Rejected.

`SIGSTOP`/`SIGCONT` was measured to round-trip cleanly (`T` → `S`), and `SIGCONT` to a
process that is not stopped exits 0 as a no-op. That property is load-bearing for the
restore design below.

## Scope

In: denylist, `action: stop|freeze`, timer kinds, generic default list, boot-ID staleness.

Out (explicitly, for a later round): Feral GameMode D-Bus auto-arm via `ClientCount` /
`GameRegistered`, `org.scx.Loader` scheduler switching, cgroup `CPUWeight` throttling,
compositor effect toggling, dry-run preview.

---

## 1. Never-touch denylist

A single flat set of lowercase names, one predicate, two call sites. Deliberately not
groups, not per-kind, not overridable.

```
session/display  niri hyprland sway river wayfire labwc gnome-shell kwin_wayland
                 plasmashell xorg xwayland greetd sddm gdm
the shell        noctalia quickshell
audio            pipewire pipewire-pulse wireplumber pulseaudio
core IPC         systemd systemd-logind dbus-broker dbus-daemon elogind
network          networkmanager wpa_supplicant iwd systemd-networkd
game stack       steam steamwebhelper gamescope wine wineserver proton lutris
                 heroic bottles gamemoded
```

**Matching.** The candidate is lowercased and any `.service` / `.timer` / `.socket`
suffix is stripped before the set lookup, so `Steam`, `steam`, `steam.service` and
`STEAM.SERVICE` all deny.

**Enforcement at two points**, because they fail differently:

- **Parse time** (`parseTargets`) — a denied entry is dropped and logged, exactly like an
  entry with a bad kind. This is what protects a user editing the `targets` setting.
- **Action time** (`probeCmd`/`stopCmd`/`startCmd`/`freezeCmd`/`thawCmd`) — the builders
  return nil for a denied match. This protects against a denied entry reaching an action
  by any path a future refactor might open, and against a stale `session.json` written
  before the denylist existed.

**Not overridable** is a deliberate call. The cost of a wrong entry is a dead session or
a killed game, and an override flag is precisely the field a user would copy from a forum
post without reading. Users with a genuine need have Feral GameMode's `start=`/`end=`
script hooks.

Not on the list, and why: xdg-desktop-portal (breaks file dialogs, not the session),
polkitd / gnome-keyring / ssh-agent / gpg-agent (annoying, recoverable),
nvidia-persistenced / supergfxd (GPU daemons, recoverable). Every entry retained has to
justify itself as session-fatal or game-fatal.

## 2. `action`: `stop` | `freeze`

A new optional target field. Absent means `stop`, so every existing config and the whole
v1 test suite keep their meaning.

Two new kinds arrive with it: `user-timer` and `system-timer`, rather than a single
`timer`. The kind is what encodes whether a command needs `sudo -n`, so a lone `timer`
would break the symmetry the `user-service` / `system-service` pair already establishes.

```json
{"match": "brave", "kind": "process", "action": "freeze", "profiles": ["heavy"]}
```

### Command matrix

Every command is shell-quoted through the existing `shellQuote`, and any match that fails
`validateShellValue` or hits the denylist yields nil.

| kind | probe | stop | start | freeze | thaw |
|---|---|---|---|---|---|
| `process` | `pgrep -x M` | `pkill -x M` | *(none)* | `pkill -STOP -x M` | `pkill -CONT -x M` |
| `user-service` | `systemctl --user is-active M` | `systemctl --user stop M` | `systemctl --user start M` | `systemctl --user kill --kill-whom=all -s SIGSTOP M` | `systemctl --user kill --kill-whom=all -s SIGCONT M` |
| `system-service` | `systemctl is-active M` | `sudo -n systemctl stop M` | `sudo -n systemctl start M` | `sudo -n systemctl kill --kill-whom=all -s SIGSTOP M` | `sudo -n systemctl kill --kill-whom=all -s SIGCONT M` |
| `user-timer` | `systemctl --user is-active M` | `systemctl --user stop M` | `systemctl --user start M` | *(invalid)* | *(invalid)* |
| `system-timer` | `systemctl is-active M` | `sudo -n systemctl stop M` | `sudo -n systemctl start M` | *(invalid)* | *(invalid)* |
| `container` | `docker inspect -f '{{.State.Running}}' M` | `docker stop M` | `docker start M` | `docker pause M` | `docker unpause M` |

`--kill-whom=all` is explicit rather than relying on systemd's default, which `systemctl
kill --help` does not state. Freezing a unit must reach every process in its cgroup, not
just the main one.

`docker pause` is the cgroup freezer, an exact match for freeze semantics.

### Restore semantics differ by action, and freeze is the simpler one

- **`stop` targets** keep v1's rule: restore only if the target was up at enable time
  **and** is still down now. Preserves "never stomp a manual restart."
- **`freeze` targets are thawed unconditionally.** No probe, no still-frozen check.
  `SIGCONT` to a running process is a verified no-op, and `docker unpause` on an unpaused
  container fails harmlessly and is logged. This is strictly safer than the probe path: it
  cannot mis-read a state, cannot stomp anything, and cannot leave a process frozen
  because a probe failed to start.

This means `restorePlan` splits into two passes rather than growing a conditional.

### Validation rules added at parse time

| Rule | Reason | On violation |
|---|---|---|
| `action` must be `stop` or `freeze` | typo protection | drop entry, log |
| timer kinds may not use `freeze` | a timer has no process to signal | drop entry, log |
| timer kinds require a `.timer` suffix on `match` | `systemctl is-active fstrim` resolves to `fstrim.service` — silently the wrong unit | drop entry, log |
| `process` + `stop` is permitted but warned | unrecoverable: no argv to relaunch from | keep entry, log warning |

The last rule is a warning rather than a rejection because a user may genuinely want a
fire-and-forget kill; the defaults simply never rely on it.

## 3. Default target list

Design rule discovered while building it: **`kind: process` + `stop` is unrecoverable, so
every bare-process default uses `freeze`, and `stop` is reserved for units, timers and
containers** — the things that can actually be started again.

Breadth is close to free: a target that is not running probes as `down`, so it is never
acted on and never restored. An entry for absent software costs one `pgrep`. The risk is
never "too many entries", it is "an entry that is present but should not be touched",
which is what §1 exists for.

### light — background only

Nothing the user could be interacting with; nothing that produces sound, voice or video
they would want during a game.

| Category | Matches | kind | action |
|---|---|---|---|
| Wallpaper daemons | `awww-daemon` `swww-daemon` `hyprpaper` `swaybg` `wpaperd` `mpvpaper` `glpaper` `wbg` `oguri` `linux-wallpaperengine` `gslapper` | process | freeze |
| Torrent | `qbittorrent` `qbittorrent-nox` `transmission-daemon` `transmission-gtk` `deluged` `deluge-gtk` `rtorrent` `aria2c` `ktorrent` | process | freeze |
| Torrent units | `transmission.service` `qbittorrent-nox.service` `deluged.service` `aria2.service` | system-service | stop |
| Usenet | `sabnzbd` `sabnzbdplus` `nzbget` | process | freeze |
| Usenet units | `sabnzbd.service` `nzbget.service` | system-service | stop |
| Cloud sync | `syncthing` `dropbox` `nextcloud` `insync` `megasync` `onedrive` `maestral` `rclone` `seafile-applet` `owncloud` | process | freeze |
| Cloud sync units | `syncthing.service` `onedrive.service` | user-service | stop |
| Backup | `borg` `restic` `duplicati` `rsnapshot` `kopia` | process | freeze |
| Backup timers | `borgmatic.timer` `restic-backup.timer` `snapper-timeline.timer` `snapper-cleanup.timer` `duplicati.timer` | system-timer | stop |
| Indexers | `baloo_file` `baloo_file_extractor` `tracker-miner-fs-3` `tracker-extract-3` `recollindex` `updatedb` `plocate` | process | freeze |
| Indexer timers | `plocate-updatedb.timer` `updatedb.timer` `mlocate.timer` | system-timer | stop |
| Maintenance timers | `fstrim.timer` `smartd.timer` `paccache.timer` `pamac-cleancache.timer` `reflector.timer` `archlinux-keyring-wkd-sync.timer` `pacman-filesdb-refresh.timer` `systemd-tmpfiles-clean.timer` `man-db.timer` `dnf-makecache.timer` `snapd.refresh.timer` `flatpak-system-update.timer` `e2scrub_all.timer` | system-timer | stop |
| Update daemons | `packagekit.service` `pamac-daemon.service` `snapd.service` `unattended-upgrades.service` | system-service | stop |
| AI / LLM (VRAM) | `ollama.service` `localai.service` `comfyui.service` `open-webui.service` | system-service | stop |
| Antivirus | `clamav-daemon.service` `clamd.service` `clamav-freshclam.service` | system-service | stop |
| Antivirus timers | `clamav-freshclam.timer` `rkhunter.timer` | system-timer | stop |
| Telemetry / remote | `whoopsie.service` `apport.service` `abrtd.service` `teamviewerd.service` `anydesk.service` | system-service | stop |
| Phone / emulator | `adb` `scrcpy` | process | freeze |

AI runtimes are **service-kind only and `stop`**. VRAM releases only on a real stop, and
`process` + `stop` is unrecoverable — so the bare-process form is documented rather than
shipped. `ollama stop --all`, which unloads models without killing the daemon, is a README
example.

### heavy — light plus

| Category | Matches | kind | action |
|---|---|---|---|
| Browsers | `brave` `chrome` `google-chrome` `chromium` `firefox` `librewolf` `vivaldi-bin` `opera` `microsoft-edge` `thorium` `zen-browser` `waterfox` `qutebrowser` | process | freeze |
| IDEs / editors | `code` `codium` `code-oss` `cursor` `zed` `idea` `pycharm` `webstorm` `clion` `goland` `rider` `rustrover` `android-studio` `sublime_text` | process | freeze |
| Language servers | `rust-analyzer` `gopls` `clangd` `pylsp` `pyright` `typescript-language-server` `jdtls` `lua-language-server` `omnisharp` `ccls` | process | freeze |
| Builds / compilers | `cargo` `rustc` `gradle` `tsc` `webpack` `vite` `esbuild` `ninja` `make` `cc1plus` `ccache` `sccache` `distccd` | process | freeze |
| AI coding agents | `claude` `opencode` `codex` `aider` | process | freeze |
| CI runners | `gitlab-runner.service` `buildkite-agent.service` `jenkins.service` | system-service | stop |
| *arr stack | `sonarr.service` `radarr.service` `lidarr.service` `readarr.service` `prowlarr.service` `bazarr.service` `jackett.service` `jellyseerr.service` `overseerr.service` `ombi.service` `tautulli.service` | system-service | stop |
| Media servers | `jellyfin.service` `plexmediaserver.service` `emby-server.service` `audiobookshelf.service` `navidrome.service` `komga.service` `kavita.service` `photoprism.service` `calibre-server.service` | system-service | stop |
| JVM databases | `elasticsearch.service` `opensearch.service` | system-service | stop |

### Excluded from defaults, documented as examples

| Excluded | Why |
|---|---|
| `discord` `vesktop` `slack` `element-desktop` `teams-for-linux` `zoom` | Freezing these kills voice chat — during the exact activity the plugin serves. |
| `spotify` `spotifyd` `mpd` `mpv` `vlc` `strawberry` | People game with music on. |
| `obs` `gpu-screen-recorder` `wf-recorder` `wl-screenrec` | People stream their games. |
| `docker.service` `containerd.service` `podman.service` | Too blunt: takes down every container, and restarting the daemon does not restore container states. Target individual containers. |
| `libvirtd.service` `virtqemud.service` `VBoxSVC` `waydroid` `qemu-system-x86_64` | Kills running guests. |
| `postgresql.service` `mysqld.service` `redis.service` | Other services depend on them. |
| `java` `dotnet` `node` | **These are game runtimes, not just build tools.** Minecraft and every PrismLauncher/MultiMC instance run as `java`; Unity and .NET titles run as `dotnet`. Freezing them freezes the game. Any interpreter that both builds and runs games is unsafe as a default no matter how much CPU it burns. |

### Behaviour changes from v1 defaults

- `spotifyd.service` leaves the defaults (music during gaming).
- `adb` becomes `freeze` — it was previously killed unrecoverably.
- `gslapper` becomes `freeze` — same reason.
- `kokoro-tts` is replaced by the generic AI-service entries.

## 4. Stale-session detection by boot ID

`buildSnapshot` records `boot_id`, read from `/proc/sys/kernel/random/boot_id` via
`noctalia.readFile`.

On `init`, if a session exists and its `boot_id` differs from the current one, the machine
has rebooted. The service then **runs the normal restore pass and clears the session**,
ending with gamer mode reported as off.

Restoring rather than merely clearing preserves the promise: a `stop`-ed unit that is not
`enabled` really is still down after a reboot, and putting it back is what the user was
told would happen. Freeze targets are gone with the reboot, so their unconditional thaw is
a harmless no-op.

Within the *same* boot a session that looks stale is deliberately kept, because that is
precisely the case where something may still be frozen and needs thawing.

A snapshot with no `boot_id` (written by v1) is treated as current, not stale — its
targets may still be suspended, and inventing staleness would abandon them.

Trade-off accepted: this can issue `sudo -n systemctl start` calls during shell startup.
Bounded by the target count, and logged.

## 5. State and UI

`game_mode.suspended` entries gain `action`, so the panel can distinguish a frozen target
from a stopped one:

```lua
{ match = "brave", kind = "process", action = "freeze" }
```

The panel's suspended list renders the action, e.g. `brave (process, frozen)` vs
`ollama.service (system-service, stopped)`. No new panel controls.

## 6. Testing

New suites:

| Suite | Covers |
|---|---|
| `tests/denylist.lua` | Every denylist entry rejected at parse time; every command builder returns nil for a denied match; case and suffix normalisation (`Steam`, `steam.service`); a denied entry inside a stored snapshot cannot produce an action. |
| `tests/actions.lua` | Full command matrix, all kind × action pairs; freeze rejected for timer kinds; `.timer` suffix required; unknown `action` rejected; `process`+`stop` warned but kept; `action` defaults to `stop`. |
| `tests/staleness.lua` | Boot-ID mismatch runs restore then clears and reports off; matching boot ID keeps the session; absent `boot_id` treated as current; unreadable `/proc` boot id degrades to "current". |
| `tests/defaults.lua` | Every default entry passes its own validation; no default entry hits the denylist; no default `process` entry uses `stop`; every timer entry ends in `.timer`; heavy is a strict superset of light; every AI entry is service-kind. |

Extended: `tests/runtime.lua` gains a mixed stop+freeze enable/disable flow asserting
freeze targets are thawed without a probe and stop targets are not. `tests/panel.lua`
gains the action label. `tests/targets.lua` gains the new validation rules.

The nine existing suites must stay green unchanged, since `action` defaults to `stop`.

Mutation testing is the acceptance bar for the safety-critical parts: removing the
denylist check, inverting the freeze/stop restore split, and dropping the `.timer` suffix
requirement must each fail the suite.

## 7. Documentation

README gains: the `action` field and when to choose each, the full kind × action matrix,
the denylist and why it is not overridable, the `process`+`stop` unrecoverability warning,
the timer kinds and why stopping a service without its timer is insufficient, the excluded
categories as copy-paste examples, and the boot-ID restore behaviour.
