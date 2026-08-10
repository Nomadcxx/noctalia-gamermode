# Flame and Panel Chrome Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the bar flame read as fire, hold the digits still while it burns, and give the panel threshold-aware readings with an animated mark.

**Architecture:** Three independent stages against the design in `docs/plans/2026-08-10-flame-and-panel-design.md`. Stage 1 reworks the bar widget's flame field and envelope and reserves its band slot. Stage 2 lifts the shell's `gradientFactor` curve into the panel so progress fills warm at the same thresholds the bar uses. Stage 3 redraws the panel mark and drives a halo and header ember from the panel's vsync frame tick. Every unit of logic stays a pure exported function so the Lua test harness can assert on it with no shell present.

**Tech Stack:** Luau (Noctalia V5 plugin API, `plugin_api = 19`), plain `lua` 5.x for tests via `./run-tests.sh`, declarative `ui.*` trees reconciled by the shell.

## Global Constraints

Copied verbatim from the design's constraints table. Every task's requirements implicitly include this section.

- Bar widgets have **no** frame tick. Animation is `noctalia.setUpdateInterval(ms)`, floored at 16ms.
- Panels get vsync ticks via `panel.setNeedsFrameTick(true)` plus a global `onFrameTick(deltaMs)`. Coalesced; stopped while closed.
- Panel second-ticks are a fixed 1000ms and are **not** settable.
- There is **no** stack, overlay, or z-index node. The tree is pure flexbox.
- Every node type accepts `opacity`; `ui.box` also accepts `softness`.
- `ui.image` accepts `border` and `borderWidth` but **no** tint/color prop.
- Colour strings are `role`, `role/alpha` (alpha 0.0-1.0), or `#rrggbb[aa]`.
- A plugin **cannot** read palette colours. There is no accessor of any kind.
- There is **no** theme-change callback. Lifecycle globals are only `onActivate`, `onConfigChanged`, `onExit`, `onIpc`, `onKey`, `onScroll`.
- SVG is rasterised once by librsvg. No SMIL, no self-animation.
- Textures are cached by `{path, targetSize}`, so rewriting a path serves a stale raster. Variants need distinct filenames.
- A plugin **cannot** query bar thickness. `barWidget` exposes only `isVertical` and `outputName`.
- `height` on a flex sets min *and* max; overflow is clipped by the bar slot.
- The shell's `label_min_width` field allows 0..200.
- `ui.label` has no `minWidth`; a reservation goes on a wrapper flex.
- Commit messages must carry no AI/agent attribution. The hook at `/home/nomadx/.git-hooks/commit-msg` matches `bot`, `agent`, `ai assistant`, `llm`, `codex`, `gemini` and others **as case-insensitive substrings**, so ordinary words like "both", "robot" and "management" trip it. Prefer "each" or "the two" over "both".
- Run the full suite with `./run-tests.sh` from the repo root. It must print `all tests passed`.

## File Structure

| File | Responsibility | Stage |
| --- | --- | --- |
| `gamer-mode/monitor.luau` | Bar widget: flame field, envelope, band, readout tree | 1 |
| `gamer-mode/plugin.toml` | Widget settings: `flame_height`, `label_min_width` bounds | 1 |
| `gamer-mode/translations/en.json` | Setting labels | 1, 3 |
| `tests/monitor.lua` | Bar widget assertions | 1 |
| `gamer-mode/panel.luau` | Panel: rows, tint, hierarchy, mark, chrome | 2, 3 |
| `tests/panel.lua` | Panel assertions | 2, 3 |
| `gamer-mode/logo-dark.svg`, `gamer-mode/logo-light.svg` | Redrawn mark, two ramps | 3 |
| `gamer-mode/README.md` | User-facing settings documentation | 1, 3 |

`monitor.luau` and `panel.luau` deliberately duplicate their formatting helpers. Plugin entries run in separate sandboxed Luau states with no `require`, so there is no module to share. Do not try to factor them together.

---

# Stage 1 — Bar flame

## Task 1: Flare envelope

The flare currently opens at full intensity and decays linearly, which reads as mechanical. Replace it with an ease-in ignition and an ease-out decay, as a pure function so it is testable without touching the clock.

**Files:**
- Modify: `gamer-mode/monitor.luau` (constants near line 22; `burningLevel` near line 467)
- Test: `tests/monitor.lua`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: `M.flareIntensity(elapsedMs: number, peak: number) -> number`. Returns 0 outside `[0, FLARE_DURATION_MS)`. Used by `burningLevel` in this task and by no later task.

- [ ] **Step 1: Write the failing test**

Append to `tests/monitor.lua`, immediately before the `-- ── intervals ──` banner:

```lua
-- ── flare envelope ──

-- Fire catches rather than arriving at full brightness, so frame one is dark and the
-- peak lands at the end of the ignition ramp.
assert(monitor.flareIntensity(0, 1) == 0, "the flare ignites from nothing")
assert(monitor.flareIntensity(75, 1) < monitor.flareIntensity(150, 1),
    "the ignition ramps up")
assert(math.abs(monitor.flareIntensity(150, 1) - 1) < 1e-9,
    "the peak lands when ignition ends, got " .. tostring(monitor.flareIntensity(150, 1)))

-- Ease-out, not linear: the curve is steepest right after the peak and flattens into a
-- long ember tail. Comparing the two end quarters of the decay is what distinguishes the
-- shape; comparing against a straight line would not, because a cubic sits under it
-- everywhere.
local earlyDrop = monitor.flareIntensity(150, 1) - monitor.flareIntensity(300, 1)
local lateDrop = monitor.flareIntensity(750, 1) - monitor.flareIntensity(900, 1)
assert(earlyDrop > lateDrop,
    "decay flattens: early " .. tostring(earlyDrop) .. " late " .. tostring(lateDrop))

assert(monitor.flareIntensity(900, 1) == 0, "the flare is out at 900ms")
assert(monitor.flareIntensity(5000, 1) == 0, "and stays out afterwards")
assert(monitor.flareIntensity(-10, 1) == 0, "a negative elapsed is not a flare")

-- The peak scales the whole envelope rather than clipping it.
assert(math.abs(monitor.flareIntensity(150, 0.5) - 0.5) < 1e-9, "peak scales the envelope")
assert(monitor.flareIntensity(300, 0) == 0, "a zero peak never lights")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./run-tests.sh 2>&1 | tail -5`
Expected: FAIL — `attempt to call a nil value (field 'flareIntensity')`.

- [ ] **Step 3: Write the implementation**

In `gamer-mode/monitor.luau`, add `IGNITE_MS` beside the existing flare constants (near line 24):

```lua
local FLARE_DURATION_MS = 900
-- Fire catches. Opening at full intensity is the single thing that made the old flare
-- read as a light switch rather than an ignition.
local IGNITE_MS = 150
```

Add the pure function just above `local function burningLevel(config)`:

```lua
-- The flare's shape over its 900ms life: ease-in to the peak, then ease-out cubic to
-- nothing. The cubic is what gives the long ember tail -- its slope is steepest right
-- after the peak and almost flat by the end, so the last third of the time covers only a
-- few percent of the intensity.
function M.flareIntensity(elapsedMs, peak)
    local t = tonumber(elapsedMs) or 0
    local top = math.max(0, tonumber(peak) or 0)
    if t < 0 or t >= FLARE_DURATION_MS or top <= 0 then
        return 0
    end
    if t < IGNITE_MS then
        local k = t / IGNITE_MS
        return top * k * k
    end
    local k = (t - IGNITE_MS) / (FLARE_DURATION_MS - IGNITE_MS)
    local inv = 1 - k
    return top * inv * inv * inv
end
```

