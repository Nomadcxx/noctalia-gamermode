# Bar Monitor — Design

Date: 2026-08-09
Repo: https://github.com/Nomadcxx/noctalia-gamermode
Issue: https://github.com/Nomadcxx/noctalia-gamermode/issues/1 (arg9244)
Builds on: `docs/plans/2026-07-30-gamermode-hardening-design.md`, shipped as v0.6.4 and merged
upstream in noctalia-dev/community-plugins#168 on 2026-07-31.
Ships as: **0.7.0**

> **Revised 2026-08-10, after live testing.** Sections 3 and 5 originally had the widget
> draw its own pill and reserve a fixed width per metric. Both were wrong, and section
> "Revision: the shell owns the pill" at the foot of this document records what replaced
> them and why. Read that before section 3.

## Problem

The plugin publishes a full metrics sample every poll and spends it on one glyph and a
tooltip. `netRxPerSec`, `netTxPerSec`, `swapPerc`, `load1/5/15` and `vramPerc` are all in
the published `metrics` table today and no bar surface reads them.

Issue #1 asks for a settings option to replace the gamepad glyph with a system-monitoring
readout, with more stats than the tooltip carries — network and gamer-mode status named
specifically. The attached screenshot shows an inline row: `1% 38° 8.4G 0% 55° 0.8G ↓548 ↑854`.

Noctalia already ships a `sysmon` bar widget (`src/shell/bar/widgets/sysmon_widget.cpp`)
that renders one stat per instance with a glyph, a text or graph display mode, and network
stats. Eight instances of it reproduce the screenshot. What it cannot do is report
gamer-mode state, because that state belongs to this plugin. The goal is therefore a
readout good enough to replace a row of `sysmon` instances outright, not one that sits
beside them.

## Decisions taken

Four questions were settled before design:

| Question | Decision |
|---|---|
| Packaging | A second `[[widget]]` entry, `monitor`, separate from the existing toggle |
| Metric selection | One bool per metric, order fixed by the plugin |
| Segment style | Glyph plus value, related segments grouped |
| Gamer-mode status | Accent the whole readout, no dedicated status segment |

## Approaches considered

| | Approach | Verdict |
|---|---|---|
| A | Separate `monitor.luau` entry, declarative `barWidget.render()` tree, reading published state | **Chosen** |
| B | Same entry as the toggle, imperative `setText` / `setGlyph` | Rejected — see below |
| C | Service publishes preformatted display strings, monitor renders them | Rejected — couples presentation to the service and bloats published state for every consumer. Reconsider only if the duplicated formatting helpers start drifting |

B fails on three counts, all verified in `plugin_widget.cpp`:

1. `luaSetGlyph` unconditionally sets the glyph visible, so the imperative path cannot
   render text without an icon and cannot give each segment its own glyph.
2. There is no `render(nil)`. `applyUiTreePatch` hides the imperative row permanently once
   a tree arrives, so a widget that switches between the two modes at runtime is a one-way
   door.
3. A single label cannot carry the pill, since `fill` belongs to a container. (Moot in
   the end — see the revision at the foot: the shell draws the pill, not the widget.)

## Runtime constraints verified against the noctalia source

Read from `/home/nomadx/noctalia` at `a5aa52499`, against installed `noctalia-git
5.0.0.r4969.g624363e30-1`.

