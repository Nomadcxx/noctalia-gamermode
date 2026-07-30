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
| `targets` | string (advanced) | *(built-in defaults)* | JSON kill list, see below. |

The suspend profile is a setting rather than a panel control: plugins can read their own
settings but not write them, so the panel shows the active profile read-only with a button
through to the settings window.

## The kill list

`targets` is a JSON array. Each entry needs a `match`, a `kind`, and the `profiles` it
belongs to:

```json
[
  {"match": "gslapper",        "kind": "process",        "profiles": ["light", "heavy"]},
  {"match": "spotifyd.service","kind": "user-service",   "profiles": ["light", "heavy"]},
  {"match": "adb",             "kind": "process",        "profiles": ["light", "heavy"]},
  {"match": "kokoro-tts",      "kind": "container",      "profiles": ["light", "heavy"]},
  {"match": "sonarr.service",  "kind": "system-service", "profiles": ["heavy"]},
  {"match": "radarr.service",  "kind": "system-service", "profiles": ["heavy"]}
]
```

That is also the built-in default. Leaving the setting empty uses it.

| `kind` | Probe | Stop | Start |
|---|---|---|---|
| `process` | `pgrep -x` | `pkill -x` | *(none — see below)* |
| `user-service` | `systemctl --user is-active` | `systemctl --user stop` | `systemctl --user start` |
| `system-service` | `systemctl is-active` | `sudo -n systemctl stop` | `sudo -n systemctl start` |
| `container` | `docker inspect -f '{{.State.Running}}'` | `docker stop` | `docker start` |

`match` is matched exactly (`pgrep -x`), not as a substring or a pattern. Values are
shell-quoted, and a `match` containing a newline, carriage return or NUL is rejected at
parse time rather than escaped.

If the setting is not valid JSON, or every entry in it is invalid, the built-in defaults
are used and the reason is logged. Individually invalid entries are dropped and the rest of
the list is still honoured — so one typo costs you one target, not the whole feature.

### Processes are not restarted

There is deliberately no start command for `kind: "process"`. A bare process name carries
no argv, no environment and no working directory, so the plugin cannot honestly relaunch
one. If you need something brought back, target the user unit or container that supervises
it instead of the process.

### System services need passwordless sudo

System units are stopped and started with `sudo -n`, which fails immediately rather than
prompting — a bar click must never block on a password. Without a NOPASSWD rule those
targets are skipped and the failure is logged.

To allow them, add a sudoers drop-in with `sudo visudo -f /etc/sudoers.d/gamermode`:

```
youruser ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop sonarr.service, /usr/bin/systemctl start sonarr.service
```

List each unit you actually target. A blanket `systemctl *` rule would let anything that
can run as your user stop or start any system unit, so prefer the explicit list.

## Restore semantics

Enabling writes a session snapshot to the plugin data directory
(`session.json`) recording, for every target in the active profile, whether it was
`running`/`active` or already down — plus the power profile in effect at the time.

Disabling walks that snapshot and, for each target that **was up when gamer mode started**,
probes it again and starts it back **only if it is still down**. That means:

- Something already stopped before you enabled gamer mode is never started for you.
- Something you restarted by hand while gamer mode was on is left alone.
- A missing unit or container is logged and skipped; restore never fails hard partway.

The snapshot is on disk, so gamer mode survives a shell restart: reload Quickshell
mid-session and the panel still shows it as on, with the same suspend list, and disable
still restores correctly.

Enabling twice is a no-op. The second enable would otherwise re-probe and record the
targets it had just suspended as "was down", losing the information needed to restore
them.

## Limitations

- No process relaunch (see above).
- No hover-rich panel: plugin API 19 has no hover callback for bar widgets.
- No per-core CPU breakdown and no top-process list in the panel.
- VRAM only where the shell reports it (NVML on NVIDIA).
- No compositor eye-candy toggling — that belongs to the compositor, not here.

## Tests

Run the whole suite from the repository root:

```sh
./run-tests.sh
```

`tests/helpers.lua` provides a `noctalia` mock backed by the real filesystem plus a JSON
codec, which lets the plugin sources be loaded and exercised under plain `lua`. The plugin
itself only ever touches the noctalia bindings: Luau's sandbox gives plugins no `io`, no
`os.execute`/`os.remove` and no `load`.

## License

MIT
