# Gamer Mode for Noctalia

`nomadcxx/gamermode` puts live CPU, RAM and GPU numbers on the Noctalia bar, and adds a
one-click gamer mode that suspends background resource hogs — then restores exactly what
it stopped, no more and no less.

> Requires Noctalia v5 and plugin API 19. Noctalia v4 uses a different QML plugin format
> and will not list or load this source.

Metrics come from the shell's own system monitor (`noctalia.systemStats()`), which reads
NVIDIA cards through NVML in-process. Nothing is spawned per poll, and AMD/Intel GPUs are
covered wherever the shell supports them.

## Requirements

`pgrep` and `pkill` (procps) for process targets, `systemctl` for unit targets, `docker`
for container targets, and `powerprofilesctl` (power-profiles-daemon) for power switching.
Each is only needed if you actually target that kind — a missing tool disables the
matching feature and is logged rather than failing the toggle.

## Install

Add this repository as a custom plugin source in Noctalia:

1. Open **Settings → Plugins → Sources**.
2. Choose **Add custom repository**.
3. Enter `https://github.com/Nomadcxx/noctalia-gamermode`.
4. Open **Settings → Plugins → Install** and select **Gamer Mode**.

Then add the **Gamer Mode** widget to a bar section in **Settings → Bar**.

Adding a source is a settings-window action; the `plugins` IPC surface covers only
listing and enabling:

```sh
noctalia msg plugins list
noctalia msg plugins enable nomadcxx/gamermode
```

## Using it

- **Bar glyph** — accented while gamer mode is on. The tooltip carries the live numbers:
  `CPU 25% 59°C | RAM 10.9G | GPU 18% 61°C | VRAM 2.5G`.
- **Left click** — toggles gamer mode, or opens the panel, depending on `click_action`.
- **Panel** — metric bars, the power-profile selector, and the list of what is currently
  suspended.

From a script or a keybind:

```sh
noctalia msg plugin nomadcxx/gamermode:service all toggle
noctalia msg plugin nomadcxx/gamermode:service all enable
noctalia msg plugin nomadcxx/gamermode:service all disable
```

## Settings

| Setting | Type | Default | Notes |
|---|---|---|---|
| `glyph` | glyph | `device-gamepad-2` | Bar icon. Must name a glyph from the shell's registry. |
| `click_action` | select | `toggle` | `toggle` or `open_panel`. |
| `poll_interval` | select | `3` | Seconds between metric updates: 2, 3 or 5. |
| `profile` | select | `light` | Which suspend profile a toggle applies. |
| `auto_performance` | bool | `true` | Switch to the `performance` power profile while on, and hand the previous one back on disable. |
| `show_temps` | bool | `true` | Include temperatures in the tooltip and panel. |
| `targets` | string (advanced) | *(built-in defaults)* | JSON target list, see below. |

The suspend profile is a setting rather than a panel control: plugins can read their own
settings but not write them, so the panel shows the active profile read-only with a button
through to the settings window.

## The target list

`targets` is a JSON array. Each entry needs a `match`, a `kind`, the `profiles` it belongs
to, and optionally an `action`:

```json
[
  {"match": "awww-daemon",    "kind": "process",        "action": "freeze", "profiles": ["light", "heavy"]},
  {"match": "qbittorrent",    "kind": "process",        "action": "freeze", "profiles": ["light", "heavy"]},
  {"match": "ollama.service", "kind": "system-service",  "action": "stop",  "profiles": ["light", "heavy"]},
  {"match": "fstrim.timer",   "kind": "system-timer",    "action": "stop",  "profiles": ["light", "heavy"]},
  {"match": "brave",          "kind": "process",         "action": "freeze","profiles": ["heavy"]},
  {"match": "jellyfin.service","kind": "system-service", "action": "stop",  "profiles": ["heavy"]}
]
```

Leaving the setting empty uses the built-in defaults: 173 entries across both profiles (94
in `light`). Breadth is close to free — a target that is not running probes as `down`, so
it is never touched and never restored. An entry for software you do not have costs one
`pgrep`.

### `stop` vs `freeze`

`action` defaults to `stop` if omitted.

| | `stop` | `freeze` |
|---|---|---|
| Mechanism | `pkill` / `systemctl stop` / `docker stop` | `SIGSTOP` / `docker pause` |
| Frees RAM | ✅ | ❌ pages stay resident |
| Frees VRAM | ✅ | ❌ |
| Stops CPU use | ✅ | ✅ completely |
| Stops disk I/O | ✅ | ✅ completely |
| Loses state | ✅ shut down | ❌ resumes exactly |
| Restartable | units and containers only | always |

Choose `freeze` for anything you will come back to — a browser, an editor, a wallpaper
daemon. Choose `stop` when you need the memory back, which is the only reason a local model
runtime like `ollama` must be stopped rather than frozen: freezing keeps every VRAM page
allocated.

Network connections drop while a target is frozen, which is usually what you want for a
torrent client and usually not what you want for a chat app.

### Kinds

