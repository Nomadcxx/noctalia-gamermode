# GamerMode Plugin — Design

Date: 2026-07-30
Repo: https://github.com/Nomadcxx/noctalia-gamermode
Target: Noctalia V5 luau plugin API (`plugin_api = 19`), reference: `Nomadcxx/noctalia-gslapper`

## Purpose

A bar plugin that (1) shows live CPU/RAM/GPU performance at a glance and (2) provides a
one-click "gamer mode" that suspends resource-heavy processes, services, and containers —
then restores exactly what it stopped, no more, no less.

## Components

```
gamermode/
  plugin.toml        # metadata, settings schema, [[service]]/[[panel]]/[[widget]]
  service.luau       # metrics poller + game-mode engine (single file)
  panel.luau         # dropdown UI
  widget.luau        # glyph + live tooltip + click handlers
  icon.svg           # gamepad, currentColor strokes (catalog + future bar icon)
  translations/en.json
```

### widget.luau

- Glyph: gamepad (configurable via `glyph` setting, like gslapper). Accent-colored when
  gamer mode is active (if the API supports glyph tinting; otherwise swap glyph).
- Tooltip: live compact stats, refreshed via `barWidget.setTooltip` on state watch:
  `CPU 23% 58C · RAM 11.2G · GPU 18% 61C · VRAM 2.6G`
- `onClick`: toggle gamer mode.
- Panel open: right-click if plugin API supports it (VERIFY: no `onRightClick` seen in
  gslapper; fallback = `click_action` setting: `toggle` | `open_panel`).
- Hover-rich-panel is NOT possible in plugin_api 19 (no hover callback). Future shell
  addition; out of scope for v1.

### service.luau

Two responsibilities:

**Metrics poller** (interval via `noctalia.setUpdateInterval`, ~3s):
- CPU %: `/proc/stat` delta (same technique as rama-shell SystemUsage.qml)
- CPU temp: `sensors` (Tdie/Tctl/Package patterns)
- RAM: `/proc/meminfo` (MemTotal - MemAvailable)
- GPU util/temp: auto-detect vendor — `nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total`
  else sysfs `/sys/class/drm/card*/device/gpu_busy_percent` + sensors, else NONE
- VRAM (NVIDIA only in v1)
- Publishes `noctalia.state.set("metrics", {...})`

**Game-mode engine** (see below). Publishes `game_mode` state:
`{ enabled, profile, suspended = [...], power_profile }`

### panel.luau

Attached panel, ~420x560, `keyboard_focus = "none"`. Reads state via
`noctalia.state.watch`, calls service functions for actions.

Layout:
1. Header: glyph + title + master toggle (`ui.button` styled; no ui.toggle exists)
2. Performance: 4 rows of `ui.progress` bars (CPU, RAM, GPU, VRAM) with % and temp labels
3. Power profile: `ui.select` (power-saver / balanced / performance) -> `powerprofilesctl set`
4. Gamer-mode profile: `ui.select` (light / heavy)
5. Suspended section (visible when enabled): what was stopped, from snapshot
6. Footer: settings button (`onOpenSettings`)

## Game-mode engine

### Snapshot (`pluginDataDir/session.json`)

Written on enable, read on disable, deleted after successful disable. Survives shell
restarts (service re-publishes `enabled` state if file exists at startup).

```json
{
  "version": 1,
  "profile": "light",
  "power_profile_before": "balanced",
  "targets": [
    {"kind": "process",        "match": "gslapper",         "was": "running", "pids": [123, 124]},
    {"kind": "user-service",   "match": "spotifyd.service", "was": "active"},
    {"kind": "container",      "match": "kokoro-tts",       "was": "running"},
    {"kind": "system-service", "match": "ollama.service",   "was": "inactive"}
  ]
}
```

### Enable

For each target in the active profile's kill list:
1. Probe current state: `pgrep -x` / `systemctl --user is-active` /
   `docker inspect -f {{.State.Running}}` / `systemctl is-active`
2. Record in snapshot
3. Stop it (`pkill`, `systemctl --user stop`, `docker stop`, `sudo -n systemctl stop`)

Then `powerprofilesctl set performance` (record previous; skipped if `auto_performance`
setting is false). Idempotent: existing `session.json` => no-op.

### Disable

For each snapshot entry where `was` = running/active:
- Start back ONLY if still down (never stomp a manual restart)
- Missing units/containers: log, skip, continue — restore never fails hard

Restore previous power profile. Delete `session.json`.

### Kill-list config

One `advanced` JSON setting `targets`, prefilled defaults:

```json
[
  {"match": "gslapper",       "kind": "process",        "profiles": ["light", "heavy"]},
  {"match": "spotifyd.service","kind": "user-service",  "profiles": ["light", "heavy"]},
  {"match": "kokoro-tts",     "kind": "container",      "profiles": ["light", "heavy"]},
  {"match": "adb",            "kind": "process",        "profiles": ["light", "heavy"]},
  {"match": "sonarr.service", "kind": "system-service", "profiles": ["heavy"]},
  {"match": "radarr.service", "kind": "system-service", "profiles": ["heavy"]}
]
```

System services use `sudo -n`; skipped with logged warning without passwordless sudo
(document the sudoers NOPASSWD line in README). No password prompts from bar clicks.

### Profiles

- `light`: wallpaper/media-player-adjacent (gslapper, spotifyd, adb, TTS containers)
- `heavy`: light + media stack + dev servers (system services, more containers)
- Power profile is independent: selectable in panel; gamer mode auto-switches to
  `performance` on enable when `auto_performance` is true, restores on disable.

## Settings schema (plugin.toml)

| key | type | default | notes |
|---|---|---|---|
| glyph | glyph | gamepad-ish | bar icon |
| click_action | select | toggle | toggle / open_panel (fallback if no onRightClick) |
| poll_interval | select | 3 | seconds: 2 / 3 / 5 |
| profile | select | light | light / heavy |
| auto_performance | bool | true | switch to performance on enable |
| show_temps | bool | true | temps in panel + tooltip |
| targets | string (advanced) | (defaults above) | JSON kill-list |

## Error handling

- No nvidia-smi / unsupported GPU: GPU row shows "unsupported", metrics continue
- powerprofilesctl missing: power-profile row hidden
- docker missing: container targets skipped with log
- Malformed `targets` JSON: fall back to compiled-in defaults, log warning
- All shell-outs via `noctalia.runAsync` with output validation (no blind parsing)

## Testing

- `tests/` like gslapper's: luau unit tests for snapshot round-trip, target probing
  (mocked command results), JSON kill-list parsing, restore filtering (was/still-down)
- Manual: enable/disable with known services; kill -9 shell mid-mode, verify restore
  still possible on next start; verify idempotent enable

## v1 scope cuts (YAGNI)

- No hover panel (API limitation)
- No per-core CPU, no top-process kill list in panel
- No AMD/Intel VRAM (sysfs busy_percent only)
- No compositor eye-candy toggling (that's rama-shell GameMode.qml's job, Hyprland-only)