Replace the tail of `burningLevel` — the two lines currently reading `-- The flare opens hot whatever the load, then settles to the resting tint.` and `return math.max(heat, 0.75) * (1 - elapsed / FLARE_DURATION_MS)` — with:

```lua
    -- The flare opens hot whatever the load, then follows the envelope down.
    return M.flareIntensity(elapsed, math.max(heat, 0.75))
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./run-tests.sh 2>&1 | tail -5`
Expected: `all tests passed`.

- [ ] **Step 5: Commit**

```bash
git add gamer-mode/monitor.luau tests/monitor.lua
git commit -m "fix: give the flare an ignition and an ease-out tail"
```

---

## Task 2: Flame motion

The field is a symmetric blur with cyclic wraparound, so peaks fade in place instead of travelling and heat teleports across the band. Add advection, persistent seeds, sharpening, and clamped edges.

**Files:**
- Modify: `gamer-mode/monitor.luau` (`M.stepFlame` near line 299, scratch buffer near line 292)
- Test: `tests/monitor.lua`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `M.stepFlame(field: {number}, heat: number, dtMs: number)` — same signature as today, mutating `field` in place. Also `M.resetFlame()`, which zeroes the wind, the seed pool and the phase, so tests can start from a known state. Task 3 calls neither.

- [ ] **Step 1: Write the failing test**

Append to `tests/monitor.lua`, immediately after the flare-envelope block added in Task 1:

```lua
-- ── flame motion ──

local function newField()
    local f = {}
    for i = 1, 28 do f[i] = 0 end
    return f
end

local function peakIndex(field)
    local best, at = -1, 0
    for i, v in ipairs(field) do
        if v > best then best, at = v, i end
    end
    return at, best
end

-- Deterministic: the model uses math.random, so seed it and reset the module's wind and
-- seed pool, or these assertions depend on whatever ran before them.
math.randomseed(20260810)
monitor.resetFlame()

-- Heat injected in the middle must travel. A symmetric blur leaves the peak where it was
-- put; advection is the whole difference between a fading blob and a flame.
local drift = newField()
drift[14] = 1
local start = peakIndex(drift)
local moved = false
for _ = 1, 40 do
    monitor.stepFlame(drift, 0, 33)
    if peakIndex(drift) ~= start then moved = true end
end
assert(moved, "advection moves heat along the band")

-- Edges are clamped, not cyclic. Heat pushed off one end must not reappear at the other.
monitor.resetFlame()
local edge = newField()
edge[1] = 1
for _ = 1, 12 do
    monitor.stepFlame(edge, 0, 33)
end
assert(edge[28] < 0.02,
    "heat at the near edge does not wrap to the far one, got " .. tostring(edge[28]))

-- Seeds persist across frames rather than being one-frame spikes, so a tongue has
-- continuity. The measurement has to be per column and at LOW heat. At high heat the
-- band saturates and stays lit whatever the injection model, so a band-wide peak cannot
-- tell the two apart -- an earlier draft of this test scored 59 out of 60 frames and
-- would have passed against the old one-frame-spark model too. Measured against that
-- model as a control, this run is 9 frames with persistent seeds and 2 without.
monitor.resetFlame()
math.randomseed(4242)
local lit = newField()
local runs, longest = {}, 0
for i = 1, 28 do runs[i] = 0 end
for _ = 1, 120 do
    monitor.stepFlame(lit, 0.15, 33)
    for i = 1, 28 do
        if lit[i] > 0.30 then
            runs[i] = runs[i] + 1
            if runs[i] > longest then longest = runs[i] end
        else
            runs[i] = 0
        end
    end
end
assert(longest >= 6, "a tongue holds its column for several frames, longest " .. tostring(longest))

-- The field is a normalised heightfield. Anything outside 0..1 is a renderer bug waiting
-- to happen, and the sharpening step is the easiest way to introduce one.
monitor.resetFlame()
local bounded = newField()
for _ = 1, 400 do
    monitor.stepFlame(bounded, math.random(), 33)
    for i, v in ipairs(bounded) do
        assert(v >= 0 and v <= 1, "column " .. i .. " left 0..1 at " .. tostring(v))
    end
end

-- The step runs 30 times a second for as long as a game does, so it must not grow
-- anything. The field is the only table it writes, and its length is the cheap proxy for
-- the scratch buffer and seed pool staying preallocated too.
monitor.resetFlame()
local fixed = newField()
for _ = 1, 300 do
    monitor.stepFlame(fixed, 0.7, 33)
end
assert(#fixed == 28, "the field neither grows nor is replaced, got " .. tostring(#fixed))

-- With no heat the band must actually die, or "resting" would never look resting.
monitor.resetFlame()
local dying = newField()
for i = 1, 28 do dying[i] = 1 end
for _ = 1, 200 do
    monitor.stepFlame(dying, 0, 33)
end
local _, remaining = peakIndex(dying)
assert(remaining < 0.02, "the field burns out with no heat, got " .. tostring(remaining))
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./run-tests.sh 2>&1 | tail -5`
Expected: FAIL — `attempt to call a nil value (field 'resetFlame')`.

- [ ] **Step 3: Write the implementation**

In `gamer-mode/monitor.luau`, replace the scratch-buffer block (`local flameScratch = {}` and its loop) and the whole of `M.stepFlame` with:

```lua
-- Scratch buffer for one step, reused so a 30fps loop allocates nothing.
local flameScratch = {}
for i = 1, FLAME_COLUMNS do
    flameScratch[i] = 0
end

-- Tongues are objects with a life, not one-frame spikes. A spark that is blurred away the
-- frame after it lands can never read as a flame; one that keeps injecting while it drifts
-- does. The pool is fixed and preallocated for the same reason as the scratch buffer.
local FLAME_SEEDS = 6
local flameSeeds = {}
for i = 1, FLAME_SEEDS do
    flameSeeds[i] = { pos = 0, life = 0, power = 0 }
end
local flameWind = 0
local flameWindPhase = 0

-- Lets a test start from a known field. Nothing in the widget calls this.
function M.resetFlame()
    flameWind = 0
    flameWindPhase = 0
    for i = 1, FLAME_SEEDS do
        local seed = flameSeeds[i]
        seed.pos, seed.life, seed.power = 0, 0, 0
    end
end

-- Reads outside the band as cold. Cyclic wraparound was why heat used to teleport from
-- one end to the other.
local function sampleField(index)
    if index < 1 or index > FLAME_COLUMNS then
        return 0
    end
    return flameScratch[index]
end

-- One step of a 1-D fire. Two sums of slowly moving sines give a wind that wanders
-- without ever repeating on a period short enough to notice; the field is advected along
-- it, blurred with a kernel that leans the same way, then sharpened to put back the peaks
-- the blur flattens. Sharpening is what turns a ridge into tongues.
function M.stepFlame(field, heat, dtMs)
    local dt = dtMs or 33
    local decay = math.min(1, dt * 0.0042)

    flameWindPhase = flameWindPhase + dt * 0.0009
    flameWind = math.sin(flameWindPhase) * 0.8 + math.sin(flameWindPhase * 2.3) * 0.35

    for i = 1, FLAME_COLUMNS do
        flameScratch[i] = field[i] or 0
    end

    local lean = math.max(-1, math.min(1, flameWind))
    local weightLeft = 0.16 + lean * 0.06
    local weightRight = 0.16 - lean * 0.06

    for i = 1, FLAME_COLUMNS do
        -- Fractional read from upwind: this is the advection.
        local source = i - flameWind
        local base = math.floor(source)
        local frac = source - base
        local shifted = sampleField(base) * (1 - frac) + sampleField(base + 1) * frac
        local blended = shifted * 0.66
            + sampleField(i - 1) * weightLeft
            + sampleField(i + 1) * weightRight
        local value = blended - decay * (0.5 + math.random() * 0.7)
        if value <= 0 then
            field[i] = 0
        else
            -- Gamma above 1 pushes midtones down and leaves peaks alone, so the tops
            -- separate from the body instead of melting into it.
            field[i] = math.min(1, value ^ 1.3)
        end
    end

    if heat <= 0 then
        return
    end

    for i = 1, FLAME_SEEDS do
        local seed = flameSeeds[i]
        if seed.life > 0 then
            seed.life = seed.life - dt
            seed.pos = seed.pos + flameWind * 0.35
            local index = math.floor(seed.pos + 0.5)
            if index >= 1 and index <= FLAME_COLUMNS then
                field[index] = math.min(1, field[index] + seed.power * dt * 0.02)
            end
        elseif math.random() < heat * 0.35 then
            seed.pos = math.random(1, FLAME_COLUMNS)
            seed.life = 120 + math.random() * 260
            seed.power = 0.45 + math.random() * 0.55 * heat
        end
    end
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./run-tests.sh 2>&1 | tail -5`
Expected: `all tests passed`.