| `kind` | Probe | `stop` | Start | `freeze` | Thaw |
|---|---|---|---|---|---|
| `process` | `pgrep -x` | `pkill -x` | *(none — see below)* | `pkill -STOP -x` | `pkill -CONT -x` |
| `user-service` | `systemctl --user is-active` | `systemctl --user stop` | `systemctl --user start` | `systemctl --user kill --kill-whom=all -s SIGSTOP` | same with `SIGCONT` |
| `system-service` | `systemctl is-active` | `sudo -n systemctl stop` | `sudo -n systemctl start` | `sudo -n systemctl kill --kill-whom=all -s SIGSTOP` | same with `SIGCONT` |
| `user-timer` | `systemctl --user is-active` | `systemctl --user stop` | `systemctl --user start` | *(invalid)* | *(invalid)* |
| `system-timer` | `systemctl is-active` | `sudo -n systemctl stop` | `sudo -n systemctl start` | *(invalid)* | *(invalid)* |
| `container` | `docker inspect -f '{{.State.Running}}'` | `docker stop` | `docker start` | `docker pause` | `docker unpause` |

`match` is matched exactly (`pgrep -x`), not as a substring or a pattern. Values are
shell-quoted, and a `match` containing a newline, carriage return or NUL is rejected at
parse time rather than escaped.

If the setting is not valid JSON, or every entry in it is invalid, the built-in defaults are
used and the reason is logged. Individually invalid entries are dropped and the rest of the
list is still honoured — so one typo costs you one target, not the whole feature.

### Timers, and why stopping a service is not enough

Stopping `foo.service` does nothing about `foo.timer` re-firing it five minutes into your
session. Scheduled work therefore needs its own target. On a stock Arch install
`fstrim.timer`, `smartd.timer`, `paccache.timer` and the package-cache timers are all
enabled, and every one of them is a mid-game I/O stall.

**The `.timer` suffix is mandatory** for the timer kinds. `systemctl is-active fstrim`
silently resolves to `fstrim.service` — the wrong unit — so an entry without the suffix is
rejected at parse time.

### Processes are not restarted

There is deliberately no start command for `kind: "process"`. A bare process name carries
no argv, no environment and no working directory, so the plugin cannot honestly relaunch
one. `process` with `action: "stop"` is therefore **unrecoverable**; it is allowed, but the
plugin logs a warning, and every shipped process default uses `freeze` instead. If you need
something brought back, target the unit or container that supervises it.

### Protected targets

Some targets can never be suspended, whatever your config says. Acting on them would end
your session, kill your audio or network, or kill the game gamer mode exists to serve. Such
an entry is dropped at parse time with a logged reason, and the command builders refuse it
again at action time so a session file written by an older version cannot act on one either.

```
session/display  niri hyprland sway river wayfire labwc gnome-shell kwin_wayland
                 plasmashell Xorg Xwayland greetd sddm gdm
the shell        noctalia quickshell
audio            pipewire pipewire-pulse wireplumber pulseaudio
core IPC         systemd systemd-logind dbus-broker dbus-daemon elogind
network          NetworkManager wpa_supplicant iwd systemd-networkd
game stack       steam steamwebhelper gamescope wine wineserver proton lutris
                 heroic bottles gamemoded
```

Matching is case-insensitive and ignores a `.service`/`.timer`/`.socket` suffix, so `Steam`,
`steam` and `steam.service` are all refused.

**This list is not overridable.** The cost of a wrong entry is a dead session or a killed
game, and an override flag is exactly the field someone copies from a forum post without
reading. If you genuinely need to act on one of these, use Feral GameMode's `start=`/`end=`
script hooks in `gamemode.ini` instead.

### System services need passwordless sudo

System units and timers are controlled with `sudo -n`, which fails immediately rather than
prompting — a bar click must never block on a password. Without a NOPASSWD rule those
targets are skipped and the failure is logged.

To allow them, add a sudoers drop-in with `sudo visudo -f /etc/sudoers.d/gamermode`:

```
youruser ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop sonarr.service, /usr/bin/systemctl start sonarr.service
```

List each unit you actually target. A blanket `systemctl *` rule would let anything that
can run as your user stop or start any system unit, so prefer the explicit list.

## Not in the defaults, on purpose

These are all reasonable targets for *someone*, and all bad defaults. Paste what you want
into `targets`.

**Voice chat** — freezing these kills voice mid-game, during the exact activity the plugin
serves.

```json
{"match": "discord", "kind": "process", "action": "freeze", "profiles": ["heavy"]},
{"match": "vesktop", "kind": "process", "action": "freeze", "profiles": ["heavy"]},
{"match": "slack", "kind": "process", "action": "freeze", "profiles": ["heavy"]},
{"match": "element-desktop", "kind": "process", "action": "freeze", "profiles": ["heavy"]}
```

**Music** — plenty of people game with music on.

```json
{"match": "spotify", "kind": "process", "action": "freeze", "profiles": ["heavy"]},
{"match": "spotifyd.service", "kind": "user-service", "action": "stop", "profiles": ["heavy"]},
{"match": "mpd.service", "kind": "user-service", "action": "stop", "profiles": ["heavy"]}
```

**Recording and streaming** — plenty of people stream the game they are playing.