| Constraint | Where |
|---|---|
| `barWidget` = `setText`, `setGlyph`, `setImage`, `setTooltip`, `clearTooltip`, `setFont`, `setColor`, `setGlyphColor`, `isVertical`, `outputName`, `setVisible`, `render` | `plugin_bindings.cpp:233` |
| `setTooltip` accepts a string, one `{key, value}` row, or a list of them | `plugin_bindings.cpp:124` |
| Bar trees drop only `input`, `select`, `scroll` — `graph` and `progress` are allowed | `plugin_widget.cpp:61` |
| `fill` and `color` take a role, a `role/alpha` suffix, or `#rrggbb[aa]` | `ui_tree_reconciler.cpp:154`, `render/core/color.h:149` |
| Flex containers take `minWidth`; labels take `width` and `textAlign`, not `minWidth` | `ui_tree_reconciler.cpp:448` |
| The **bar** draws the capsule, not the widget: `content + 2 * capsule_padding` by `capsule_thickness * bar thickness`, radius `min(w, h) * 0.5`, content centred | `bar.cpp:929`, `:967` |
| Plugin widgets get a capsule spec from `[widget.*] capsule*` exactly as native ones do | `bar.cpp:2263` |
| `height` on a flex sets **both** min and max — children that sum past it overflow into the bar's clip | `ui_tree_reconciler.cpp:1095` |
| `sysmon` reserves no label width by default (`labelMinWidth = 0`, applied only when positive) | `sysmon_widget.h:53`, `sysmon_widget.cpp:273` |
| `sysmon` tints value **and** glyph towards a highlight colour over activity/critical thresholds | `sysmon_widget.cpp:76`, `:344` |
| `setUpdateInterval` clamps to a 16 ms floor, so up to 60 fps | `plugin_widget.cpp:502` |
| Every plugin bar widget ticks at 250 ms by default, dispatching a global `update()` | `plugin_widget.h:157`, `script_runtime.cpp:992` |
| Updates defer only during panel transitions — **a covered bar keeps ticking** | `bar.cpp:2384` |
| Image paths resolve `~`, absolute, or plugin-relative; SVG goes through librsvg | `plugin_widget.cpp:135`, `image_file_loader.cpp:401` |
| Per-instance widget settings merge over entry defaults, then plugin settings | `widget_factory.cpp:261` |
| Manifest supports `type = "file"` with `extensions`, and `visible_when` | `plugin_manifest.cpp:83`, `:307` |
| No `require`: `luaL_openlibs` + `luaL_sandbox` with no host loader | `luau_host.cpp:1636` |
| Nothing in this design is gated above `plugin_api = 19` | `plugin_api.h` |

The last one is load-bearing for the whole design: **entry scripts cannot share code.**
`monitor.luau` carries its own copy of the formatting helpers that `widget.luau` and
`panel.luau` already duplicate. That is forced by the runtime, not a style choice, and it
is the reason approach C stays on the table as a fallback.

## 1. Architecture

```
service.luau ──▶ state "metrics"   ──┬──▶ widget.luau   toggle: glyph + tooltip
             ──▶ state "game_mode" ──┴──▶ monitor.luau  readout: segments + tooltip   ← new
```

`monitor.luau` is a pure renderer. It owns no state, polls nothing, spawns nothing, and
adds no commands. It watches the same two state keys the toggle watches and calls
`barWidget.render()` when either changes. **No service changes.**

```toml
[[widget]]
id = "monitor"
entry = "monitor.luau"
```

The two widgets split cleanly by mechanism: the toggle stays imperative and never calls
`render()`, the monitor is declarative and never calls `setGlyph`. Neither hits the
one-way door.

Clicks match the toggle so muscle memory transfers: the monitor honours the existing
plugin-level `click_action`, and right-click always toggles gamer mode.

## 2. Segment model and layout

```
off   ·  CPU 12%  45°   GPU 63%  71°   ↓548K ↑854K  ·
on    ▓  CPU 12%  45°   GPU 63%  71°   ↓548K ↑854K  ▓
         └── group ──┘  └─── group ───┘  └─ group ─┘
```

The readout root is the row of groups itself, becoming a `ui.column` of row plus band
when the flame is lit. (As shipped — the original text had the root be a column carrying
a pill; see the revision at the foot.) A segment is
`ui.row{ ui.glyph, ui.label }`, or just the label when `show_glyphs` is off, which is the
requester's screenshot exactly. Groups are rows of segments with a tight gap; the row's gap
between groups is wider, which is what makes clusters read as clusters rather than as a run
of numbers.

Glyph names are taken from the vocabulary the built-in sysmon and this plugin's own panel
already use, so the widget looks native rather than bolted on: `cpu-usage`,
`cpu-temperature`, `gpu-usage`, `temperature`, `memory`, `storage`, `performance`,
`download`, `upload`. All but `performance` come from the built-in sysmon; that one is
borrowed from this plugin's own panel, which already uses it for load average.

**Jitter is solved at the label, not the row.** Every value label carries an explicit
`width` and `textAlign = "right"`. `12%` growing to `100%` shifts nothing, and columns line
up across refreshes. `minWidth` on the segment row would also work but leaves the digits
ragged, and labels do not accept `minWidth` anyway.