If the persistence assertion fails, raise `seed.life`'s floor. If the *burnout* assertion
fails, do **not** touch `seed.life` — `stepFlame` returns on `heat <= 0` before the seed
loop ever runs, so seeds cannot affect burnout. Burnout is governed by `decay` and the
blur weights (which sum to 0.98, below 1, so the field is contractive). Do not weaken
either assertion to fit the model.

- [ ] **Step 5: Commit**

```bash
git add gamer-mode/monitor.luau tests/monitor.lua
git commit -m "fix: make the flame drift and lick instead of smudging"
```

---

## Task 3: Band height and a slot that holds the digits still

Raise the band to a configurable 10px and reserve its slot whenever the flame is enabled, so toggling gamer mode no longer moves the readout.

**Files:**
- Modify: `gamer-mode/monitor.luau` (`FLAME_HEIGHT` near line 30; `M.readConfig`; `M.flameBand`; `M.buildTree`)
- Modify: `gamer-mode/plugin.toml`
- Modify: `gamer-mode/translations/en.json`
- Modify: `gamer-mode/README.md`
- Test: `tests/monitor.lua`

**Interfaces:**
- Consumes: `M.stepFlame` from Task 2 (unchanged signature).
- Produces: `M.flameBand(field: {number}, style: string, height: number)` — gains a third parameter. `M.readConfig()` gains `flame_height: number`, clamped to 4..16, default 10.

- [ ] **Step 1: Write the failing test**

In `tests/monitor.lua`, **replace** the three assertions that the reservation invalidates.

First, replace lines reading:

```lua
assert(tree.kind == "row", "an unlit readout is just the row, got " .. tostring(tree.kind))
assert(#tree.children == 4, "cpu, mem, gpu and net form four groups, got " .. #tree.children)
```

with:

```lua
-- The band's slot is reserved whenever the flame is enabled, lit or not, so the digits do
-- not move when gamer mode is toggled. The readout is the column's first child.
assert(tree.kind == "column", "an unlit readout still reserves the band, got " .. tostring(tree.kind))
assert(#tree.children == 2, "readout and reserved band, got " .. #tree.children)
assert(tree.children[1].kind == "row", "the readout is the first child")
assert(#tree.children[1].children == 4,
    "cpu, mem, gpu and net form four groups, got " .. #tree.children[1].children)
```

Second, replace:

```lua
assert(#lit.children[1].children == #dark.children, "the same groups in both states")
```

with:

```lua
assert(#lit.children[1].children == #dark.children[1].children,
    "the same groups whether lit or not")
```

Third, replace:

```lua
-- Unlit, there is no band and so no column at all.
assert(monitor.buildTree(FULL, off, defaultsFlame, false, 0.8).kind == "row",
    "gamer mode off is a plain readout")
```

with:

```lua
-- Unlit the slot is still there, and it is empty. This is what stops the readout settling
-- when gamer mode comes on.
local reserved = monitor.buildTree(FULL, off, defaultsFlame, false, 0.8)
assert(reserved.kind == "column", "gamer mode off still reserves the slot")
for _, v in ipairs(reserved.children[2].spec.values or {}) do
    assert(v == 0, "the reserved band carries no heat, got " .. tostring(v))
end
```

Then append this block after the flame-motion block:

```lua
-- ── band height ──

assert(monitor.readConfig().flame_height == 10, "the band is 10px by default")

-- A plugin cannot ask the shell how thick the bar is, so the height has to be a setting
-- and it has to be clamped. 10px fits a 42px bar (33px capsule) and a 34px bar (30px
-- capsule) over ~17px of digits; a thin bar needs less.
mock.config.flame_height = 2
assert(monitor.readConfig().flame_height == 4, "too small clamps up to 4")
mock.config.flame_height = 99
assert(monitor.readConfig().flame_height == 16, "too large clamps down to 16")
mock.config.flame_height = "nonsense"
assert(monitor.readConfig().flame_height == 10, "unparseable falls back to the default")

mock.config.flame_height = 12
local tallConfig = monitor.readConfig()
local tall = monitor.buildTree(FULL, on, tallConfig, false, 0.8)
assert(tall.children[2].spec.height == 12,
    "the band honours the setting, got " .. tostring(tall.children[2].spec.height))

tallConfig.flame_style = "bars"
local tallBars = monitor.buildTree(FULL, on, tallConfig, false, 0.8)
assert(tallBars.children[2].spec.height == 12, "bars style honours it too")
mock.config.flame_height = nil

-- A vertical bar is ~26px wide and the readout stacks glyph over value, so the flame is
-- suppressed there entirely. The reservation must not follow it: no band, no slot, and
-- flame_height ignored.
local verticalTree = monitor.buildTree(FULL, on, monitor.readConfig(), true, 0.8)
assert(verticalTree.kind == "column", "a vertical readout still stacks")
for _, child in ipairs(verticalTree.children) do
    assert(child.kind == "column",
        "a vertical stack holds only segment cells, found " .. tostring(child.kind))
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./run-tests.sh 2>&1 | tail -5`
Expected: FAIL — the first new assertion reports `an unlit readout still reserves the band, got row`.

- [ ] **Step 3: Write the implementation**

In `gamer-mode/monitor.luau`, replace the `FLAME_HEIGHT` constant and its comment with:

```lua
-- The band's height in pixels. A plugin cannot read the bar's thickness -- barWidget
-- exposes only isVertical and outputName -- so this cannot be derived and has to be a
-- setting. The default fits a 42px bar (33px capsule) and a 34px bar (30px capsule) over
-- ~17px of digits; a thinner bar needs a smaller band or the slot clips.
local FLAME_HEIGHT_DEFAULT = 10
local FLAME_HEIGHT_MIN = 4
local FLAME_HEIGHT_MAX = 16
```