```json
{"match": "obs", "kind": "process", "action": "freeze", "profiles": ["heavy"]},
{"match": "gpu-screen-recorder", "kind": "process", "action": "freeze", "profiles": ["heavy"]}
```

**Language runtimes** — `java`, `dotnet` and `node` burn plenty of CPU, and they are also
**game runtimes**. Minecraft and every PrismLauncher/MultiMC instance run as `java`; Unity
and .NET titles run as `dotnet`. Freezing them freezes the game. Only add these if you are
certain nothing you play uses them.

**Container and VM daemons** — too blunt. Stopping `docker.service` takes down every
container, and starting it again does not restore their previous states; stopping
`libvirtd` kills running guests. Target individual containers with `kind: "container"`
instead, which freezes and thaws cleanly via `docker pause`.

**Shared databases** — `postgresql`, `mysqld` and `redis` usually have other services
depending on them. `elasticsearch` and `opensearch` *are* shipped in `heavy`, because their
JVM heaps are typically the largest single RAM consumer on a dev box.

**Releasing VRAM without killing the daemon** — `ollama` can unload models while staying
up, which is gentler than stopping the service. There is no target kind for this; use a
Feral GameMode `start=` hook:

```ini
[custom]
start=/usr/bin/ollama stop --all
```

## Restore semantics

Enabling writes a session snapshot to the plugin data directory (`session.json`) recording,
for every target in the active profile, whether it was `running`/`active` or already down,
which `action` was applied — plus the power profile in effect and the kernel boot ID.

Disable runs two passes, because the two actions need different logic.

**`stop` targets** are probed again and started back **only if still down**:

- Something already stopped before you enabled gamer mode is never started for you.
- Something you restarted by hand while gamer mode was on is left alone.
- A missing unit or container is logged and skipped; restore never fails hard partway.

**`freeze` targets** are thawed **unconditionally**, with no probe. A frozen process still
appears in `pgrep`, so no probe could tell "still frozen" from "running" — but `SIGCONT` to
a process that is not stopped exits 0 and changes nothing. Thawing blind is therefore both
simpler and strictly safer than probing: it cannot misread a state, cannot stomp a manual
restart, and cannot leave something frozen because a probe failed to run.

The snapshot is on disk, so gamer mode survives a shell restart: reload Quickshell
mid-session and the panel still shows it as on, with the same suspend list, and disable
still restores correctly.

Enabling twice is a no-op. The second enable would otherwise re-probe and record the targets
it had just suspended as "was down", losing the information needed to restore them.

### After a reboot

A session file outlives a reboot, so the boot ID is compared at startup. If it differs, the
session is stale: nothing that was frozen still exists, and units that were stopped may have
come back on their own.

A stale session still gets a **full restore pass before being cleared** — a stopped unit that
is not `enabled` really is still down after a reboot, and putting it back is what you were
told would happen. Frozen targets died with the reboot, so their thaw is a harmless no-op.
This can mean a few `sudo -n systemctl start` calls shortly after login; they are logged.

Within the *same* boot a session is always kept, even if everything looks like it is running
— that is precisely the case where something may still be frozen and needs thawing. A
session written before this version carries no boot ID and is treated as current rather than
abandoning targets that may still be suspended.

## Limitations

- No process relaunch for `action: "stop"` (see above).
- `renice` is deliberately not offered. It looks like the safe middle ground and is not:
  with `RLIMIT_NICE=0`, which is the default, an unprivileged process can *lower* priority
  but never raise it back, so a renice would permanently degrade every process it touched.
  `freeze` is the reversible option instead. This is also why Feral GameMode requires
  membership in a `gamemode` group to renice at all.
- No I/O weighting for user units: cgroup v2 delegates `cpu memory pids` to the user
  manager, not `io`.
- No hover-rich panel: plugin API 19 has no hover callback for bar widgets.
- No per-core CPU breakdown and no top-process list in the panel.
- VRAM only where the shell reports it (NVML on NVIDIA).
- No compositor eye-candy toggling — that belongs to the compositor, not here.

Not built, but viable later: arming gamer mode automatically from Feral GameMode's
`com.feralinteractive.GameMode` D-Bus interface (it has a `ClientCount` property that emits
changes and a `GameRegistered` signal), and switching sched_ext schedulers through
`org.scx.Loader`.

## Tests

Run the whole suite from the repository root:

```sh
./run-tests.sh
```

`tests/helpers.lua` provides a `noctalia` mock backed by the real filesystem plus a JSON
codec, which lets the plugin sources be loaded and exercised under plain `lua`. The plugin
itself only ever touches the noctalia bindings: Luau's sandbox gives plugins no `io`, no
`os.execute`/`os.remove` and no `load`. `tests/sandbox.sh` fails the build if a plugin source
reaches for any of them, since they parse fine under plain `lua` and only break once the
shell loads them.

The safety-critical paths are held to a mutation bar: disabling the denylist at either check,
inverting the freeze/stop restore split, dropping the `.timer` suffix rule, letting a process
default use `stop`, or ignoring the boot ID must each make the suite fail.

## License

MIT
