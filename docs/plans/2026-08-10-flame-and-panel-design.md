# Flame motion and panel chrome — design

Date: 2026-08-10
Status: approved, not yet implemented
Supersedes nothing. Builds on `2026-08-09-bar-monitor-design.md` (the sysmon-parity revision).

## Why

Three complaints and one audit finding:

1. The bar flame's motion does not read as fire. It is a symmetric blur, so peaks fade in
   place instead of travelling, and heat wraps from one edge to the other.
2. The flare envelope is mechanical: it opens at full intensity and decays linearly.
3. The band is too subtle at 6px.
4. The panel does not reflect load at all — every progress bar is `primary` whatever the
   reading — which now contradicts the bar widget, which warms toward `error`.

## Verified constraints

Every row was checked against the shell source in `/home/nomadx/noctalia` for this design.
These are the facts the design is built on; do not re-derive them by guessing.

| Constraint | Evidence |
| --- | --- |
| Bar widgets have no frame tick. Animation is `noctalia.setUpdateInterval(ms)`, floored at 16ms | `kWidgetLib` has no `setNeedsFrameTick`; `plugin_widget.cpp:502` |
| Panels *do* get vsync ticks: `panel.setNeedsFrameTick(true)` + global `onFrameTick(deltaMs)`, coalesced, stopped while closed | `plugin_bindings.cpp:620-626`, `plugin_panel.cpp:238-248` |
| Panel second-ticks are a fixed 1000ms and are not settable | `plugin_panel.cpp:24` `kTickIntervalMs = 1000` |
| No stack, overlay, or z-index node exists. The tree is pure flexbox, 17 node types | `ui_prelude.h:18-35` |
| Every node type accepts `opacity`; `ui.box` also accepts `softness` | `ui_tree_reconciler.cpp:447-455` |
| `ui.image` accepts `border` and `borderWidth` but no tint/color | `kImage`, `ui_tree_reconciler.cpp:462` |
| Colour strings are `role`, `role/alpha` (0..1), or `#rrggbb[aa]` | `ui_tree_reconciler.cpp:151-178` |
| A plugin cannot read palette colours. There is no accessor of any kind | `kNoctaliaBaseLib`, `luau_host.cpp:1533-1587` |
| There is no theme-change callback. The only lifecycle globals are `onActivate`, `onConfigChanged`, `onExit`, `onIpc`, `onKey`, `onScroll` | `hasGlobal` call sites |
| SVG is rasterised once by librsvg. No SMIL, no self-animation | `image_file_loader.cpp:17,399` |
| `data:` URIs are accepted by the image loader | `image_file_loader.cpp:503` |
| Textures are cached by `{path, targetSize}`, so rewriting a path serves a stale raster | `async_texture_cache.cpp:323` |
| A plugin cannot query bar thickness. `barWidget` exposes only `isVertical` and `outputName` | `kWidgetLib`, `plugin_bindings.cpp:233-247` |
| `height` on a flex sets min *and* max; overflow is clipped by the bar slot | `ui_tree_reconciler.cpp:1095` |
| The shell's `label_min_width` field allows 0..200 | `sysmon_widget_definition.cpp:206-211` |

## 1. Flame motion

Replace the step function. The current model blurs symmetrically
(`f[i]*0.62 + (left+right)*0.19`), decays uniformly at random, and wraps at the edges.

Four changes, in order of visual impact:

- **Advection.** Each step, sample the field at a fractional offset and drift it. Wind
  varies slowly over time. This alone produces the leaning, travelling motion; without it
  no amount of tuning makes a symmetric kernel look like fire.
- **Persistent tongue seeds.** Replace one-frame random spikes with a small pool of seeds,
  each holding a position, intensity and lifetime, drifting with the wind and injecting
  over several frames. Tongues gain continuity instead of being noise.
- **Sharpening.** After blurring, apply `v^1.3` to restore the peaks the blur flattens.
  This is what turns a ridge into distinct tongues.
- **Clamped edges** instead of cyclic wraparound, so flames die at the ends.

The seed pool is fixed-size and preallocated, as `flameScratch` already is: a 30fps loop
must allocate nothing.

## 2. Flame envelope

Keep the 900ms window and keep the clean vanish at the end. Only the shape changes:

- **Ignition:** ease-in from 0 to peak over the first 150ms.
- **Decay:** ease-out cubic `(1 - t)^3` over the remaining 750ms — fast initial drop, long
  ember tail.

Frame rate stays at 33ms. Choppiness was explicitly not a complaint, and 60fps would double
the cost of the one thing that runs continuously.

## 3. Band height, and holding the digits still

`FLAME_HEIGHT` becomes a `flame_height` setting: default 10, range 4..16.

It has to be a setting because the widget cannot know the bar's thickness, and 10px would
clip on a thin bar. Default 10 fits a 42px bar (33px capsule) and a 34px bar (30px capsule)
with the digits' ~17px.

**The band slot is reserved whenever the flame is enabled**, drawn empty when nothing is
burning, so the digits never move on toggle.

Rejected alternative: reserving symmetrically (a spacer above as well) would keep the
readout centred *and* stable, but costs `2 * flame_height`. At 10px on a 30px capsule that
is 37px of content, which overflows into the slot clip — the exact regression the previous
revision fixed.