In `M.readConfig`, add after the `label_min_width` entry:

```lua
        flame_height = (function()
            local value = tonumber(noctalia.getConfig("flame_height")) or FLAME_HEIGHT_DEFAULT
            return math.max(FLAME_HEIGHT_MIN, math.min(FLAME_HEIGHT_MAX, math.floor(value)))
        end)(),
```

Change `M.flameBand`'s signature and its two uses of the old constant:

```lua
function M.flameBand(field, style, height)
    local band = height or FLAME_HEIGHT_DEFAULT
    if style ~= "bars" then
        local outer, inner = {}, {}
        for i = 1, FLAME_COLUMNS do
            outer[i] = field[i]
            inner[i] = field[i] * 0.55
        end
        return ui.graph({
            values = outer,
            values2 = inner,
            color = "#ff6a00",
            color2 = "#ffd27a",
            fillOpacity = 1.0,
            height = band,
        })
    end

    local bars = {}
    for i = 1, FLAME_COLUMNS do
        bars[i] = ui.box({
            flexGrow = 1,
            height = math.max(1, field[i] * band),
            fill = heatColor(field[i]),
            radius = 1,
        })
    end
    -- align = "end" puts them on a baseline so they grow upward.
    return ui.row({ align = "end", gap = 1, height = band }, bars)
end
```

Replace the tail of `M.buildTree` — everything from `local lit = config.highlight_gamer_mode` to the end of the function — with:

```lua
    -- The slot is reserved whenever the flame could appear, not only while it burns.
    -- Adding the band on toggle would change the content's height, and the shell centres
    -- content inside the capsule, so every digit would settle by half the band. A slot
    -- that is always there costs a constant offset instead, and a constant offset is
    -- invisible in a way that movement never is.
    --
    -- Reserving symmetrically -- a spacer above as well -- would keep the readout centred
    -- too, but at 2 * flame_height it overflows a 30px capsule and the bar clips its
    -- slots. That is the regression this widget already shipped once.
    if not (config.highlight_gamer_mode and config.flame ~= "off") then
        return readout
    end

    local lit = gm and gm.enabled and burning ~= nil
    return ui.column({ gap = 0 }, {
        readout,
        M.flameBand(lit and flameField or coldField, config.flame_style, config.flame_height),
    })
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./run-tests.sh 2>&1 | tail -5`
Expected: `all tests passed`.

- [ ] **Step 5: Add the setting**

In `gamer-mode/plugin.toml`, insert before the `flame` setting block:

```toml
[[widget.setting]]
key = "flame_height"
type = "int"
label_key = "settings.monitor.flame_height.label"
description_key = "settings.monitor.flame_height.description"
default = 10
min = 4
max = 16
```

In `gamer-mode/translations/en.json`, add to `settings.monitor`:

```json
"flame_height": {
  "label": "Flame height",
  "description": "Height of the flame band in pixels. Lower it on a thin bar, where a tall band leaves the readout no room."
}
```

In `gamer-mode/README.md`, add a row to the settings table:

```markdown
| Flame height | How tall the flame band is, in pixels. Lower it on a thin bar. | 10 |
```

- [ ] **Step 6: Run the tests again and commit**

Run: `./run-tests.sh 2>&1 | tail -5`
Expected: `all tests passed`.

```bash
git add gamer-mode/monitor.luau gamer-mode/plugin.toml gamer-mode/translations/en.json gamer-mode/README.md tests/monitor.lua
git commit -m "fix: reserve the band slot so the digits stop settling"
```

---

## Task 4: Audit fixes

Two defects the audit turned up. The tint floor is the one that matters: `error` at 0.55 alpha composites to a muted red that reads as *less* present than full-alpha `on_surface`, so crossing a threshold currently dims the text before it warms.

**Files:**
- Modify: `gamer-mode/monitor.luau` (`valueColor` near line 374)
- Modify: `gamer-mode/plugin.toml` (`label_min_width` block)
- Test: `tests/monitor.lua`

**Interfaces:**
- Consumes: `M.gradientFactor` (already present, unchanged).
- Produces: nothing new.

- [ ] **Step 1: Write the failing test**

Append to `tests/monitor.lua`, after the band-height block:

```lua
-- ── tint floor ──

-- Crossing a threshold must never make the value less visible than it was. The shell
-- lerps in HSV between two resolved colours; a plugin can read neither, so the ramp runs
-- through the role's alpha instead. That only works if the floor stays high enough that
-- a tinted value is at least as present as an untinted one.
local hotMetrics = helpers.copy(FULL)
hotMetrics.cpuPerc = 0.51
local justOver = monitor.formatSegments(hotMetrics, monitor.readConfig())[1]
assert(justOver.tint > 0, "51% is over the 50% activity threshold")

local alpha = tonumber(string.match(
    (function()
        local hot = monitor.buildTree(hotMetrics, off, monitor.readConfig(), false, nil)
        local group = hot.children[1].children[1]
        local segment = group.children[1]
        -- glyph first, then the label; each carries the value colour
        return segment.children[#segment.children].spec.color
    end)(),
    "^error/([%d%.]+)$"))
assert(alpha ~= nil, "a tinted value names the error role with an alpha")
assert(alpha >= 0.80, "the tint floor keeps the value present, got " .. tostring(alpha))
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./run-tests.sh 2>&1 | tail -5`
Expected: FAIL — `the tint floor keeps the value present, got 0.67`.

(At `cpuPerc = 0.51` the tint is `0.25 + 0.75 * (0.01 / 0.40) = 0.26875`, so the old floor
gives `0.55 + 0.45 * 0.26875 = 0.6709`, formatted `error/0.67`.)

- [ ] **Step 3: Write the implementation**

In `gamer-mode/monitor.luau`, in `valueColor`, replace:

```lua
    return string.format("error/%.2f", 0.55 + 0.45 * segment.tint)
```

with:

```lua
    -- The floor is high on purpose. Alpha is the only ramp available, and a low floor
    -- makes the value *dimmer* the moment it crosses its activity threshold -- the
    -- opposite of what the threshold is for.
    return string.format("error/%.2f", 0.80 + 0.20 * segment.tint)
```

In `gamer-mode/plugin.toml`, in the `label_min_width` block, change `max = 120` to `max = 200`, matching the shell's own field.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./run-tests.sh 2>&1 | tail -5`
Expected: `all tests passed`.

- [ ] **Step 5: Commit**

```bash
git add gamer-mode/monitor.luau gamer-mode/plugin.toml tests/monitor.lua
git commit -m "fix: stop a warming value from dimming as it crosses"
```

---

# Stage 2 — Panel information

## Task 5: Tint the panel's progress fills

Every panel bar is `primary` whatever the reading, which now contradicts the bar widget. Give each row the same thresholds and the same curve.

**Files:**
- Modify: `gamer-mode/panel.luau` (`M.buildRows` near line 141; `metricRow` near line 302)
- Test: `tests/panel.lua`

**Interfaces:**
- Consumes: nothing from Stage 1. Stage 2 does not depend on Stage 1 and may be implemented independently.
- Produces: `M.gradientFactor(value, activity, critical) -> number` on the panel module — the same curve as `monitor.luau`'s, duplicated because sandboxed entries cannot share a module. Each row from `M.buildRows` gains `activity: number` and `critical: number`. `M.barFill(row) -> string` returns the fill colour token.