**Superseded.** Reserving every metric's worst case made the readout permanently as wide
as a saturated network link. The shell reserves nothing by default and neither does this;
`label_min_width` is opt-in, on a wrapper flex. See the revision at the foot.

Fixed order:

| Group | Segments |
|---|---|
| CPU | usage, temperature |
| Memory | RAM, swap |
| GPU | usage, temperature, VRAM |
| System | load average |
| Network | ↓ rx, ↑ tx |

## 3. Settings

Per-instance `[[widget.setting]]` on the monitor entry, so two placements can differ:

| Key | Type | Default |
|---|---|---|
| `show_cpu` | bool | true |
| `show_cpu_temp` | bool | true |
| `show_ram` | bool | true |
| `show_swap` | bool | false |
| `show_gpu` | bool | true |
| `show_gpu_temp` | bool | true |
| `show_vram` | bool | false |
| `show_load` | bool | false |
| `show_net` | bool | true |
| `show_glyphs` | bool | true |
| `highlight_gamer_mode` | bool | true |
| `flame` | select `off` / `flare` / `always` | `flare` |
| `flame_style` | select `graph` / `bars` | `graph` |

`flame` carries `visible_when = { key = "highlight_gamer_mode", values = [true] }` so it
disappears when there is no flame to animate. Defaults reproduce the requester's screenshot
minus the segments most people will not want.

The monitor declares no `click_action` of its own. It reads the plugin-level one, so both
widgets behave identically on click.

### Custom icons, the other half of issue #1

Two plugin-level settings beside the existing `glyph`:

| Key | Type | Notes |
|---|---|---|
| `icon_file` | file, `extensions = ["svg", "png"]` | Wins over `glyph` when set |
| `icon_file_active` | file, same | Used while gamer mode is on; falls back to `icon_file` |

The toggle calls `setImage(path, true, size)`. The `watch` flag reloads the bar when the
file changes on disk, so editing an SVG updates the icon live.

`icon_file_active` exists because `setGlyphColor` does not tint an image. Without it, a
user who picks a custom icon silently loses the accent that currently signals gamer mode.
Two files restores it.

## 4. Tooltip

Both widgets move from the joined `A | B | C` string to `setTooltip(rows)`, which renders
as an aligned key/value table.

The monitor's tooltip shows **what the bar does not**. Enabling `show_gpu` removes GPU from
the tooltip. The tooltip complements the readout instead of repeating it, and always ends
with a gamer-mode row carrying state and suspended count — the part of issue #1 that the
built-in sysmon can never provide. Temperatures carry their unit in the tooltip (`45°C`)
where the bar drops it for space (`45°`).

The toggle's tooltip becomes rows of the same data, plus the gamer-mode row. The existing
loading string still covers the pre-first-sample case.

## 5. The flame

`highlight_gamer_mode` originally painted the readout with `fill = "primary/0.15"`. As
shipped it adds the flame band and nothing else — no fill, no padding change, no extra
segment — so switching it on moves no digit horizontally. See the revision at the foot.

### The flame is a reading, not an ornament

Intensity is derived from the published sample, never from a preference:

```
usage    = max(cpuPerc, gpuPerc)                     -- what a player feels
tempHeat = clamp((max(cpuTemp, gpuTemp) - 50) / 40)  -- what the hardware feels
heat     = clamp(usage * 0.7 + tempHeat * 0.3)
```

A floor of `0.12` keeps embers alive at idle so the band still reads as lit. Usage leads
because it is what a player notices; temperature still counts, so a hot card at moderate
load earns a hot flame. The result is a bar that rages when the machine does — legible
across the room without reading a number.

This also settles the cost argument. An always-burning flame was hard to justify as
decoration; as a load indicator it is the same class of thing as the numbers beside it.

### Structure

The readout root becomes a `ui.column`:

```
column
├── row      the segment groups
└── band     the flame
```

Unlit there is no column at all — the row of groups is the root, which is the shape a
`sysmon` readout has. The pill in the original sketch of this block is gone; the bar
draws it. See the revision at the foot.

The band sits below the text because the tree has no z-order — nothing can be composited
behind a label. `flame_style` picks how it is drawn:

| Style | Built from | Nodes | Notes |
|---|---|---|---|
| `graph` | one `ui.graph`, two series | 1 | **Default.** Outer flame in `#ff6a00`, hotter inner one in `#ffd27a`. Scales to any readout width with no size arithmetic |
| `bars` | 28 `ui.box` on a baseline | 28 | `align = "end"` with per-box `height` and `fill`. Crisper up close, 28× the node churn |

Heights come from a 1-D heat field stepped once per frame: sparks injected at the base in
proportion to `heat`, lateral bleed to neighbours, then decay. Roughly fifteen lines of
Luau over a fixed-size table, no allocation per frame.

The palette is fixed rather than role-derived — `#3d0f02 → #b02a04 → #ff6a00 → #ffb340 →
#ffe9a3`. Fire is not a theme colour, and a theme whose primary is green should still get
fire.

### When it burns

Animation rides the widget's own tick, which needs care because that tick is never off. A
plugin bar widget ticks at 250 ms by default and dispatches a global `update()`; scripts
that define no such global, including this plugin's current widget, pay only a queue
round-trip. So:

- At load the monitor calls `setUpdateInterval(1000)`, cutting the idle tick from four a
  second to one. It cannot be disabled outright, and the monitor does not need it — the
  readout is driven by `state.watch`.
- `update()` exists but returns immediately unless a flare is in progress or
  `flame = "always"` is driving the loop.
- On a false→true transition of `game_mode.enabled` with `flame = "flare"`, the monitor
  calls `setUpdateInterval(33)`, animates for ~900 ms off `noctalia.nowMs()` deltas, then
  calls `setUpdateInterval(1000)` and goes quiet. Bar widgets get no frame tick;
  `setNeedsFrameTick` is panel-only.

- `off` — no animation, no band, interval never raised. The plain tint.
- `flare` — opens at `max(heat, 0.75)` whatever the load, ramps to nothing over ~900 ms,
  settles to the resting tint. Default.
- `always` — the band stays lit and tracks `heat` for as long as gamer mode is on.

`always` is a loop, not an edge, so it is armed in two places beyond the transition
watcher: at load and in `onConfigChanged`. Gamer mode may already be on when the widget
loads, and changing the setting fires no transition.

`always` stays off by default because **updates are not gated on visibility**. The only
deferral is during panel transitions (`bar.cpp:2384`); a fullscreen game covering the bar
does not stop the timer. With `graph` that is one node re-walked per frame, which is a
defensible price for a live load indicator — but it is still a price, and the user should
opt into it.

A vertical bar gets no band at all. It needs horizontal room, and a ~26 px column has
none, so a vertical readout is the same shape whether gamer mode is on or off.

## 6. Absent data, first sample, vertical bars

Three rules, two inherited from the existing plugin:

1. **Absent metrics are omitted, never zeroed.** No GPU means no GPU group, not `GPU 0%`.
2. **Before the first sample**, every enabled segment renders `—`, dimmed to
   `on_surface_variant` so the loading state reads as loading rather than as data, and no
   row appears a second after login. Nothing has been sampled, so nothing is tinted.
3. **On a vertical bar** (`barWidget.isVertical()`), segments stack one per row as glyph
   over value, centred, with no width reservation — `label_min_width` is horizontal-only
   and would clip in a ~26 px bar. Group gaps collapse.

## 7. Testing

New `tests/monitor.lua`, the 18th suite. The mock gains a `barWidget.render` capture and
`setUpdateInterval`.

| Assertion | Why |
|---|---|
| Segment presence and order follow the toggles | The core contract |
| No GPU in the sample produces no GPU segments | Rule 1, the honesty rule |
| Values carry no `width` by default, and `label_min_width` puts a `minWidth` on a wrapper | Matching the shell's default, and the regression that made the readout worst-case wide |
| The tree paints no `fill` anywhere, lit or unlit | The per-cluster boxes the user reported |
| `gradientFactor` is flat below activity, jumps to the onset tint, saturates at critical | It claims to reproduce the shell's curve; this is that claim |
| Band present only when enabled **and** `highlight_gamer_mode` **and** `flame ~= "off"` | Three conditions, easy to conflate |
| The band never asks for `flexGrow` | In a column that is vertical growth, into the bar's clip |
| The same groups in the lit and unlit trees | The band must not disturb the readout |
| `flame = "flare"` restores the idle interval when the flare ends | A stuck 30 fps loop is the expensive failure |
| `flame = "off"` never raises the interval | Opt-out actually opts out |
| `flame = "always"` is armed at load and on config change | No transition edge exists when gamer mode is already on |
| `heat` rises with usage and with temperature, and is 0 before the first sample | The flame claims to report the machine; this is that claim |
| A band is present only while burning, and never on a vertical bar | Rule 3, and the band needs horizontal room |
| `flame_style` selects graph or bars without changing the segment rows | The fire must not disturb the readout |
| Vertical layout stacks instead of running horizontally | Rule 3 |
| Vertical labels carry no width reservation | A ~26 px bar cannot fit the horizontal reservations |
| A resting band renders a zeroed field, not the live one | Otherwise the field freezes mid-flame when a flare ends |
| Unknown or missing state renders without erroring | The widget must never take the bar down |