Accepted cost: the digits sit `flame_height / 2` above the capsule's centre permanently
rather than settling by that much on toggle. A constant offset is invisible in a way motion
is not, and lowering `flame_height` lowers the offset.

When `flame = "off"` or `highlight_gamer_mode` is false, nothing is reserved and the readout
is exactly centred, identical to a plain sysmon row.

Vertical bars are unaffected throughout. The flame is already suppressed there — a vertical
bar is ~26px wide and the readout stacks glyph over value — so no slot is reserved, no tick
is raised, and `flame_height` is ignored.

## 4. Audit fixes

- `label_min_width` max: 120 -> 200, matching the shell's field.
- Tint floor: `0.55 + 0.45 * tint` -> `0.80 + 0.20 * tint`.

  The second one is a real defect, not a tidy-up. `error` at 0.55 alpha composites to a
  muted red that reads as *less* present than full-alpha `on_surface`, so crossing a
  threshold currently dims the text before it warms. Raising the floor removes the dip.

  Exact parity with the shell's HSV lerp remains impossible: it interpolates between two
  resolved colours, and a plugin cannot read either one.

## 5. Panel — information

- Move `gradientFactor` into the panel and give each row the same activity/critical
  thresholds the bar uses, so progress fills warm toward `error` exactly as the bar
  widget's values do.
- Hierarchy: readings in `on_surface`; captions, glyphs and units stay
  `on_surface_variant`. Currently everything is dimmed equally, so nothing outranks
  anything.
- Collapse `metricRow` and `figureRow` into one builder. After the hierarchy pass they
  differ only by whether a progress bar is present.

## 6. Panel — mark

The artwork is redrawn: denser and cleaner, so it survives 42px where the three
hand-plotted beziers currently mush together.

**Theme-awareness is limited to a dark ramp and a light ramp**, chosen by
`noctalia.isDarkMode()`. Palette-derived hues are impossible — a plugin cannot read
`primary` or any other role. This is the honest ceiling, and the design does not pretend
otherwise.

Written as two files, `logo-dark.svg` and `logo-light.svg`, never one path rewritten:
the texture cache is keyed by path and would serve a stale raster after a theme flip.
There is no theme-change callback, so the check runs on panel open and on render.

## 7. Panel — chrome

Driven by `panel.setNeedsFrameTick(true)` and a global `onFrameTick(deltaMs)`. Vsync,
coalesced so a slow script only sees the latest frame, and stopped dead while the panel is
closed — an idle or closed panel costs nothing. The tick is requested only while gamer mode
is on, and released when it goes off.

- **Halo.** A glow *behind* the mark is impossible without layering. Instead the halo is an
  animated border ring on the `ui.image`: colour, alpha and width driven per frame, pulsing
  with real heat. It is an outline rather than a bloom, and the spec says so rather than
  promising a bloom it cannot deliver.
- **Header ember.** A soft accent on the header rule breathing on a slow sine, using
  `ui.box`'s `softness` and `opacity`.

## Phasing

Three independent stages, each shippable and each with its own tests passing before the
next starts:

1. **Bar flame** — sections 1, 2, 3 and the `label_min_width` cap. Touches `monitor.luau`,
   `plugin.toml`, `tests/monitor.lua`. No panel involvement.
2. **Panel information** — section 5 and the tint floor. Touches `panel.luau`,
   `tests/panel.lua`, and lifts `gradientFactor` into shared use.
3. **Panel mark and chrome** — sections 6 and 7. Touches `panel.luau`, the logo assets,
   `tests/panel.lua`.

Stage 1 carries all the layout risk and none of the new machinery; stage 3 carries all the
new machinery and none of the layout risk. Running them in this order keeps a bisect
meaningful if the capsule geometry regresses again.

## Testing

`tests/monitor.lua` and `tests/panel.lua` extend rather than change shape. The pure
functions stay pure and stay exported, which is what makes each of these assertable
without a shell:

| Behaviour | Assertion |
| --- | --- |
| Envelope ignites | intensity at 0ms < intensity at 150ms |
| Envelope decays ease-out | intensity at 300ms > linear at 300ms; 0 at 900ms |
| Advection moves heat | a single seed's peak index shifts across steps |
| Edges do not wrap | heat at index 1 does not appear at index N |
| Seeds persist | a seed injects across more than one step |
| Field stays bounded | every value in 0..1 over a long run |
| No allocation per step | seed pool length constant across steps |
| Slot reserved when flame enabled | unlit tree is a column of 2 whenever flame ~= off |
| Slot absent when flame off | tree is a bare row, no column wrapper |
| Band height follows setting | band spec height == flame_height |
| `flame_height` clamped | out-of-range values clamp to 4..16 |
| Tint floor | tint just above 0 yields alpha >= 0.80 |
| Panel rows tint | a row at critical resolves to an error fill |
| Panel hierarchy | reading colour is on_surface, caption is on_surface_variant |
| Theme variant | isDarkMode true and false select different logo filenames |
| Frame tick lifecycle | requested when mode is on, released when off |

## Out of scope

- 60fps. Choppiness was not a complaint and the flame is the one thing running
  continuously.
- Per-frame generated SVG data URIs. Each unique frame is its own texture-cache entry.
- Palette-derived logo colours, a bloom behind the mark, sub-second panel second-ticks.
  All three are ruled out by the constraints table, not by preference.