- [ ] **Step 1: Write the failing test**

Append at the **end** of `tests/panel.lua`. Every panel block in this plan appends at the end, after the existing handler-wiring section, so `rendered` and `flatten` are already defined and populated:

```lua
-- ── threshold tinting ──

-- The same curve and the same thresholds as the shell's sysmon widgets, so the panel and
-- the bar agree about what "hot" means.
assert(p.gradientFactor(0.10, 0.50, 0.90) == 0, "below activity stays cold")
assert(p.gradientFactor(0.50, 0.50, 0.90) == 0, "at activity is still cold")
assert(p.gradientFactor(0.95, 0.50, 0.90) == 1, "past critical is fully hot")
local onset = p.gradientFactor(0.51, 0.50, 0.90)
assert(onset >= 0.25 and onset < 0.30,
    "crossing jumps to the onset tint, got " .. tostring(onset))
assert(p.gradientFactor(nil, 0.50, 0.90) == 0, "no reading is not a hot reading")
-- Pin the interior slope too. The onset band alone also passes for a wrong denominator,
-- so a broken ramp would ship green. Tolerance rather than equality: 0.70 - 0.50 is not
-- bit-equal to 0.2 in double precision.
assert(math.abs(p.gradientFactor(0.70, 0.50, 0.90) - 0.625) < 1e-9,
    "the ramp is linear between the thresholds, got " .. tostring(p.gradientFactor(0.70, 0.50, 0.90)))

-- Every row heats on its own progress value, which is already the fraction the bar draws.
local cool = p.buildRows({
    available = true, cpuPerc = 0.10, memPerc = 0.10,
    memUsedMb = 1024, memTotalMb = 32768,
}, false)
assert(cool[1].label == "CPU", "cpu leads the rows")
assert(cool[1].activity == 0.50 and cool[1].critical == 0.90, "cpu uses 50/90")
assert(p.barFill(cool[1]) == "primary", "a cool row keeps the accent colour")

local hot = p.buildRows({
    available = true, cpuPerc = 0.98, memPerc = 0.10,
    memUsedMb = 1024, memTotalMb = 32768,
}, false)
local fill = p.barFill(hot[1])
assert(string.match(fill, "^error/"), "a critical row warms to error, got " .. fill)
local hotAlpha = tonumber(string.match(fill, "^error/([%d%.]+)$"))
assert(hotAlpha >= 0.80, "the panel shares the bar's tint floor, got " .. tostring(hotAlpha))

-- The wiring, not just the helper. Asserting only on barFill would let the metricRow edit
-- be skipped entirely with the suite still green.
noctalia.state.set("metrics", {
    available = true, cpuPerc = 0.98, memPerc = 0.10,
    memUsedMb = 1024, memTotalMb = 32768,
})
local sawHotBar = false
for _, node in ipairs(flatten(rendered)) do
    if node.kind == "progress" and type(node.spec.fill) == "string"
        and node.spec.fill:match("^error/") then
        sawHotBar = true
    end
end
assert(sawHotBar, "a critical reading renders a warmed progress fill")

-- RAM at 60/90, swap at 20/80, gpu at 50/95, vram at 50/90 -- the shell's defaults.
local all = p.buildRows({
    available = true, cpuPerc = 0.1, memPerc = 0.1,
    memUsedMb = 1024, memTotalMb = 32768,
    swapPerc = 0.1, swapUsedMb = 128, swapTotalMb = 8192,
    gpuAvailable = true, gpuPerc = 0.1, vramPerc = 0.1,
    vramUsedMb = 512, vramTotalMb = 8188,
}, false)
local expected = {
    CPU = { 0.50, 0.90 }, RAM = { 0.60, 0.90 }, Swap = { 0.20, 0.80 },
    GPU = { 0.50, 0.95 }, VRAM = { 0.50, 0.90 },
}
assert(#all == 5, "all five rows are built, got " .. #all)
for _, row in ipairs(all) do
    local want = expected[row.label]
    assert(want, "unexpected row " .. tostring(row.label))
    assert(row.activity == want[1] and row.critical == want[2],
        row.label .. " thresholds are " .. tostring(row.activity) .. "/" .. tostring(row.critical))
end
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./run-tests.sh 2>&1 | tail -5`
Expected: FAIL — `attempt to call a nil value (field 'gradientFactor')`.

- [ ] **Step 3: Write the implementation**

In `gamer-mode/panel.luau`, add above `M.buildRows`:

```lua
-- The shell tints a sysmon value from its normal colour towards the highlight colour as
-- the metric climbs, holding flat below the activity threshold and saturating at the
-- critical one, with a jump to kActivityOnset the moment it crosses (sysmon_widget.cpp
-- gradientFactor). Duplicated from monitor.luau rather than shared: plugin entries run in
-- separate sandboxed Luau states with no `require`.
local ACTIVITY_ONSET = 0.25

function M.gradientFactor(value, activity, critical)
    if value == nil or activity == nil or critical == nil then
        return 0
    end
    local v = math.max(value, 0)
    local top = math.max(critical, 0)
    if top <= 0 or v <= 0 then
        return 0
    end
    local floor = math.max(0, math.min(activity, top))
    if v <= floor then
        return 0
    end
    if v >= top then
        return 1
    end
    return ACTIVITY_ONSET + (1 - ACTIVITY_ONSET) * (v - floor) / (top - floor)
end

-- Every row's `progress` is already the fraction the shell would gradient on, so the bar
-- and the reading cannot disagree.
function M.barFill(row)
    local tint = M.gradientFactor(row.progress, row.activity, row.critical)
    if tint <= 0 then
        return "primary"
    end
    return string.format("error/%.2f", 0.80 + 0.20 * tint)
end
```

In `M.buildRows`, add thresholds to each row. CPU:

```lua
    rows[#rows + 1] = {
        label = "CPU",
        glyph = "cpu-usage",
        progress = clamp(m.cpuPerc),
        activity = 0.50,
        critical = 0.90,
        detail = withTemp(percent(m.cpuPerc), showTemps, m.cpuTemp),
    }
```

RAM gains `activity = 0.60, critical = 0.90`. Swap gains `activity = 0.20, critical = 0.80`. GPU gains `activity = 0.50, critical = 0.95`. VRAM gains `activity = 0.50, critical = 0.90`. Add the two fields to each existing table literal; change nothing else about them.

In `metricRow`, change the progress fill:

```lua
        ui.progress({
            height = 4,
            progress = row.progress,
            fill = M.barFill(row),
            track = "surface_variant",
            radius = 2,
        }),
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./run-tests.sh 2>&1 | tail -5`
Expected: `all tests passed`.

- [ ] **Step 5: Commit**

```bash
git add gamer-mode/panel.luau tests/panel.lua
git commit -m "feat: warm the panel bars at the same thresholds as the bar"
```

---

## Task 6: Hierarchy, and one row builder

Everything in the panel is `on_surface_variant`, so a reading reads no louder than its caption. Promote the readings, and collapse the two near-identical row builders now that they differ only by whether a bar is present.

**Files:**
- Modify: `gamer-mode/panel.luau` (`metricRow` and `figureRow` near lines 302-330; `body` near line 491)
- Test: `tests/panel.lua`

**Interfaces:**
- Consumes: `M.barFill` from Task 5.
- Produces: a single file-local `readingRow(entry, withBar)` replacing `metricRow` and `figureRow`. Not exported; Task 7 and Task 8 do not call it.