`tests/widget.lua` is updated for tooltip rows. `./run-tests.sh` stays the entry point.

## 8. Documentation

- `README.md`: a Monitor section covering both entries, every new setting, and the `always`
  cost warning.
- `translations/en.json`: label and description keys for all fourteen new settings, plus
  tooltip row labels.
- Screenshots of the monitor in both states, since the upstream PR template requires them
  for visual surfaces.

## 9. Release process

Verified against `noctalia-dev/community-plugins` at `main`, 2026-08-09.

The plugin merged on 2026-07-31, so this is an update, not a submission.

1. **Bump `version` in `plugin.toml` to `0.7.0`.** The validator enforces
   `^\d+\.\d+\.\d+$` (`validate-plugins.py:16`) — no pre-release or build suffixes. The
   repo README requires a bump on *every* change to the plugin.
2. **Sync the plugin directory into a fork checkout at the repo root** (`fork/gamer-mode/`,
   not under any `plugins/` directory), branch, and open a PR against `main`.
3. **Use the PR template.** A bot closes pull requests that lose the
   `<!-- noctalia-pr-template:v1 -->` marker, a `##` heading, a `- **Field:**` line, or a
   `- [ ]` entry. Tick *"Update to an existing plugin (version bumped in `plugin.toml`)"*.
   Attach screenshots — required for anything with a visual surface.
4. **Never commit `catalog.toml`.** `on-push.yml` regenerates it after merge and commits it
   as `chore: update plugin catalog [skip ci]`.
5. **Leave `plugin_api` at 19.** Nothing in this design is gated above it.
6. CI runs `validate-plugins.py` plus the validator's own unit tests on every PR push.

### Why the version string matters more than it looks

`update-catalog.py` does not date a release from file mtimes. It walks the history of
`<plugin>/plugin.toml` and records when each **version string was first committed**
(`release_times`), then uses that as `updated_at`. Consequences:

- Editing plugin files without bumping `version` ships no new release. The store keeps
  showing the old date.
- Re-using or reverting to a previous version string keeps that version's original date.
- The catalog also publishes a **release ladder** (`release_history`): for each
  `plugin_api` level below the tip, the newest revision at that level, pinned by git rev,
  so users on an older Noctalia can still install something. Staying at 19 generates no
  ladder rows for us. If a future version ever raises `plugin_api`, this 0.7.0 revision
  automatically becomes the fallback for older shells — which is a reason to raise
  `plugin_api` only when a capability genuinely requires it.

## Out of scope

- **Audio reactivity.** `plugin_widget.cpp:113` reads an `audio_spectrum` setting and
  forwards PipeWire spectrum frames to `onAudioSpectrum(values, state)`, so an
  audio-reactive flame is buildable. Explicitly declined for this release.
- ~~**Threshold colouring.**~~ Deferred here on the grounds that the pill's background
  tint would collide with it. With the pill gone there is nothing to collide with, and
  threshold colouring turned out to be how the shell expresses intensity — so it shipped
  in this release instead. See the revision at the foot.
- **Per-core CPU, disk I/O, per-interface network.** Not in the published `metrics` table;
  each would need service work.
- **Gradient fills.** The renderer has `FillMode::LinearGradient`, but the reconciler only
  ever sets a solid colour from `parseColor`. Not reachable from a plugin.
- **Heat behind the digits.** A `ui.row` paints its fill behind its own children, so warm
  fills on the group rows would put heat behind the readings — the closest a tree with no
  z-order can get to fire under text. Prototyped as a third `flame_style` called `burn` and
  dropped: it adds a fill mutation per group on top of the 28 boxes, for an effect that is
  coarse at one cell per group.