- [ ] **Step 1: Write the failing test**

Append at the **end** of `tests/panel.lua`, after the previous task's block:

```lua
-- ── hierarchy ──

-- A reading must outrank its caption. Everything used to be on_surface_variant, which
-- gave a wall of equally dim text with no entry point.
local function findLabels(node, out)
    out = out or {}
    if type(node) ~= "table" then return out end
    if node.kind == "label" then out[#out + 1] = node.spec end
    for _, child in ipairs(node.children or {}) do findLabels(child, out) end
    return out
end

noctalia.state.set("metrics", {
    available = true, cpuPerc = 0.5, memPerc = 0.5,
    memUsedMb = 16384, memTotalMb = 32768,
})
local labels = findLabels(rendered)
local captions, readings = 0, 0
for _, spec in ipairs(labels) do
    if spec.color == "on_surface_variant" then captions = captions + 1 end
    if spec.color == "on_surface" then readings = readings + 1 end
end
assert(captions > 0, "captions stay dimmed")
assert(readings > 0, "readings are promoted to on_surface")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./run-tests.sh 2>&1 | tail -5`
Expected: FAIL — `readings are promoted to on_surface`.

- [ ] **Step 3: Write the implementation**

In `gamer-mode/panel.luau`, replace both `metricRow` and `figureRow` with one builder:

```lua
-- One builder for readings with a bar and readings without. After the hierarchy pass the
-- two differed only by the progress node, and keeping two copies meant every colour
-- decision had to be made twice.
local function readingRow(entry, withBar)
    local line = ui.row({ align = "center", gap = 8 }, {
        ui.glyph({ name = entry.glyph, size = 14, color = "on_surface_variant" }),
        ui.label({ text = entry.label, color = "on_surface_variant", width = 48 }),
        -- A spacer pushes the detail right. `align` is not a label prop: setting it left
        -- the text unaligned and the shell logged a warning on every render.
        ui.spacer({ flexGrow = 1 }),
        ui.label({ text = entry.detail, color = "on_surface", fontSize = 11 }),
    })
    if not withBar then
        return line
    end
    return ui.column({ gap = 4 }, {
        line,
        ui.progress({
            height = 4,
            progress = entry.progress,
            fill = M.barFill(entry),
            track = "surface_variant",
            radius = 2,
        }),
    })
end
```

In `body`, change the two call sites:

```lua
        for _, row in ipairs(rows) do
            children[#children + 1] = readingRow(row, true)
        end
        for _, figure in ipairs(M.buildFigures(metrics)) do
            children[#children + 1] = readingRow(figure, false)
        end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./run-tests.sh 2>&1 | tail -5`
Expected: `all tests passed`.

- [ ] **Step 5: Commit**

```bash
git add gamer-mode/panel.luau tests/panel.lua
git commit -m "refactor: let the readings outrank their captions"
```

---

# Stage 3 — Panel mark and chrome

## Task 7: Redraw the mark, and give it a light ramp

The current mark is three hand-plotted flames that mush together at 42px. Redraw it as two bold shapes, and ship a light variant so it does not stay a dark-theme mark on a light theme.

**Files:**
- Modify: `gamer-mode/panel.luau` (`LOGO_SVG` constant; `logoPath` near line 95)
- Test: `tests/panel.lua`

**Interfaces:**
- Consumes: nothing from Tasks 5-6.
- Produces: `M.logoVariant(dark: boolean) -> string` returning the filename (`"logo-dark.svg"` or `"logo-light.svg"`). Task 8 does not call it; `logoPath` does.

- [ ] **Step 1: Write the failing test**

Append at the **end** of `tests/panel.lua`, after the previous task's block:

```lua
-- ── the mark ──

-- Two files, never one path rewritten. Textures are cached by {path, targetSize}, so
-- rewriting logo.svg in place would keep serving the previous theme's raster.
assert(p.logoVariant(true) == "logo-dark.svg", "dark theme picks the dark mark")
assert(p.logoVariant(false) == "logo-light.svg", "light theme picks the light mark")
assert(p.logoVariant(true) ~= p.logoVariant(false),
    "the variants are distinct paths or the cache serves a stale raster")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./run-tests.sh 2>&1 | tail -5`
Expected: FAIL — `attempt to call a nil value (field 'logoVariant')`.

- [ ] **Step 3: Write the implementation**

In `gamer-mode/panel.luau`, replace the `LOGO_SVG` constant with two. The mark is one bold flame with an inner core — two shapes rather than three overlapping ones, because at 42px the old outlines merged into a single orange blob:

```lua
local LOGO_SVG_DARK = [[<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="100%" height="100%">
  <defs>
    <linearGradient id="body" x1="0" y1="1" x2="0" y2="0">
      <stop offset="0" stop-color="#B3200E"/>
      <stop offset="0.45" stop-color="#F0630A"/>
      <stop offset="1" stop-color="#FFC02E"/>
    </linearGradient>
    <linearGradient id="core" x1="0" y1="1" x2="0" y2="0">
      <stop offset="0" stop-color="#FFB020"/>
      <stop offset="1" stop-color="#FFF3B0"/>
    </linearGradient>
  </defs>
  <path fill="url(#body)" d="M32 4 C 38 18, 50 24, 50 38 A 18 18 0 0 1 14 38 C 14 27, 22 24, 24 14 C 29 19, 30 27, 28 33 C 31 28, 33 16, 32 4 Z"/>
  <path fill="url(#core)" d="M32 30 C 36 36, 40 39, 40 44 A 8 8 0 0 1 24 44 C 24 39, 29 36, 32 30 Z"/>
</svg>]]

-- Deeper stops so the mark still has contrast against a light surface. The palette is not
-- readable from a plugin, so this is a fixed pair rather than a derived colour.
local LOGO_SVG_LIGHT = [[<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 64 64" width="100%" height="100%">
  <defs>
    <linearGradient id="body" x1="0" y1="1" x2="0" y2="0">
      <stop offset="0" stop-color="#8C1408"/>
      <stop offset="0.45" stop-color="#D24A05"/>
      <stop offset="1" stop-color="#E89100"/>
    </linearGradient>
    <linearGradient id="core" x1="0" y1="1" x2="0" y2="0">
      <stop offset="0" stop-color="#E08A00"/>
      <stop offset="1" stop-color="#FFD867"/>
    </linearGradient>
  </defs>
  <path fill="url(#body)" d="M32 4 C 38 18, 50 24, 50 38 A 18 18 0 0 1 14 38 C 14 27, 22 24, 24 14 C 29 19, 30 27, 28 33 C 31 28, 33 16, 32 4 Z"/>
  <path fill="url(#core)" d="M32 30 C 36 36, 40 39, 40 44 A 8 8 0 0 1 24 44 C 24 39, 29 36, 32 30 Z"/>
</svg>]]
```

Add the variant chooser and rewrite `logoPath`:

```lua
-- Distinct filenames per variant, never one path rewritten: the texture cache is keyed by
-- {path, targetSize}, so overwriting logo.svg would keep serving the old theme's raster.
function M.logoVariant(dark)
    return dark and "logo-dark.svg" or "logo-light.svg"
end

local function logoPath()
    local directory = noctalia.pluginDataDir()
    if not directory then
        return nil
    end
    -- There is no theme-change callback, so the variant is resolved on every render. It
    -- is a filename comparison and a fileExists in the common case.
    local dark = noctalia.isDarkMode() ~= false
    local path = directory .. "/" .. M.logoVariant(dark)
    if not noctalia.fileExists(path) then
        if not noctalia.writeFile(path, dark and LOGO_SVG_DARK or LOGO_SVG_LIGHT) then
            noctalia.log("gamermode: could not write the panel logo")
            return nil
        end
    end
    return path
end
```

If the test harness's mock lacks `isDarkMode`, add it to `helpers.newNoctalia` beside `mock.commandExists`:

```lua
    mock.isDarkMode = function()
        return opts.darkMode ~= false
    end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./run-tests.sh 2>&1 | tail -5`
Expected: `all tests passed`.

- [ ] **Step 5: Remove the stale asset and commit**

The old `gamer-mode/logo.svg` is no longer referenced by `panel.luau`. Check whether anything else uses it first:

```bash
grep -rn "logo.svg" gamer-mode/ tests/ docs/ || echo "no remaining references"
```

Delete it only if that prints `no remaining references`; `tests/logo.lua` may assert on it, in which case update that test to the new variants instead.

```bash
git add -A gamer-mode/ tests/
git commit -m "feat: redraw the mark and give it a light ramp"
```

---

## Task 8: Frame tick and the halo

Drive the mark's halo from the panel's vsync tick while gamer mode is on, and release the tick when it goes off.

**Files:**
- Modify: `gamer-mode/panel.luau` (`header` near line 343; the state watchers near line 616; new global `onFrameTick`)
- Test: `tests/panel.lua`

**Interfaces:**
- Consumes: `M.logoVariant` from Task 7.
- Produces: `M.haloSpec(phase: number, heat: number) -> {border: string, borderWidth: number}` — pure, so the animation is assertable without a clock. A global `onFrameTick(deltaMs)`. A file-local `haloPhase` advanced by it.

- [ ] **Step 1: Write the failing test**

Append at the **end** of `tests/panel.lua`, after the previous task's block:

```lua
-- ── halo ──

-- A glow behind the mark is impossible: there is no stack, overlay or z-index node, so
-- the halo is an animated border ring on the image itself. ui.image takes border and
-- borderWidth, and a hex colour carries its own alpha byte.
local calm = p.haloSpec(0, 0)
local fierce = p.haloSpec(0, 1)
assert(fierce.borderWidth > calm.borderWidth, "more heat means a thicker ring")
assert(string.match(fierce.border, "^#%x%x%x%x%x%x%x%x$"),
    "the ring carries its own alpha, got " .. tostring(fierce.border))

-- It pulses: the same heat at different points in the cycle differs.
-- Quadrature, not antiphase: sin(0) and sin(pi) are each ~0, so comparing those two
-- phases compares identical output and the assertion fails after the change.
local a = p.haloSpec(0, 0.6)
local b = p.haloSpec(math.pi / 2, 0.6)
assert(a.border ~= b.border or a.borderWidth ~= b.borderWidth,
    "the halo animates across the phase")

-- The tick is a cost, so it is only requested while the mode is on.
_G.panel.frameTick = nil
noctalia.state.set("game_mode", { enabled = true, busy = false, suspended = {} })
assert(_G.panel.frameTick == true, "gamer mode on raises the frame tick")
noctalia.state.set("game_mode", { enabled = false, busy = false, suspended = {} })
assert(_G.panel.frameTick == false, "gamer mode off releases it")
```

Add `setNeedsFrameTick` to the panel mock at the top of `tests/panel.lua`:

```lua
_G.panel = {
    render = function(tree)
        rendered = tree
    end,
    close = function()
        _G.panel.closed = true
    end,
    setNeedsFrameTick = function(wants)
        _G.panel.frameTick = wants
    end,
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./run-tests.sh 2>&1 | tail -5`
Expected: FAIL — `attempt to call a nil value (field 'haloSpec')`.

- [ ] **Step 3: Write the implementation**

In `gamer-mode/panel.luau`, add above `header`:

```lua
-- How hard the machine is working, 0..1, mirroring monitor.luau's heatOf. Usage leads
-- because that is what a player feels; temperature follows.
local function heatOf(m)
    if not (type(m) == "table" and m.available) then
        return 0
    end
    local gpuUsage = 0
    if m.gpuAvailable and tonumber(m.gpuPerc) then
        gpuUsage = tonumber(m.gpuPerc)
    end
    local usage = math.max(tonumber(m.cpuPerc) or 0, gpuUsage)
    local hottest = math.max(tonumber(m.cpuTemp) or 0, tonumber(m.gpuTemp) or 0)
    local tempHeat = 0
    if hottest > 0 then
        tempHeat = math.max(0, math.min(1, (hottest - 50) / 40))
    end
    return math.max(0, math.min(1, usage * 0.7 + tempHeat * 0.3))
end

local haloPhase = 0

-- A ring, not a bloom. Nothing can be drawn behind the mark -- the tree is pure flexbox
-- with no stack or z-index -- so the halo is ui.image's own border, animated per frame.
-- Hex is used rather than a role token because fire is not a theme colour, and because a
-- role's alpha suffix cannot be pulsed below the role's own resolved alpha.
function M.haloSpec(phase, heat)
    local hot = math.max(0, math.min(1, tonumber(heat) or 0))
    local pulse = 0.5 + 0.5 * math.sin(tonumber(phase) or 0)
    local intensity = 0.25 + 0.75 * hot
    local alpha = math.floor((0.20 + 0.55 * intensity * pulse) * 255 + 0.5)
    -- Warmer and brighter as it climbs: red at rest, amber under load.
    local red = 255
    local green = math.floor(90 + 110 * hot + 0.5)
    local blue = math.floor(20 + 40 * hot * pulse + 0.5)
    return {
        border = string.format("#%02x%02x%02x%02x", red, green, blue, alpha),
        borderWidth = 1 + 2 * intensity * pulse,
    }
end
```

In `header`, apply the halo to the image when the mode is on:

```lua
local function header()
    local logo = logoPath()
    local mark
    if logo then
        -- radius is set unconditionally: putting it inside the branch would pop the mark
        -- between square and circular every time the mode is toggled.
        local props = { path = logo, width = 42, height = 42, fit = "contain", radius = 21 }
        if gameMode.enabled then
            local halo = M.haloSpec(haloPhase, heatOf(metrics))
            props.border = halo.border
            props.borderWidth = halo.borderWidth
        end
        mark = ui.image(props)
    else
        -- The glyph is the fallback for the one case that can fail: no plugin data
        -- directory to write the logo into.
        mark = ui.glyph({ name = "device-gamepad-2", size = 22, color = "primary" })
    end

    return ui.row({ align = "center", gap = 10 }, {
        mark,
        ui.column({ gap = 0, flexGrow = 1 }, {
            ui.label({ text = tr("panel.title"), fontSize = 17, fontWeight = "bold" }),
            ui.label({
                text = gameMode.enabled and tr("panel.state_on") or tr("panel.state_off"),
                fontSize = 11,
                color = gameMode.enabled and "primary" or "on_surface_variant",
            }),
        }),
        toggleButton(),
        -- The panel also dismisses on an outside click, but a visible control is the one
        -- people look for, and every other panel in the shell has one.
        ui.button({ glyph = "close", variant = "ghost", tooltip = tr("panel.close"), onClick = "onCloseClicked" }),
    })
end
```

Add the frame-tick lifecycle. Put this helper above the state watchers, and call it from the `game_mode` watcher:

```lua
-- Vsync ticks are coalesced and stop dead while the panel is closed, but they are still a
-- cost, so they are only asked for while there is something to animate.
local function syncFrameTick()
    if panel.setNeedsFrameTick then
        panel.setNeedsFrameTick(gameMode.enabled == true)
    end
end
```

In the `game_mode` watcher, add `syncFrameTick()` immediately before its `render()` call.

Watchers fire on *change*, so that alone leaves the halo frozen when the panel is opened
while gamer mode is already on — the common case. Call it from `onOpen` too, immediately
after its existing `render()`:

```lua
    syncFrameTick()
```

If `onOpen` is not present in `panel.luau`, add the same line at the end of `onActivate`.

Add the global at the bottom of the file, beside the other shell entry points:

```lua
-- ── shell entry points (must be globals) ──

-- Called at vsync while the panel is open and something is animating. Advancing a phase
-- and re-rendering is the whole of it; the halo is a pure function of that phase.
function onFrameTick(deltaMs)
    if not gameMode.enabled then
        return
    end
    haloPhase = (haloPhase + (tonumber(deltaMs) or 16) * 0.0025) % (math.pi * 2)
    render()
end
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./run-tests.sh 2>&1 | tail -5`
Expected: `all tests passed`.

- [ ] **Step 5: Commit**

```bash
git add gamer-mode/panel.luau tests/panel.lua
git commit -m "feat: ring the mark with a halo that answers to load"
```

---

## Task 9: Header ember

A soft accent under the header that breathes while the mode is on, so the panel reads as live rather than as a form.

**Files:**
- Modify: `gamer-mode/panel.luau` (`body` near line 491)
- Test: `tests/panel.lua`

**Interfaces:**
- Consumes: `haloPhase` and `heatOf` from Task 8.
- Produces: `M.emberSpec(phase: number, heat: number) -> {fill: string, opacity: number, softness: number}`.

- [ ] **Step 1: Write the failing test**

Append at the **end** of `tests/panel.lua`, after the previous task's block:

```lua
-- ── header ember ──

local dim = p.emberSpec(0, 0)
local bright = p.emberSpec(0, 1)
assert(bright.opacity > dim.opacity, "more heat means a brighter ember")
assert(bright.softness > 0, "the ember has a soft edge, not a hard rule")
-- Quadrature for the same reason as the halo: sin(0) == sin(pi) ~= a different pulse.
assert(p.emberSpec(0, 0.5).opacity ~= p.emberSpec(math.pi / 2, 0.5).opacity,
    "the ember breathes across the phase")
-- The opacity is clamped in the implementation, so asserting 0..1 could never fail.
-- Assert the useful property instead: it actually varies across the cycle rather than
-- sitting at one value.
local seen = {}
for _, phase in ipairs({ 0, 1, 2, 3, 4, 5, 6 }) do
    seen[string.format("%.4f", p.emberSpec(phase, 1).opacity)] = true
end
local distinct = 0
for _ in pairs(seen) do distinct = distinct + 1 end
assert(distinct >= 4, "the ember takes several values across a cycle, got " .. distinct)

-- It is only drawn while the mode is on; an idle panel is a plain form.
local function countBoxes(node)
    if type(node) ~= "table" then return 0 end
    local n = (node.kind == "box") and 1 or 0
    for _, child in ipairs(node.children or {}) do n = n + countBoxes(child) end
    return n
end
-- Counting boxes alone would also count anything else the enabled state adds, so match
-- the ember's own fill. That is what makes this fail if the ember specifically is gone.
local function hasEmber(node)
    if type(node) ~= "table" then return false end
    if node.kind == "box" and node.spec and node.spec.softness ~= nil
        and type(node.spec.fill) == "string" and node.spec.fill:match("^#ff%x%x%x%x$") then
        return true
    end
    for _, child in ipairs(node.children or {}) do
        if hasEmber(child) then return true end
    end
    return false
end
noctalia.state.set("game_mode", { enabled = false, busy = false, suspended = {} })
assert(not hasEmber(rendered), "an idle panel has no ember")
local quiet = countBoxes(rendered)
noctalia.state.set("game_mode", { enabled = true, busy = false, suspended = {} })
assert(hasEmber(rendered), "gamer mode adds the ember")
assert(countBoxes(rendered) > quiet, "and it is a new node, not a recoloured one")
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `./run-tests.sh 2>&1 | tail -5`
Expected: FAIL — `attempt to call a nil value (field 'emberSpec')`.

- [ ] **Step 3: Write the implementation**

In `gamer-mode/panel.luau`, add beside `M.haloSpec`:

```lua
-- A soft bar under the header that breathes. ui.box's softness is what keeps it from
-- reading as a second separator; a hard 2px rule there just looks like a mistake.
function M.emberSpec(phase, heat)
    local hot = math.max(0, math.min(1, tonumber(heat) or 0))
    local pulse = 0.5 + 0.5 * math.sin(tonumber(phase) or 0)
    local opacity = 0.18 + 0.42 * (0.3 + 0.7 * hot) * pulse
    return {
        fill = string.format("#ff%02x1e", math.floor(90 + 110 * hot + 0.5)),
        opacity = math.max(0, math.min(1, opacity)),
        softness = 2 + 2 * hot,
    }
end
```

In `body`, insert the ember directly after the header's separator — that is, as the first thing added to `children`:

```lua
local function body()
    local showTemps = noctalia.getConfig("show_temps") ~= false
    local children = {}

    if gameMode.enabled then
        local ember = M.emberSpec(haloPhase, heatOf(metrics))
        children[#children + 1] = ui.box({
            height = 2,
            radius = 1,
            fill = ember.fill,
            opacity = ember.opacity,
            softness = ember.softness,
        })
    end

    local rows = M.buildRows(metrics, showTemps)
```

Leave the rest of `body` unchanged.

- [ ] **Step 4: Run the tests to verify they pass**

Run: `./run-tests.sh 2>&1 | tail -5`
Expected: `all tests passed`.

- [ ] **Step 5: Update the README and commit**

Add to `gamer-mode/README.md`, in or after the section describing the panel:

```markdown
### While gamer mode is on

The panel mark gains a ring that thickens and warms with real load, and a soft ember
breathes under the header. Each is driven by the panel's vsync frame tick, which the
shell stops while the panel is closed — an idle or closed panel costs nothing.
```

```bash
git add gamer-mode/panel.luau gamer-mode/README.md tests/panel.lua
git commit -m "feat: breathe an ember under the panel header"
```

---

## Final verification

- [ ] **Run the full suite**

Run: `./run-tests.sh`
Expected: `all tests passed`, 18 suites.

- [ ] **Confirm the capsule geometry did not regress**

This widget has shipped a capsule regression twice. On a machine running the shell:

```bash
export XDG_RUNTIME_DIR=/run/user/1000 WAYLAND_DISPLAY=wayland-1
noctalia msg plugins update <source-name>
noctalia msg config-reload
```

Then capture a frame and check that the plugin's capsule occupies the same rows as a
built-in sysmon `capsule_group` on the same bar. They must match exactly; the shell sizes
each the same way.

- [ ] **Confirm the digits do not settle**

Toggle gamer mode with `noctalia msg plugin nomadcxx/gamer-mode:service all enable`, then
`disable`. The digits must not move vertically between the two states. If they do, the
band slot is not being reserved when unlit — re-read Task 3.