## Revision: the shell owns the pill

Live testing killed the pill this design asked the widget to draw. Three complaints, one
root cause: the design never checked how the shell frames its own bar widgets.

`SysmonWidget::create` builds a `ui::row` of glyph, optional gauge or graph, and label,
and `doLayout` sizes it to its content (`sysmon_widget.cpp:230`, `:498`). It paints no
background at all. The pill comes from the bar: `finalizeCapsules` wraps a widget — or a
run of adjacent widgets sharing a `capsule_group` — in a shell sized `content + 2 *
capsule_padding` along the main axis and `capsule_thickness * bar thickness` across it,
radius `min(w, h) * 0.5`, content centred inside (`bar.cpp:929`, `:967`–`:986`). Plugin
widgets go through the same `createWidget` path as native ones and get
`setBarCapsuleSpec` from `[widget.*] capsule*` config (`bar.cpp:2263`), so `capsule =
true` is all this widget ever needed.

Measured on a 42 px bar: the shell's capsule and this widget's now occupy the identical
rows 5–37, 33 px, matching `round(42 * 0.76)`.

What that fixes, and what the hand-drawn pill had got wrong:

- **Height.** `PILL_HEIGHT = 28` was a guess. A plugin cannot see the bar's thickness or
  its content scale, so no guess could have been right on a second machine. Worse,
  `height` on a flex sets both min and max (`ui_tree_reconciler.cpp:1095`), and the
  children summed past 28, so the flame band was being clamped out of the layout — the
  "flame stopped appearing" regression.
- **Radius.** `PILL_RADIUS = 999` leaning on the renderer's clamp was a workaround for a
  problem the shell does not have.
- **Vertical centring.** `finalizeCapsules` centres content in the shell. The reserved
  spacer above the readout is gone with the pill.

Two further corrections, both from reading the reference rather than inventing:

**Reserved widths are opt-in, not the default.** `SysmonWidget::Options::labelMinWidth`
defaults to `0` and the min-width is applied only when positive (`sysmon_widget.h:53`,
`sysmon_widget.cpp:273`). Section 3's fixed per-segment widths made the readout
permanently as wide as a saturated network link, since every metric reserved its
worst-case value. Removed; `label_min_width` is now a setting with the shell's key name
and the shell's default. Because `ui.label` takes `width` and `maxWidth` but no
`minWidth`, the reservation goes on a wrapper flex, which has one.

**Intensity belongs on the value, not behind it.** The per-group `fill` rectangles added
after the first round of feedback were visible boxes around each cluster — exactly what
the user reported. The shell instead lerps each value and its glyph from the normal
foreground towards a highlight colour (`error` by default) as the metric climbs, holding
flat below an activity threshold, jumping to a 0.25 onset tint on crossing, and
saturating at a critical one (`sysmon_widget.cpp:76` `gradientFactor`, `:344`
`currentValueColor`). `M.gradientFactor` reproduces that curve and the per-stat defaults
from `sysmon_threshold_profile.h`, so a monitor grouped beside the built-in widgets warms
in step with them. The shell lerps in HSV; a plugin can only name colours, so the ramp
runs through the role's alpha instead.

The flame band is now the whole of what this widget adds on top of a sysmon readout,
which is the shape the feature should have had from the start.

### Consequences

- The widget is a bare `ui.row` when unlit and a two-child `ui.column` when the band is
  present. Toggling gamer mode therefore changes the content height by `FLAME_HEIGHT`,
  and the shell re-centres it: the digits settle 3 px. Accepted over reserving the band's
  height permanently, which would leave every user who never enables gamer mode looking
  at a readout sitting off-centre in its capsule. The capsule's own height does not
  change — it is `capsule_thickness` of the bar — so nothing reflows.
- `ui.*` columns stretch children across the cross axis by default
  (`ui_tree_reconciler.cpp:625`), so the band spans the readout without `flexGrow`.
  `flexGrow` in a column is vertical, and the bar clips its slots; the graph band no
  longer asks for it.
- Without `capsule = true` the widget renders as a bare readout on the bar. That is the
  same thing a `sysmon` widget does in that configuration, and it is documented in the
  plugin README rather than worked around.
