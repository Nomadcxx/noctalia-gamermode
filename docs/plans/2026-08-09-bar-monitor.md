# Bar Monitor Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a second bar widget that renders a live metrics readout good enough to replace a row of Noctalia's built-in `sysmon` widgets, with a gamer-mode highlight the built-in cannot provide.

**Architecture:** A new `monitor.luau` entry watches the `metrics` and `game_mode` state the service already publishes and renders a declarative `barWidget.render()` tree. It owns no state, polls nothing, and spawns nothing. The existing toggle widget stays imperative and gains custom-icon settings and tooltip rows.

**Tech Stack:** Luau (Noctalia plugin API 19), sandboxed — no `io`, no `os`, no `require`. Tests run under plain `lua` against the `tests/helpers.lua` mock. Design: `docs/plans/2026-08-09-bar-monitor-design.md`.

## Global Constraints

- `plugin_api` stays **19**. Nothing in this plan is gated above it.
- `version` in `gamer-mode/plugin.toml` is bumped exactly once, to **0.7.0**, in Task 8. Semver `MAJOR.MINOR.PATCH` only — CI enforces `^\d+\.\d+\.\d+$`.
- **Entry scripts cannot share code.** There is no `require` in the sandbox. Formatting helpers are duplicated into `monitor.luau` deliberately; do not attempt to factor them into a shared file.
- **A setting must be declared in `plugin.toml` before any script reads it.** `noctalia.getConfig` on an undeclared key logs `plugin ... read undeclared setting` and returns `nil`.
- Every user-visible string goes through `noctalia.tr(key)` with the key defined in `gamer-mode/translations/en.json`.
- `./run-tests.sh` must be green at the end of every task. It runs every `tests/*.lua`, every `tests/*.sh`, and `loadfile`-checks every `gamer-mode/*.luau`.
- **Commit messages must not contain AI or agent attribution.** No `Co-Authored-By: Claude` trailer. The repo hook rejects it. Pre-check with `sh /home/nomadx/.git-hooks/commit-msg <file>` before committing if unsure.
- Never create or edit `catalog.toml`. Upstream CI generates it.
- **The mock is not the API.** `tests/helpers.lua` exposes some bindings at a different path than the shell does — `mock.trim` against the real `noctalia.string.trim`, for one. Check `/home/nomadx/noctalia/src/scripting/luau_host.cpp` before relying on any binding the plugin does not already use.
- `description` in `plugin.toml` stays at or below 120 characters.

## File Structure

| File | Responsibility |
|---|---|
| `gamer-mode/monitor.luau` | **New.** The readout: config reading, segment formatting, tree building, tooltip rows, flare timing. Self-contained. |
| `gamer-mode/widget.luau` | Existing toggle. Gains custom icons and tooltip rows. No other change. |
| `gamer-mode/plugin.toml` | Declares the `monitor` entry, its per-instance settings, and the toggle's icon settings. |
| `gamer-mode/translations/en.json` | Labels and descriptions for every new setting, plus tooltip row labels. |
| `tests/monitor.lua` | **New.** The 18th suite. Covers the readout end to end. |
| `tests/widget.lua` | Existing. Updated for tooltip rows and icons. |
| `gamer-mode/README.md` | User-facing documentation for both entries. |

`monitor.luau` stays one file. It is expected to land around 260 lines, which is smaller than `widget.luau` plus `panel.luau` and well within what one file should hold.

---

### Task 1: Monitor entry renders the default segments

**Files:**
- Create: `gamer-mode/monitor.luau`
- Create: `tests/monitor.lua`
- Modify: `gamer-mode/plugin.toml` (new `[[widget]]` entry and its `show_*` settings)
- Modify: `gamer-mode/translations/en.json`

**Interfaces:**
- Consumes: `noctalia.state` keys `metrics` and `game_mode`, as published by `service.luau`.
- Produces:
  - `M.readConfig() -> table` with boolean fields `show_cpu`, `show_cpu_temp`, `show_ram`, `show_swap`, `show_gpu`, `show_gpu_temp`, `show_vram`, `show_load`, `show_net`, `show_glyphs`.
  - `M.formatSegments(metrics: table, config: table) -> array` of `{ id, group, glyph, width, text }` in fixed display order.
  - `M.buildTree(metrics, gameMode, config) -> uiNode`.

- [ ] **Step 1: Write the failing test**

Create `tests/monitor.lua`:

```lua
-- Bar monitor: the metrics readout. The declarative ui.* tree is captured so the test
-- can assert on what was actually rendered rather than on a formatted string.
package.path = "./tests/?.lua;" .. package.path
local helpers = require("helpers")

_G.ui = setmetatable({}, {
    __index = function(_, name)
        return function(spec, children)
            return { kind = name, spec = spec or {}, children = children }
        end
    end,
})

local rendered = nil
local vertical = false
_G.barWidget = {
    render = function(tree)
        rendered = tree
    end,
    setTooltip = function(value)
        _G.barWidget.tooltip = value
    end,
    isVertical = function()
        return vertical
    end,
}

local FULL = {
    available = true,
    cpuPerc = 0.12,
    cpuTemp = 45,
    memUsedMb = 8601,
    memTotalMb = 32768,
    swapUsedMb = 512,
    swapTotalMb = 8192,
    swapPerc = 0.0625,
    gpuAvailable = true,
    gpuPerc = 0.63,
    gpuTemp = 71,
    vramUsedMb = 2150,
    vramTotalMb = 8188,
    load1 = 1.25,
    load5 = 0.98,
    load15 = 0.75,
    netRxPerSec = 561152,
    netTxPerSec = 874496,
}

local mock = helpers.newNoctalia({ config = {} })
mock.published.metrics = helpers.copy(FULL)
mock.published.game_mode = { enabled = false, suspended = {} }

local monitor = dofile("gamer-mode/monitor.luau")

-- ── defaults ──

local config = monitor.readConfig()
assert(config.show_cpu == true, "cpu on by default")
assert(config.show_swap == false, "swap off by default")
assert(config.show_vram == false, "vram off by default")
assert(config.show_load == false, "load off by default")
assert(config.show_net == true, "network on by default")
assert(config.show_glyphs == true, "glyphs on by default")

local segments = monitor.formatSegments(FULL, config)
local ids = {}
for index, segment in ipairs(segments) do
    ids[index] = segment.id
end
local order = table.concat(ids, ",")
assert(order == "cpu,cpu_temp,ram,gpu,gpu_temp,net_rx,net_tx",
    "default segments in fixed order, got: " .. order)

assert(segments[1].text == "12%", "cpu percentage, got " .. segments[1].text)
assert(segments[2].text == "45°", "cpu temperature, got " .. segments[2].text)
assert(segments[3].text == "8.4G", "ram in GiB, got " .. segments[3].text)
assert(segments[6].text == "548K", "rx rate, got " .. segments[6].text)

-- ── it renders on load and on every state change ──

assert(rendered ~= nil, "the widget renders as soon as it loads")

rendered = nil
mock.state.set("metrics", helpers.copy(FULL))
assert(rendered ~= nil, "a new metrics sample re-renders")

rendered = nil
mock.state.set("game_mode", { enabled = true, suspended = {} })
assert(rendered ~= nil, "a gamer-mode change re-renders")

print("monitor: passed")
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `lua tests/monitor.lua`
Expected: FAIL — `cannot open gamer-mode/monitor.luau`.

- [ ] **Step 3: Declare the entry and its settings**

Append to `gamer-mode/plugin.toml`, after the existing `[[widget]]` block:

```toml
[[widget]]
id = "monitor"
entry = "monitor.luau"

[[widget.setting]]
key = "show_cpu"
type = "bool"
label_key = "settings.monitor.show_cpu.label"
description_key = "settings.monitor.show_cpu.description"
default = true

[[widget.setting]]
key = "show_cpu_temp"
type = "bool"
label_key = "settings.monitor.show_cpu_temp.label"
default = true

[[widget.setting]]
key = "show_ram"
type = "bool"
label_key = "settings.monitor.show_ram.label"
default = true

[[widget.setting]]
key = "show_swap"
type = "bool"
label_key = "settings.monitor.show_swap.label"
default = false

[[widget.setting]]
key = "show_gpu"
type = "bool"
label_key = "settings.monitor.show_gpu.label"
default = true

[[widget.setting]]
key = "show_gpu_temp"
type = "bool"
label_key = "settings.monitor.show_gpu_temp.label"
default = true

[[widget.setting]]
key = "show_vram"
type = "bool"
label_key = "settings.monitor.show_vram.label"
default = false

[[widget.setting]]
key = "show_load"
type = "bool"
label_key = "settings.monitor.show_load.label"
default = false

[[widget.setting]]
key = "show_net"
type = "bool"
label_key = "settings.monitor.show_net.label"
default = true

[[widget.setting]]
key = "show_glyphs"
type = "bool"
label_key = "settings.monitor.show_glyphs.label"
description_key = "settings.monitor.show_glyphs.description"
default = true
```

Add to `gamer-mode/translations/en.json`, inside the existing `settings` object, keeping the file's existing key order style:

```json
"monitor": {
  "show_cpu": { "label": "CPU usage", "description": "Show processor load in the bar." },
  "show_cpu_temp": { "label": "CPU temperature" },
  "show_ram": { "label": "RAM used" },
  "show_swap": { "label": "Swap used" },
  "show_gpu": { "label": "GPU usage" },
  "show_gpu_temp": { "label": "GPU temperature" },
  "show_vram": { "label": "VRAM used" },
  "show_load": { "label": "Load average" },
  "show_net": { "label": "Network rates" },
  "show_glyphs": { "label": "Icons", "description": "Show an icon beside each reading. Off gives numbers only." }
}
```

- [ ] **Step 4: Write the minimal implementation**

Create `gamer-mode/monitor.luau`:

```lua
--!nonstrict
--
-- Bar monitor: a live metrics readout. It owns no state -- it renders whatever the
-- service publishes and never issues a command of its own except the panel toggle.
--
-- The formatting helpers below are duplicated from widget.luau and panel.luau on
-- purpose. Plugin entries run in separate sandboxed Luau states with no `require`, so
-- there is no module for them to share.

local PANEL_ID = "nomadcxx/gamer-mode:main"
local MIB_PER_GIB = 1024

local M = {}

local metrics = noctalia.state.get("metrics") or { available = false }
local gameMode = noctalia.state.get("game_mode") or { enabled = false, suspended = {} }
local nonceCounter = 0

local function percent(fraction)
    return string.format("%d%%", math.floor((tonumber(fraction) or 0) * 100 + 0.5))
end

local function gibibytes(mib)
    return string.format("%.1fG", (tonumber(mib) or 0) / MIB_PER_GIB)
end

local function degrees(temp)
    return string.format("%d°", math.floor((tonumber(temp) or 0) + 0.5))
end

-- Bar space is scarce, so rates are unit-suffixed rather than spelled "KB/s". The panel
-- has room for the long form and uses it.
local function perSecond(bytes)
    local value = tonumber(bytes) or 0
    if value >= 1024 * 1024 then
        return string.format("%.1fM", value / (1024 * 1024))
    elseif value >= 1024 then
        return string.format("%.0fK", value / 1024)
    end
    return string.format("%.0fB", value)
end

-- Display order is fixed by the plugin; the settings only decide which rows appear.
-- `value` returns nil when the machine has nothing to report, which drops the segment
-- rather than printing a zero that reads like an idle device.
local SEGMENTS = {
    {
        id = "cpu", setting = "show_cpu", group = "cpu", glyph = "cpu-usage", width = 34,
        value = function(m) return percent(m.cpuPerc) end,
    },
    {
        id = "cpu_temp", setting = "show_cpu_temp", group = "cpu", glyph = "cpu-temperature", width = 34,
        value = function(m) return m.cpuTemp and degrees(m.cpuTemp) or nil end,
    },
    {
        id = "ram", setting = "show_ram", group = "mem", glyph = "memory", width = 42,
        value = function(m) return gibibytes(m.memUsedMb) end,
    },
    {
        id = "swap", setting = "show_swap", group = "mem", glyph = "storage", width = 34,
        value = function(m)
            if m.swapTotalMb and m.swapTotalMb > 0 then
                return percent(m.swapPerc)
            end
            return nil
        end,
    },
    {
        id = "gpu", setting = "show_gpu", group = "gpu", glyph = "gpu-usage", width = 34,
        value = function(m)
            if m.gpuAvailable and m.gpuPerc then
                return percent(m.gpuPerc)
            end
            return nil
        end,
    },
    {
        id = "gpu_temp", setting = "show_gpu_temp", group = "gpu", glyph = "temperature", width = 34,
        value = function(m) return m.gpuTemp and degrees(m.gpuTemp) or nil end,
    },
    {
        id = "vram", setting = "show_vram", group = "gpu", glyph = "memory", width = 42,
        value = function(m) return m.vramUsedMb and gibibytes(m.vramUsedMb) or nil end,
    },
    {
        id = "load", setting = "show_load", group = "sys", glyph = "performance", width = 40,
        value = function(m) return m.load1 and string.format("%.2f", m.load1) or nil end,
    },
    {
        id = "net_rx", setting = "show_net", group = "net", glyph = "download", width = 46,
        value = function(m) return m.netRxPerSec and perSecond(m.netRxPerSec) or nil end,
    },
    {
        id = "net_tx", setting = "show_net", group = "net", glyph = "upload", width = 46,
        value = function(m) return m.netTxPerSec and perSecond(m.netTxPerSec) or nil end,
    },
}

function M.readConfig()
    local function bool(key, default)
        local value = noctalia.getConfig(key)
        if value == nil then
            return default
        end
        return value ~= false
    end
    return {
        show_cpu = bool("show_cpu", true),
        show_cpu_temp = bool("show_cpu_temp", true),
        show_ram = bool("show_ram", true),
        show_swap = bool("show_swap", false),
        show_gpu = bool("show_gpu", true),
        show_gpu_temp = bool("show_gpu_temp", true),
        show_vram = bool("show_vram", false),
        show_load = bool("show_load", false),
        show_net = bool("show_net", true),
        show_glyphs = bool("show_glyphs", true),
    }
end

function M.formatSegments(m, config)
    m = m or {}
    local out = {}
    for _, segment in ipairs(SEGMENTS) do
        if config[segment.setting] then
            local text = segment.value(m)
            if text then
                out[#out + 1] = {
                    id = segment.id,
                    group = segment.group,
                    glyph = segment.glyph,
                    width = segment.width,
                    text = text,
                }
            end
        end
    end
    return out
end

function M.buildTree(m, gm, config)
    local children = {}
    for _, segment in ipairs(M.formatSegments(m, config)) do
        children[#children + 1] = ui.row({ align = "center", gap = 3 }, {
            ui.glyph({ name = segment.glyph, size = 13, color = "on_surface_variant" }),
            ui.label({ text = segment.text, width = segment.width, textAlign = "right", color = "on_surface" }),
        })
    end
    return ui.row({ align = "center", gap = 10, paddingH = 6 }, children)
end

local function render()
    barWidget.render(M.buildTree(metrics, gameMode, M.readConfig()))
end

noctalia.state.watch("metrics", function(value)
    metrics = type(value) == "table" and value or { available = false }
    render()
end)

noctalia.state.watch("game_mode", function(value)
    gameMode = type(value) == "table" and value or { enabled = false, suspended = {} }
    render()
end)

-- ── shell entry points (must be globals) ──

function onClick()
    if (noctalia.getConfig("click_action") or "open_panel") == "toggle" then
        nonceCounter = nonceCounter + 1
        noctalia.state.set("command", { nonce = noctalia.nowMs() * 1000 + nonceCounter, action = "toggle" })
    else
        noctalia.togglePanel(PANEL_ID)
    end
end

function onRightClick()
    nonceCounter = nonceCounter + 1
    noctalia.state.set("command", { nonce = noctalia.nowMs() * 1000 + nonceCounter, action = "toggle" })
end

function onConfigChanged()
    render()
end

render()

return M
```

- [ ] **Step 5: Run the tests and make sure they pass**

Run: `lua tests/monitor.lua`
Expected: `monitor: passed`

Run: `./run-tests.sh`
Expected: `all tests passed`

- [ ] **Step 6: Commit**

```bash
git add gamer-mode/monitor.luau gamer-mode/plugin.toml gamer-mode/translations/en.json tests/monitor.lua
git commit -m "feat: bar monitor widget rendering the default metric segments"
```

---

### Task 2: Absent metrics are omitted, and the first sample does not resize the bar

**Files:**
- Modify: `gamer-mode/monitor.luau` (`M.formatSegments`)
- Modify: `tests/monitor.lua`

**Interfaces:**
- Consumes: `M.formatSegments`, `M.readConfig` from Task 1.
- Produces: no signature change. `M.formatSegments` gains placeholder behaviour when `m.available` is false.

- [ ] **Step 1: Write the failing test**

Append to `tests/monitor.lua`, before the `print` line:

```lua
-- ── a machine with no GPU ──

-- Omitted entirely rather than zeroed: "GPU 0%" reads like an idle GPU, which is a
-- different and false claim.
local noGpu = helpers.copy(FULL)
noGpu.gpuAvailable = false
noGpu.gpuPerc = nil
noGpu.gpuTemp = nil
noGpu.vramUsedMb = nil

local allOn = monitor.readConfig()
allOn.show_swap = true
allOn.show_vram = true
allOn.show_load = true

local without = monitor.formatSegments(noGpu, allOn)
for _, segment in ipairs(without) do
    assert(segment.id ~= "gpu" and segment.id ~= "gpu_temp" and segment.id ~= "vram",
        "no GPU segment on a machine without one, got " .. segment.id)
end
assert(#without == 7, "cpu, cpu_temp, ram, swap, load and two net, got " .. #without)

-- Swap that exists is shown; swap turned off is not a bar at 0%.
local noSwap = helpers.copy(FULL)
noSwap.swapTotalMb = 0
for _, segment in ipairs(monitor.formatSegments(noSwap, allOn)) do
    assert(segment.id ~= "swap", "no swap segment when the machine has no swap")
end

-- ── before the first sample ──

-- Placeholders keep every enabled segment at its final width, so the bar does not
-- resize a second after login.
local pending = monitor.formatSegments({ available = false }, monitor.readConfig())
assert(#pending == 7, "every enabled segment is present while loading, got " .. #pending)
for _, segment in ipairs(pending) do
    assert(segment.text == "—", "placeholder text, got " .. segment.text)
    assert(type(segment.width) == "number" and segment.width > 0, "placeholder keeps its final width")
    assert(segment.placeholder == true, "placeholders are marked so the renderer can dim them")
end
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `lua tests/monitor.lua`
Expected: FAIL — `every enabled segment is present while loading, got 3`. Without the placeholder branch, `formatSegments` on an empty sample drops every segment whose `value` returns nil and formats the rest as zeroes.

- [ ] **Step 3: Add the placeholder branch**

In `gamer-mode/monitor.luau`, add the constant beside `MIB_PER_GIB`:

```lua
local PLACEHOLDER = "—"
```

Replace `M.formatSegments` with:

```lua
function M.formatSegments(m, config)
    m = m or {}
    local loading = not m.available
    local out = {}
    for _, segment in ipairs(SEGMENTS) do
        if config[segment.setting] then
            -- Before the first sample there is nothing to ask the machine about, so every
            -- enabled segment reserves its width with a placeholder. Once a sample lands,
            -- a nil value means the hardware is genuinely absent and the segment goes.
            local text = loading and PLACEHOLDER or segment.value(m)
            if text then
                out[#out + 1] = {
                    id = segment.id,
                    group = segment.group,
                    glyph = segment.glyph,
                    width = segment.width,
                    text = text,
                    -- Marked so the renderer can dim them: a dash in the value colour
                    -- reads as data.
                    placeholder = loading,
                }
            end
        end
    end
    return out
end
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `lua tests/monitor.lua`
Expected: `monitor: passed`

Run: `./run-tests.sh`
Expected: `all tests passed`

- [ ] **Step 5: Commit**

```bash
git add gamer-mode/monitor.luau tests/monitor.lua
git commit -m "feat: omit absent metrics and reserve segment width while loading"
```

---

### Task 3: Grouping, fixed widths, icon toggle, vertical bars

**Files:**
- Modify: `gamer-mode/monitor.luau` (`M.buildTree`)
- Modify: `tests/monitor.lua`

**Interfaces:**
- Consumes: `M.formatSegments`, `M.buildTree` from Task 1.
- Produces: `M.buildTree(metrics, gameMode, config, vertical) -> uiNode`. The fourth parameter is new; callers that omit it get the horizontal layout.

- [ ] **Step 1: Write the failing test**

Append to `tests/monitor.lua`:

```lua
-- ── grouping and widths ──

local function labelsOf(node, out)
    out = out or {}
    if type(node) ~= "table" then
        return out
    end
    if node.kind == "label" then
        out[#out + 1] = node.spec
    end
    for _, child in ipairs(node.children or {}) do
        labelsOf(child, out)
    end
    return out
end

local function glyphCount(node)
    local count = 0
    if type(node) ~= "table" then
        return 0
    end
    if node.kind == "glyph" then
        count = 1
    end
    for _, child in ipairs(node.children or {}) do
        count = count + glyphCount(child)
    end
    return count
end

local defaults = monitor.readConfig()
local tree = monitor.buildTree(FULL, { enabled = false, suspended = {} }, defaults)

-- The root is a column so the flame band of Task 5 has somewhere to go. Its first child
-- is the row of groups; nothing else is in it until something is burning.
assert(tree.kind == "column", "the readout root is a column, got " .. tostring(tree.kind))
assert(#tree.children == 1, "only the segment row until a flame is lit, got " .. #tree.children)
local segmentRow = tree.children[1]
assert(segmentRow.kind == "row", "the segments live in a row, got " .. tostring(segmentRow.kind))
assert(#segmentRow.children == 4, "cpu, mem, gpu and net form four groups, got " .. #segmentRow.children)

for _, spec in ipairs(labelsOf(tree)) do
    assert(type(spec.width) == "number" and spec.width > 0,
        "every value label reserves a fixed width, or the bar twitches on refresh")
    assert(spec.textAlign == "right", "values are right-aligned so columns line up")
end

assert(glyphCount(tree) == 7, "one glyph per segment, got " .. glyphCount(tree))

-- ── glyphs off ──

local bare = helpers.copy(defaults)
bare.show_glyphs = false
assert(glyphCount(monitor.buildTree(FULL, { enabled = false }, bare)) == 0,
    "no glyphs when the setting is off")
assert(#labelsOf(monitor.buildTree(FULL, { enabled = false }, bare)) == 7,
    "the values stay when the glyphs go")

-- ── vertical bars ──

-- "CPU 12%" cannot fit a 26px-wide bar, so segments stack instead of running across.
local stacked = monitor.buildTree(FULL, { enabled = false }, defaults, true)
assert(stacked.kind == "column", "a vertical bar stacks, got " .. tostring(stacked.kind))
assert(#stacked.children == 7, "one row per segment when stacked, got " .. #stacked.children)
for _, spec in ipairs(labelsOf(stacked)) do
    assert(spec.width == nil, "no width reservation vertically: a ~26px bar cannot fit one")
    assert(spec.textAlign == "center", "stacked values are centred")
end
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `lua tests/monitor.lua`
Expected: FAIL — `cpu, mem, gpu and net form four groups, got 7`. Task 1's tree is flat.

- [ ] **Step 3: Implement grouping, the glyph toggle, and the vertical layout**

Replace `M.buildTree` in `gamer-mode/monitor.luau`:

```lua
local function segmentNode(segment, showGlyphs)
    local children = {}
    if showGlyphs then
        children[#children + 1] = ui.glyph({ name = segment.glyph, size = 13, color = "on_surface_variant" })
    end
    children[#children + 1] = ui.label({
        text = segment.text,
        width = segment.width,
        textAlign = "right",
        -- A placeholder in the value colour reads as data; dim it so the loading state
        -- reads as loading.
        color = segment.placeholder and "on_surface_variant" or "on_surface",
    })
    return ui.row({ align = "center", gap = 3 }, children)
end

-- Segments of the same group sit close together and groups sit further apart, which is
-- what makes three clusters read as three clusters rather than one run of numbers.
function M.buildTree(m, gm, config, vertical)
    local segments = M.formatSegments(m, config)

    if vertical then
        -- A vertical bar is ~26px wide, so the horizontal width reservations would clip.
        -- Segments stack glyph over value, centred, with no reserved width.
        local rows = {}
        for _, segment in ipairs(segments) do
            local cell = {}
            if config.show_glyphs then
                cell[#cell + 1] = ui.glyph({ name = segment.glyph, size = 13, color = "on_surface_variant" })
            end
            cell[#cell + 1] = ui.label({
                text = segment.text,
                textAlign = "center",
                color = segment.placeholder and "on_surface_variant" or "on_surface",
            })
            rows[#rows + 1] = ui.column({ align = "center", gap = 0 }, cell)
        end
        return ui.column({ align = "center", gap = 2 }, rows)
    end

    local groups = {}
    local currentId = nil
    local current = nil
    for _, segment in ipairs(segments) do
        if segment.group ~= currentId then
            current = {}
            groups[#groups + 1] = current
            currentId = segment.group
        end
        current[#current + 1] = segmentNode(segment, config.show_glyphs)
    end

    local children = {}
    for _, group in ipairs(groups) do
        children[#children + 1] = ui.row({ align = "center", gap = 6 }, group)
    end

    -- A column, not a row: Task 5 appends the flame band underneath these groups, and
    -- the pill's fill and padding belong to the container that holds both.
    return ui.column({ align = "center", gap = 1, paddingH = 6, paddingV = 3 }, {
        ui.row({ align = "center", gap = 12 }, children),
    })
end
```

Update the `render` local to pass the orientation:

```lua
local function render()
    barWidget.render(M.buildTree(metrics, gameMode, M.readConfig(), barWidget.isVertical()))
end
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `lua tests/monitor.lua`
Expected: `monitor: passed`

Run: `./run-tests.sh`
Expected: `all tests passed`

- [ ] **Step 5: Commit**

```bash
git add gamer-mode/monitor.luau tests/monitor.lua
git commit -m "feat: group segments, reserve label widths, stack on vertical bars"
```

---

### Task 4: The gamer-mode pill

**Files:**
- Modify: `gamer-mode/monitor.luau` (`M.readConfig`, `M.buildTree`)
- Modify: `gamer-mode/plugin.toml` (`highlight_gamer_mode`)
- Modify: `gamer-mode/translations/en.json`
- Modify: `tests/monitor.lua`

**Interfaces:**
- Consumes: `M.buildTree(metrics, gameMode, config, vertical)` from Task 3.
- Produces: `config.highlight_gamer_mode` boolean, default true. Root node gains `fill` when gamer mode is on and the setting is enabled.

- [ ] **Step 1: Write the failing test**

Append to `tests/monitor.lua`:

```lua
-- ── the gamer-mode pill ──

local on = { enabled = true, suspended = { "gslapper" } }
local off = { enabled = false, suspended = {} }

local lit = monitor.buildTree(FULL, on, defaults)
local dark = monitor.buildTree(FULL, off, defaults)

assert(dark.spec.fill == nil, "no tint while gamer mode is off")
assert(lit.spec.fill == "primary/0.15",
    "a theme-aware tint while gamer mode is on, got " .. tostring(lit.spec.fill))

-- The pill must not move anything. Identical padding in both states is the whole point
-- of tinting rather than inserting a status segment.
assert(lit.spec.paddingH == dark.spec.paddingH, "padding identical on and off")
assert(#lit.children == #dark.children, "the same segments in both states")

-- Both conditions, not either.
local noHighlight = helpers.copy(defaults)
noHighlight.highlight_gamer_mode = false
assert(monitor.buildTree(FULL, on, noHighlight).spec.fill == nil,
    "no tint when the highlight setting is off, even with gamer mode on")

assert(monitor.readConfig().highlight_gamer_mode == true, "highlight on by default")
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `lua tests/monitor.lua`
Expected: FAIL — `a theme-aware tint while gamer mode is on, got nil`.

- [ ] **Step 3: Declare the setting and paint the pill**

Append to the monitor's settings in `gamer-mode/plugin.toml`:

```toml
[[widget.setting]]
key = "highlight_gamer_mode"
type = "bool"
label_key = "settings.monitor.highlight_gamer_mode.label"
description_key = "settings.monitor.highlight_gamer_mode.description"
default = true
```

Add to the `settings.monitor` object in `gamer-mode/translations/en.json`:

```json
"highlight_gamer_mode": {
  "label": "Highlight while gamer mode is on",
  "description": "Tints the readout instead of adding an icon, so nothing moves when it switches."
}
```

In `gamer-mode/monitor.luau`, add the constant beside `PLACEHOLDER`:

```lua
-- A role with an alpha suffix rather than a hex value, so the tint follows the theme.
local PILL_FILL = "primary/0.15"
```

Add to the table returned by `M.readConfig`:

```lua
        highlight_gamer_mode = bool("highlight_gamer_mode", true),
```

Replace the final `return` of `M.buildTree` with:

```lua
    local props = { align = "center", gap = 1, paddingH = 6, paddingV = 3, radius = 8 }
    -- The padding above is unconditional. Painting the fill must not change the layout,
    -- or every digit in the bar shifts the moment gamer mode is toggled.
    if config.highlight_gamer_mode and gm and gm.enabled then
        props.fill = PILL_FILL
    end
    return ui.column(props, {
        ui.row({ align = "center", gap = 12 }, children),
    })
```

- [ ] **Step 4: Run the tests and make sure they pass**

Run: `lua tests/monitor.lua`
Expected: `monitor: passed`

Run: `./run-tests.sh`
Expected: `all tests passed`

- [ ] **Step 5: Commit**

```bash
git add gamer-mode/monitor.luau gamer-mode/plugin.toml gamer-mode/translations/en.json tests/monitor.lua
git commit -m "feat: tint the readout while gamer mode is on"
```

---

### Task 5: The flame

**Files:**
- Modify: `gamer-mode/monitor.luau`
- Modify: `gamer-mode/plugin.toml` (`flame`, `flame_style`)
- Modify: `gamer-mode/translations/en.json`
- Modify: `tests/monitor.lua`

**Interfaces:**
- Consumes: `M.buildTree(metrics, gameMode, config, vertical)` from Task 4.
- Produces:
  - `config.flame` string, one of `off`, `flare`, `always`, default `flare`.
  - `config.flame_style` string, one of `graph`, `bars`, default `graph`.
  - `M.heatOf(metrics) -> number` in `0..1`.
  - `M.stepFlame(field, heat, dtMs)` mutating a fixed-size array of column heats.
  - `M.flameBand(field, style) -> uiNode`.
  - `M.buildTree(metrics, gameMode, config, vertical, burning)`. `burning` is a number in
    `0..1` or nil. Nil means no flame; the band is absent, not flat.
  - Global `update()`, called by the shell on its timer.

**Background the implementer needs:** every plugin bar widget ticks on a timer and
dispatches a global `update()`. The default interval is 250 ms; `noctalia.setUpdateInterval(ms)`
changes it, with a 16 ms floor. There is **no visibility gating** — a fullscreen game
covering the bar does not stop the timer. `align = "end"` is a valid flex token, which is
what lets boxes sit on a baseline and grow upward. `ui.graph` accepts two series
(`values`, `values2`) with two colours and a `fillOpacity`.

Note the tests run under plain `lua`, not Luau, so `table.clone` and `table.create` are
unavailable. The implementation uses a module-level scratch table instead.

- [ ] **Step 1: Write the failing test**

Append to `tests/monitor.lua`:

```lua
-- ── heat: the flame reports the machine ──

assert(monitor.heatOf({ available = false }) == 0, "no heat before the first sample")

local idle = { available = true, cpuPerc = 0.02, gpuAvailable = true, gpuPerc = 0.03, cpuTemp = 36, gpuTemp = 34 }
local pegged = { available = true, cpuPerc = 0.97, gpuAvailable = true, gpuPerc = 0.99, cpuTemp = 88, gpuTemp = 84 }
assert(monitor.heatOf(idle) < 0.1, "an idle machine barely burns, got " .. monitor.heatOf(idle))
assert(monitor.heatOf(pegged) > 0.9, "a pegged machine rages, got " .. monitor.heatOf(pegged))

-- Usage leads, but a hot card at moderate load still earns a hotter flame.
local warm = { available = true, cpuPerc = 0.4, gpuAvailable = true, gpuPerc = 0.4, cpuTemp = 82, gpuTemp = 80 }
local cool = { available = true, cpuPerc = 0.4, gpuAvailable = true, gpuPerc = 0.4, cpuTemp = 42, gpuTemp = 40 }
assert(monitor.heatOf(warm) > monitor.heatOf(cool), "temperature raises the heat at equal usage")

-- ── the heat field ──

local field = {}
for i = 1, 28 do field[i] = 0 end
for _ = 1, 40 do monitor.stepFlame(field, 0.9, 33) end
local total, peak = 0, 0
for i = 1, 28 do
    total = total + field[i]
    peak = math.max(peak, field[i])
    assert(field[i] >= 0 and field[i] <= 1, "every column stays in range, got " .. field[i])
end
assert(total > 0, "a hot field has heat in it")
assert(peak > 0.4, "sparks reach the top, peak was " .. peak)

-- It has to die down too, or "off" would never look off.
for _ = 1, 400 do monitor.stepFlame(field, 0, 33) end
local cold = 0
for i = 1, 28 do cold = cold + field[i] end
assert(cold < 0.5, "the field decays to nothing without sparks, got " .. cold)

-- ── the band ──

local defaultsFlame = monitor.readConfig()
assert(defaultsFlame.flame == "flare", "flare by default")
assert(defaultsFlame.flame_style == "graph", "graph by default")

local litTree = monitor.buildTree(FULL, on, defaultsFlame, false, 0.8)
assert(#litTree.children == 2, "the band joins the segment row, got " .. #litTree.children)
assert(litTree.children[2].kind == "graph", "graph style renders one graph node, got " .. tostring(litTree.children[2].kind))

local barsConfig = helpers.copy(defaultsFlame)
barsConfig.flame_style = "bars"
local barsTree = monitor.buildTree(FULL, on, barsConfig, false, 0.8)
assert(barsTree.children[2].kind == "row", "bars style renders a row of boxes")
assert(#barsTree.children[2].children == 28, "28 columns, got " .. #barsTree.children[2].children)

-- No band when nothing is burning: absent, not flat.
assert(#monitor.buildTree(FULL, on, defaultsFlame, false, nil).children == 1, "no band when not burning")
assert(#monitor.buildTree(FULL, off, defaultsFlame, false, 0.8).children == 1, "no band when gamer mode is off")

-- A vertical bar has no horizontal room for it.
assert(#monitor.buildTree(FULL, on, defaultsFlame, true, 0.8).children == 7,
    "a vertical readout stacks segments and grows no band")

-- ── intervals ──

assert(mock.updateIntervalMs == 1000, "idle tick slowed on load, got " .. tostring(mock.updateIntervalMs))

mock.config.flame = "flare"
mock.config.flame_style = "graph"
mock.state.set("game_mode", { enabled = false, suspended = {} })
mock.updateIntervalMs = nil

mock.state.set("game_mode", { enabled = true, suspended = { "gslapper" } })
assert(mock.updateIntervalMs == 33, "flare raises the tick, got " .. tostring(mock.updateIntervalMs))

-- The flare has to end on its own. A stuck 30fps loop is the expensive failure, and it
-- would be burning that CPU exactly while a game is running.
local guard = 0
while mock.updateIntervalMs == 33 and guard < 200 do
    mock.clock = mock.clock + 100
    update()
    guard = guard + 1
end
assert(mock.updateIntervalMs == 1000, "flare restores the idle tick when it finishes")
assert(guard < 200, "the flare terminates rather than spinning")

mock.updateIntervalMs = nil
mock.state.set("game_mode", { enabled = false, suspended = {} })
assert(mock.updateIntervalMs == 1000, "no flare when gamer mode goes off, got " .. tostring(mock.updateIntervalMs))

-- ── flame = off ──

mock.config.flame = "off"
mock.updateIntervalMs = nil
mock.state.set("game_mode", { enabled = true, suspended = {} })
assert(mock.updateIntervalMs == nil, "flame=off never raises the tick")

local offConfig = monitor.readConfig()
assert(offConfig.flame == "off", "the setting is read")
assert(monitor.buildTree(FULL, on, offConfig, false, nil).spec.fill == "primary/0.15",
    "flame=off still tints, it just does not burn")

-- ── flame = always ──

mock.config.flame = "always"
mock.state.set("game_mode", { enabled = false, suspended = {} })
mock.updateIntervalMs = nil
mock.state.set("game_mode", { enabled = true, suspended = {} })
assert(mock.updateIntervalMs == 33, "always raises the tick on the off-to-on edge, got " .. tostring(mock.updateIntervalMs))

-- `always` is a loop, not an edge: no transition fires when the user switches the setting
-- while gamer mode is already on, so onConfigChanged must arm it.
mock.updateIntervalMs = nil
onConfigChanged()
assert(mock.updateIntervalMs == 33, "onConfigChanged arms the loop when gamer mode is already on")

rendered = nil
mock.clock = mock.clock + 40
update()
assert(rendered ~= nil, "update re-renders while the loop runs")
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `lua tests/monitor.lua`
Expected: FAIL — `attempt to call a nil value (field 'heatOf')`.

- [ ] **Step 3: Declare the settings**

Append to the monitor's settings in `gamer-mode/plugin.toml`:

```toml
[[widget.setting]]
key = "flame"
type = "select"
label_key = "settings.monitor.flame.label"
description_key = "settings.monitor.flame.description"
default = "flare"
visible_when = { key = "highlight_gamer_mode", values = [true] }
options = [
  { value = "off", label_key = "settings.monitor.flame.options.off" },
  { value = "flare", label_key = "settings.monitor.flame.options.flare" },
  { value = "always", label_key = "settings.monitor.flame.options.always" },
]

[[widget.setting]]
key = "flame_style"
type = "select"
label_key = "settings.monitor.flame_style.label"
description_key = "settings.monitor.flame_style.description"
default = "graph"
visible_when = { key = "highlight_gamer_mode", values = [true] }
options = [
  { value = "graph", label_key = "settings.monitor.flame_style.options.graph" },
  { value = "bars", label_key = "settings.monitor.flame_style.options.bars" },
]
```

Add to the `settings.monitor` object in `gamer-mode/translations/en.json`:

```json
"flame": {
  "label": "Flame",
  "description": "Burns while gamer mode is on, as hot as the machine is working. \"Always\" keeps it animating the whole session, which costs CPU while you play.",
  "options": { "off": "Off", "flare": "Flare on switch", "always": "Always" }
},
"flame_style": {
  "label": "Flame style",
  "description": "How the flame is drawn. \"Graph\" is one node and the cheapest; \"bars\" is crisper up close and costs 28.",
  "options": { "graph": "Graph", "bars": "Bars" }
}
```

- [ ] **Step 4: Implement heat and the field**

Add to `gamer-mode/monitor.luau` beside the other constants:

```lua
-- The readout is driven by state.watch, so the tick only exists for animation. It cannot
-- be switched off, so idle is slowed from the 250ms default instead.
local IDLE_INTERVAL_MS = 1000
local FLARE_INTERVAL_MS = 33
local FLARE_DURATION_MS = 900

local FLAME_COLUMNS = 28
local FLAME_HEIGHT = 6
-- Embers stay alive at idle so the pill still reads as lit.
local HEAT_FLOOR = 0.12

-- Fixed, not role-derived. Fire is not a theme colour, and a theme whose primary is green
-- should still get fire.
local FLAME_STOPS = {
    { 0.00, 61, 15, 2 },
    { 0.28, 176, 42, 4 },
    { 0.58, 255, 106, 0 },
    { 0.82, 255, 179, 64 },
    { 1.00, 255, 233, 163 },
}
```

Add the heat function after `M.formatSegments`:

```lua
-- How hard the machine is working, 0..1 -- the thing the flame reports. Usage leads,
-- because that is what a player feels; temperature follows, so a hot card at moderate
-- load still earns a hot flame.
function M.heatOf(m)
    if not (m and m.available) then
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
```

Add the field simulation below it:

```lua
-- Scratch buffer for one step, reused so a 30fps loop allocates nothing.
local flameScratch = {}
for i = 1, FLAME_COLUMNS do
    flameScratch[i] = 0
end

-- One step of a 1-D fire: bleed into the neighbours, decay, then inject sparks in
-- proportion to how hard the machine is working.
function M.stepFlame(field, heat, dtMs)
    local decay = math.min(1, (dtMs or 33) * 0.0042)
    for i = 1, FLAME_COLUMNS do
        flameScratch[i] = field[i] or 0
    end
    for i = 1, FLAME_COLUMNS do
        local left = flameScratch[i == 1 and FLAME_COLUMNS or i - 1]
        local right = flameScratch[i == FLAME_COLUMNS and 1 or i + 1]
        local blended = flameScratch[i] * 0.62 + (left + right) * 0.19
        field[i] = math.max(0, blended - decay * (0.5 + math.random() * 0.7))
    end
    if heat <= 0 then
        return
    end
    local sparks = math.max(1, math.floor(FLAME_COLUMNS * 0.22 * heat + 0.5))
    for _ = 1, sparks do
        local index = math.random(1, FLAME_COLUMNS)
        field[index] = math.min(1, field[index] + 0.55 + math.random() * 0.45 * heat)
    end
end

local function heatColor(value)
    local t = math.max(0, math.min(1, value))
    for i = 2, #FLAME_STOPS do
        local stop = FLAME_STOPS[i]
        if t <= stop[1] then
            local previous = FLAME_STOPS[i - 1]
            local k = (t - previous[1]) / (stop[1] - previous[1])
            return string.format(
                "#%02x%02x%02x",
                math.floor(previous[2] + (stop[2] - previous[2]) * k),
                math.floor(previous[3] + (stop[3] - previous[3]) * k),
                math.floor(previous[4] + (stop[4] - previous[4]) * k)
            )
        end
    end
    return "#ffe9a3"
end

-- graph is one node whatever the width. bars draws a box per column, which looks crisper
-- close up and costs 28 times as much to reconcile.
function M.flameBand(field, style)
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
            fillOpacity = 0.9,
            height = FLAME_HEIGHT,
            flexGrow = 1,
        })
    end

    local bars = {}
    for i = 1, FLAME_COLUMNS do
        bars[i] = ui.box({
            flexGrow = 1,
            height = math.max(1, field[i] * FLAME_HEIGHT),
            fill = heatColor(field[i]),
            radius = 1,
        })
    end
    -- align = "end" puts them on a baseline so they grow upward.
    return ui.row({ align = "end", gap = 1, height = FLAME_HEIGHT }, bars)
end
```

- [ ] **Step 5: Hang the band off the tree**

Add to the table returned by `M.readConfig`:

```lua
        flame = noctalia.getConfig("flame") or "flare",
        flame_style = noctalia.getConfig("flame_style") or "graph",
```

Add the flame field beside `nonceCounter`:

```lua
local flameField = {}
for i = 1, FLAME_COLUMNS do
    flameField[i] = 0
end
local flareStartedMs = nil
local wasEnabled = gameMode.enabled == true
```

Change `M.buildTree` to take `burning` and append the band. Its signature becomes:

```lua
function M.buildTree(m, gm, config, vertical, burning)
```

and the horizontal return becomes:

```lua
    local props = { align = "center", gap = 1, paddingH = 6, paddingV = 3, radius = 8 }
    local lit = config.highlight_gamer_mode and gm and gm.enabled
    if lit then
        props.fill = PILL_FILL
    end

    local stack = { ui.row({ align = "center", gap = 12 }, children) }
    -- Absent, not flat: a band drawn at zero height is still a node to reconcile, and it
    -- reads as a dead strip under the numbers.
    if lit and burning ~= nil then
        stack[#stack + 1] = M.flameBand(flameField, config.flame_style)
    end
    return ui.column(props, stack)
```

The vertical branch is unchanged and grows no band.

- [ ] **Step 6: Drive it from the tick**

Replace `render`, the `game_mode` watcher and `onConfigChanged`, and add `update`:

```lua
local function burningLevel(config)
    if config.flame == "off" then
        return nil
    end
    if not (config.highlight_gamer_mode and gameMode.enabled) then
        return nil
    end
    local heat = HEAT_FLOOR + M.heatOf(metrics) * (1 - HEAT_FLOOR)
    if config.flame == "always" then
        return heat
    end
    if flareStartedMs == nil then
        return nil
    end
    local elapsed = noctalia.nowMs() - flareStartedMs
    if elapsed >= FLARE_DURATION_MS then
        return nil
    end
    -- The flare opens hot whatever the load, then settles to the resting tint.
    return math.max(heat, 0.75) * (1 - elapsed / FLARE_DURATION_MS)
end

local function render()
    local config = M.readConfig()
    local burning = burningLevel(config)
    if burning ~= nil then
        M.stepFlame(flameField, burning, FLARE_INTERVAL_MS)
    end
    barWidget.render(M.buildTree(metrics, gameMode, config, barWidget.isVertical(), burning))
    barWidget.setTooltip(M.tooltipRows(metrics, gameMode, config))
end

-- Called by the shell on its timer. It does nothing at all unless something is burning,
-- which is what keeps the idle cost to one no-op call a second.
function update()
    local config = M.readConfig()
    if config.flame == "always" and gameMode.enabled and config.highlight_gamer_mode then
        render()
        return
    end
    if flareStartedMs == nil then
        return
    end
    if noctalia.nowMs() - flareStartedMs >= FLARE_DURATION_MS then
        flareStartedMs = nil
        noctalia.setUpdateInterval(IDLE_INTERVAL_MS)
    end
    render()
end

function onConfigChanged()
    local config = M.readConfig()
    if config.flame == "always" and gameMode.enabled and config.highlight_gamer_mode then
        noctalia.setUpdateInterval(FLARE_INTERVAL_MS)
    elseif flareStartedMs == nil then
        noctalia.setUpdateInterval(IDLE_INTERVAL_MS)
    end
    render()
end
```

Replace the `game_mode` watcher so the flare starts on the off-to-on edge only:

```lua
noctalia.state.watch("game_mode", function(value)
    gameMode = type(value) == "table" and value or { enabled = false, suspended = {} }
    local config = M.readConfig()
    local enabled = gameMode.enabled == true

    if enabled and not wasEnabled and config.highlight_gamer_mode then
        if config.flame == "flare" then
            flareStartedMs = noctalia.nowMs()
            noctalia.setUpdateInterval(FLARE_INTERVAL_MS)
        elseif config.flame == "always" then
            noctalia.setUpdateInterval(FLARE_INTERVAL_MS)
        end
    elseif not enabled and wasEnabled then
        flareStartedMs = nil
        noctalia.setUpdateInterval(IDLE_INTERVAL_MS)
    end

    wasEnabled = enabled
    render()
end)
```

Finally, replace the bare `render()` at the bottom of the file with:

```lua
noctalia.setUpdateInterval(IDLE_INTERVAL_MS)
-- `always` is a free-running loop, not an edge: gamer mode may already be on when the
-- widget loads, and no transition will fire to start it.
local bootConfig = M.readConfig()
if bootConfig.flame == "always" and gameMode.enabled and bootConfig.highlight_gamer_mode then
    noctalia.setUpdateInterval(FLARE_INTERVAL_MS)
end
render()
```

- [ ] **Step 7: Run the tests and make sure they pass**

Run: `lua tests/monitor.lua`
Expected: `monitor: passed`

Run: `./run-tests.sh`
Expected: `all tests passed`

- [ ] **Step 8: Commit**

```bash
git add gamer-mode/monitor.luau gamer-mode/plugin.toml gamer-mode/translations/en.json tests/monitor.lua
git commit -m "feat: a flame that burns as hot as the machine is working"
```

---

### Task 6: Tooltip rows on both entries

**Files:**
- Modify: `gamer-mode/monitor.luau` (`M.tooltipRows`)
- Modify: `gamer-mode/widget.luau` (`M.formatTooltip` becomes `M.tooltipRows`)
- Modify: `gamer-mode/translations/en.json`
- Modify: `tests/monitor.lua`, `tests/widget.lua`

**Interfaces:**
- Consumes: `M.formatSegments`, `M.readConfig` from Tasks 1-2.
- Produces:
  - `monitor.M.tooltipRows(metrics, gameMode, config) -> array` of `{ key, value }`.
  - `widget.M.tooltipRows(metrics, showTemps, gameMode) -> array` of `{ key, value }`, replacing `M.formatTooltip`.

**Note:** `barWidget.setTooltip` accepts a string, a single `{key, value}` row, or a list of rows. Passing a list renders an aligned table.

- [ ] **Step 1: Write the failing test**

Append to `tests/monitor.lua`:

```lua
-- ── tooltip ──

-- The tooltip shows what the bar does not, so hovering adds information instead of
-- repeating it.
local rows = monitor.tooltipRows(FULL, off, defaults)
local seen = {}
for _, row in ipairs(rows) do
    seen[row.key] = row.value
end

assert(seen["widget.swap"] ~= nil, "swap is off the bar by default, so it is in the tooltip")
assert(seen["widget.load"] ~= nil, "load average is in the tooltip")
assert(seen["widget.cpu"] == nil, "cpu is on the bar, so it is not repeated in the tooltip")

local withGpuOff = helpers.copy(defaults)
withGpuOff.show_gpu = false
local rows2 = monitor.tooltipRows(FULL, off, withGpuOff)
local seen2 = {}
for _, row in ipairs(rows2) do
    seen2[row.key] = row.value
end
assert(seen2["widget.gpu"] ~= nil, "turning a segment off moves it into the tooltip")

-- Units the bar drops for space come back in the tooltip.
local noTemp = helpers.copy(defaults)
noTemp.show_cpu_temp = false
local seenT = {}
for _, row in ipairs(monitor.tooltipRows(FULL, off, noTemp)) do
    seenT[row.key] = row.value
end
assert(seenT["widget.cpu_temp"] == "45°C", "tooltip temperatures carry the unit, got " .. tostring(seenT["widget.cpu_temp"]))

-- Gamer mode is the thing the built-in sysmon widget can never report.
assert(rows[#rows].key == "widget.gamer_mode", "the last row is gamer-mode state")
local onRows = monitor.tooltipRows(FULL, on, defaults)
assert(onRows[#onRows].value:find("1"), "the suspended count is in the gamer-mode row")
```

Replace the tooltip assertions in `tests/widget.lua` (the block using `widget.formatTooltip`) with:

```lua
local function rowMap(rows)
    local out = {}
    for _, row in ipairs(rows) do
        out[row.key] = row.value
    end
    return out
end

local tip = rowMap(widget.tooltipRows(full, true, { enabled = false }))
assert(tip["widget.cpu"] == "25%", "cpu percentage, got " .. tostring(tip["widget.cpu"]))
assert(tip["widget.cpu_temp"] == "59°C", "cpu temp rounded to whole degrees, got " .. tostring(tip["widget.cpu_temp"]))
assert(tip["widget.ram"] == "10.9G", "ram in GiB, got " .. tostring(tip["widget.ram"]))
assert(tip["widget.gpu"] == "18%", "gpu percentage")
assert(tip["widget.vram"] == "2.5G", "vram in GiB, got " .. tostring(tip["widget.vram"]))

local noTemps = rowMap(widget.tooltipRows(full, false, { enabled = false }))
assert(noTemps["widget.cpu_temp"] == nil, "no temperature row when show_temps is off")
assert(noTemps["widget.gpu_temp"] == nil, "no gpu temperature row when show_temps is off")
assert(noTemps["widget.cpu"] == "25%", "usage still shown")

local missingGpu = rowMap(widget.tooltipRows({ available = true, cpuPerc = 0.1, memUsedMb = 1024 }, true, { enabled = false }))
assert(missingGpu["widget.gpu"] == nil, "no gpu row on a machine without one")
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `lua tests/monitor.lua`
Expected: FAIL — `attempt to call a nil value (field 'tooltipRows')`.

- [ ] **Step 3: Add the translation keys**

Add a `widget` object to `gamer-mode/translations/en.json` beside the existing keys, or extend it if present:

```json
"widget": {
  "cpu": "CPU",
  "cpu_temp": "CPU temp",
  "ram": "RAM",
  "swap": "Swap",
  "gpu": "GPU",
  "gpu_temp": "GPU temp",
  "vram": "VRAM",
  "load": "Load",
  "net_rx": "Down",
  "net_tx": "Up",
  "gamer_mode": "Gamer mode",
  "gamer_mode_on": "On, {count} suspended",
  "gamer_mode_off": "Off"
}
```

Keep the existing `widget.tooltip_loading` key. Do not remove it.

- [ ] **Step 4: Implement the monitor tooltip**

First, give the two temperature entries in `SEGMENTS` a `tip` function — the bar drops the unit for space, the tooltip has room for it:

```lua
        tip = function(m) return m.cpuTemp and string.format("%d°C", math.floor(m.cpuTemp + 0.5)) or nil end,
```

(and the same for `gpu_temp` with `m.gpuTemp`).

Then add to `gamer-mode/monitor.luau`, after `M.formatSegments`:

```lua
-- The bar and the tooltip are complements: a segment the user put on the bar is left out
-- of the tooltip, so hovering always adds something.
function M.tooltipRows(m, gm, config)
    m = m or {}
    local rows = {}
    if m.available then
        for _, segment in ipairs(SEGMENTS) do
            if not config[segment.setting] then
                local text = (segment.tip or segment.value)(m)
                if text then
                    rows[#rows + 1] = { key = noctalia.tr("widget." .. segment.id), value = text }
                end
            end
        end
    else
        rows[#rows + 1] = { key = noctalia.tr("widget.tooltip_loading"), value = PLACEHOLDER }
    end

    local suspended = gm and gm.suspended or {}
    rows[#rows + 1] = {
        key = noctalia.tr("widget.gamer_mode"),
        value = (gm and gm.enabled)
            and noctalia.trp("widget.gamer_mode_on", #suspended)
            or noctalia.tr("widget.gamer_mode_off"),
    }
    return rows
end
```

Call it from `render`, immediately after `barWidget.render(...)`:

```lua
    barWidget.setTooltip(M.tooltipRows(metrics, gameMode, config))
```

- [ ] **Step 5: Implement the toggle tooltip**

In `gamer-mode/widget.luau`, replace `M.formatTooltip` with:

```lua
-- Rows rather than a joined string: setTooltip renders a list of {key, value} tables as
-- an aligned two-column block.
function M.tooltipRows(m, showTemps, gm)
    m = m or {}
    if not m.available then
        return { { key = noctalia.tr("widget.tooltip_loading"), value = "—" } }
    end

    local rows = {
        { key = noctalia.tr("widget.cpu"), value = percent(m.cpuPerc) },
    }
    if showTemps and tonumber(m.cpuTemp) then
        rows[#rows + 1] = { key = noctalia.tr("widget.cpu_temp"), value = string.format("%d°C", math.floor(tonumber(m.cpuTemp) + 0.5)) }
    end
    rows[#rows + 1] = { key = noctalia.tr("widget.ram"), value = gibibytes(m.memUsedMb) }

    -- GPU and VRAM rows are omitted entirely when unsupported: an empty reading is more
    -- honest than a zero that looks like an idle GPU.
    if m.gpuAvailable and m.gpuPerc then
        rows[#rows + 1] = { key = noctalia.tr("widget.gpu"), value = percent(m.gpuPerc) }
        if showTemps and tonumber(m.gpuTemp) then
            rows[#rows + 1] = { key = noctalia.tr("widget.gpu_temp"), value = string.format("%d°C", math.floor(tonumber(m.gpuTemp) + 0.5)) }
        end
    end
    if m.vramUsedMb then
        rows[#rows + 1] = { key = noctalia.tr("widget.vram"), value = gibibytes(m.vramUsedMb) }
    end

    local suspended = gm and gm.suspended or {}
    rows[#rows + 1] = {
        key = noctalia.tr("widget.gamer_mode"),
        value = (gm and gm.enabled)
            and noctalia.trp("widget.gamer_mode_on", #suspended)
            or noctalia.tr("widget.gamer_mode_off"),
    }
    return rows
end
```

Update the call inside `render` in the same file:

```lua
    barWidget.setTooltip(M.tooltipRows(metrics, noctalia.getConfig("show_temps") ~= false, gameMode))
```

Delete the now-unused `withTemp` helper.

- [ ] **Step 6: Run the tests and make sure they pass**

Run: `lua tests/monitor.lua && lua tests/widget.lua`
Expected: both print `passed`.

Run: `./run-tests.sh`
Expected: `all tests passed`

- [ ] **Step 7: Commit**

```bash
git add gamer-mode/monitor.luau gamer-mode/widget.luau gamer-mode/translations/en.json tests/monitor.lua tests/widget.lua
git commit -m "feat: tooltip rows that complement the bar instead of repeating it"
```

---

### Task 7: Custom icons on the toggle widget

**Files:**
- Modify: `gamer-mode/widget.luau` (`render`)
- Modify: `gamer-mode/plugin.toml` (`icon_file`, `icon_file_active`)
- Modify: `gamer-mode/translations/en.json`
- Modify: `tests/widget.lua`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: no new exported function. `render` in `widget.luau` calls `barWidget.setImage(path, true, 18)` when an icon file is configured, and `barWidget.setGlyph(name)` otherwise.

**Background the implementer needs:** `setImage` clears the glyph and `setGlyph` clears the image, so switching between them at runtime is safe. Paths resolve `~`, absolute, or plugin-relative. The second argument is a watch flag: true reloads the bar when the file changes on disk. `setGlyphColor` does **not** tint an image, which is why a separate active icon exists.

- [ ] **Step 1: Write the failing test**

Add to the `_G.barWidget` stub in `tests/widget.lua`:

```lua
    setImage = function(path, watch, size)
        bar.image = { path = path, watch = watch, size = size }
        bar.glyph = nil
    end,
```

and extend the stub's `setGlyph` to clear the image, mirroring the shell:

```lua
    setGlyph = function(value)
        bar.glyph = value
        bar.image = nil
    end,
```

Append to `tests/widget.lua`:

```lua
-- ── custom icons ──

-- A glyph by default, so nothing changes for anyone who has not set a file.
assert(bar.glyph ~= nil and bar.image == nil, "glyph by default")

mock.config.icon_file = "~/.config/noctalia/flame.svg"
onConfigChanged()
assert(bar.image ~= nil, "a configured icon file replaces the glyph")
assert(bar.image.path == "~/.config/noctalia/flame.svg", "the path is passed through unexpanded")
assert(bar.image.watch == true, "watch is on, so editing the file updates the bar")
assert(bar.glyph == nil, "the glyph is cleared")

-- setGlyphColor cannot tint an image, so an active icon carries the state instead.
mock.config.icon_file_active = "~/.config/noctalia/flame-on.svg"
mock.state.set("game_mode", { enabled = true, suspended = {} })
assert(bar.image.path == "~/.config/noctalia/flame-on.svg", "the active icon shows while gamer mode is on")

mock.state.set("game_mode", { enabled = false, suspended = {} })
assert(bar.image.path == "~/.config/noctalia/flame.svg", "back to the resting icon")

-- Falls back rather than blanking the bar when only the resting icon is set.
mock.config.icon_file_active = nil
mock.state.set("game_mode", { enabled = true, suspended = {} })
assert(bar.image.path == "~/.config/noctalia/flame.svg", "the resting icon covers both states when it is the only one")

-- Clearing the setting returns to the glyph.
mock.config.icon_file = nil
onConfigChanged()
assert(bar.glyph ~= nil and bar.image == nil, "clearing the file restores the glyph")
```

- [ ] **Step 2: Run it to make sure it fails**

Run: `lua tests/widget.lua`
Expected: FAIL — `a configured icon file replaces the glyph`.

- [ ] **Step 3: Declare the settings**

Add to `gamer-mode/plugin.toml` immediately after the existing `glyph` setting:

```toml
[[setting]]
key = "icon_file"
type = "file"
label_key = "settings.icon_file.label"
description_key = "settings.icon_file.description"
default = ""
extensions = ["svg", "png"]

[[setting]]
key = "icon_file_active"
type = "file"
label_key = "settings.icon_file_active.label"
description_key = "settings.icon_file_active.description"
default = ""
extensions = ["svg", "png"]
```

Add to `settings` in `gamer-mode/translations/en.json`:

```json
"icon_file": {
  "label": "Custom icon",
  "description": "An SVG or PNG to use instead of the glyph. Edits to the file appear in the bar straight away."
},
"icon_file_active": {
  "label": "Custom icon, gamer mode on",
  "description": "Shown while gamer mode is on. A custom icon cannot be recoloured, so without this the state is only in the tooltip."
}
```

- [ ] **Step 4: Implement**

Replace `render` in `gamer-mode/widget.luau`:

```lua
-- Trimmed locally on purpose. The real binding is `noctalia.string.trim`, but the test
-- harness exposes a top-level `noctalia.trim`, so code written against the mock would
-- pass the suite and fail in the shell. A Lua pattern depends on neither.
local function trimmed(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local function iconFile()
    local resting = trimmed(noctalia.getConfig("icon_file"))
    if resting == "" then
        return nil
    end
    if gameMode.enabled then
        local active = trimmed(noctalia.getConfig("icon_file_active"))
        if active ~= "" then
            return active
        end
    end
    return resting
end

local function render()
    local icon = iconFile()
    if icon then
        -- watch = true, so editing the file updates the bar without a reload. An image
        -- cannot be tinted, which is what icon_file_active exists to work around.
        barWidget.setImage(icon, true, 18)
    else
        barWidget.setGlyph(noctalia.getConfig("glyph") or "device-gamepad-2")
        barWidget.setGlyphColor(gameMode.enabled and "primary" or "on_surface")
    end
    barWidget.setTooltip(M.tooltipRows(metrics, noctalia.getConfig("show_temps") ~= false, gameMode))
end
```

- [ ] **Step 5: Run the tests and make sure they pass**

Run: `lua tests/widget.lua`
Expected: `widget: passed`

Run: `./run-tests.sh`
Expected: `all tests passed`

- [ ] **Step 6: Commit**

```bash
git add gamer-mode/widget.luau gamer-mode/plugin.toml gamer-mode/translations/en.json tests/widget.lua
git commit -m "feat: custom SVG or PNG icons for the bar toggle"
```

---

### Task 8: Documentation, screenshots, and the version bump

**Files:**
- Modify: `gamer-mode/README.md`
- Modify: `gamer-mode/plugin.toml` (version)
- Add: `docs/images/monitor.webp`

- [ ] **Step 1: Verify the translation file covers every declared setting**

Run:

```bash
lua -e '
local json = dofile("tests/helpers.lua").json
local translations = json.decode(io.open("gamer-mode/translations/en.json"):read("a"))
local missing = {}
for key in io.open("gamer-mode/plugin.toml"):read("a"):gmatch("label_key%s*=%s*\"([^\"]+)\"") do
  local node = translations
  for part in key:gmatch("[^%.]+") do node = type(node) == "table" and node[part] or nil end
  if node == nil then missing[#missing+1] = key end
end
for key in io.open("gamer-mode/plugin.toml"):read("a"):gmatch("description_key%s*=%s*\"([^\"]+)\"") do
  local node = translations
  for part in key:gmatch("[^%.]+") do node = type(node) == "table" and node[part] or nil end
  if node == nil then missing[#missing+1] = key end
end
print(#missing == 0 and "all keys present" or ("MISSING: " .. table.concat(missing, ", ")))
'
```

Expected: `all keys present`. Fix `en.json` if it reports anything and re-run.

- [ ] **Step 2: Capture screenshots**

Add the monitor widget to the bar via Settings → Bar, then capture the readout in both states:

```bash
grim -g "$(slurp)" /home/nomadx/noctalia-gamermode/docs/images/monitor.webp
```

Take it with gamer mode off and on so the pill is visible in one of them. The upstream PR template requires screenshots for anything with a visual surface.

- [ ] **Step 3: Document both entries in the plugin README**

Add a `## Monitor` section to `gamer-mode/README.md` covering:

- The two widget entries and what each is for.
- A table of every monitor setting with its default, matching `plugin.toml` exactly.
- The complement rule: a metric shown on the bar is left out of the tooltip.
- That `flame = "always"` holds a 30fps animation for as long as gamer mode is on, and that Noctalia does not stop widget timers when the bar is covered, so it costs CPU during play.
- That a custom `icon_file` cannot be tinted, and `icon_file_active` is how the state stays visible.
- That vertical bars stack the segments.

- [ ] **Step 4: Bump the version**

In `gamer-mode/plugin.toml`, change line 3:

```toml
version = "0.7.0"
```

Minor, not patch: this adds a widget entry and settings without changing existing behaviour.

- [ ] **Step 5: Run the full suite**

Run: `./run-tests.sh`
Expected: `all tests passed`

- [ ] **Step 6: Commit**

```bash
git add gamer-mode/README.md gamer-mode/plugin.toml docs/images/monitor.webp
git commit -m "docs: document the monitor widget and release 0.7.0"
```

---

### Task 9: Upstream update PR

**Files:**
- No repository files. This task publishes the work to `noctalia-dev/community-plugins`.

**Background the implementer needs:** the plugin merged upstream on 2026-07-31, so this is an update. Plugin directories live at the **repo root** (`gamer-mode/`), not under any `plugins/` directory. `catalog.toml` is generated by CI and must never be committed. The PR description is bot-checked: losing the `<!-- noctalia-pr-template:v1 -->` marker, a `##` heading, a `- **Field:**` line, or a `- [ ]` entry closes the PR automatically.

- [ ] **Step 1: Confirm the version bump is the only manifest identity change**

Run:

```bash
cd /home/nomadx/noctalia-gamermode
git diff main~1 -- gamer-mode/plugin.toml | grep -E '^\+(version|plugin_api|id|name)'
```

Expected: exactly one line, `+version = "0.7.0"`. `plugin_api` must still read 19; raising it would push older Noctalia installs onto a pinned older revision through the catalog's release ladder.

- [ ] **Step 2: Sync into a fork checkout**

```bash
SCRATCH=/tmp/claude-1000/-home-nomadx-noctalia-gamermode/327deb24-d25b-4548-8612-0719bd0d331f/scratchpad
gh repo clone Nomadcxx/community-plugins "$SCRATCH/fork" -- --depth 1
cd "$SCRATCH/fork"
git checkout -b feat/gamer-mode-monitor
rsync -a --delete /home/nomadx/noctalia-gamermode/gamer-mode/ "$SCRATCH/fork/gamer-mode/"
git status --short
```

Expected: changes confined to `gamer-mode/`. If `catalog.toml` or any other plugin directory appears, stop and fix the sync before continuing.

- [ ] **Step 3: Validate locally before pushing**

```bash
cd "$SCRATCH/fork"
python3 .github/workflows/scripts/validate-plugins.py
```

Expected: no errors. This is the same script CI runs.

- [ ] **Step 4: Push and open the PR**

```bash
cd "$SCRATCH/fork"
git add gamer-mode
git commit -m "gamer-mode: 0.7.0 — bar monitor widget, custom icons, tooltip rows"
git push -u origin feat/gamer-mode-monitor
```

Open the PR against `noctalia-dev/community-plugins:main` using the repository's PR template verbatim. Tick **"Update to an existing plugin (version bumped in `plugin.toml`)"**, fill the Noctalia version and plugin API level (19), and attach the screenshots from Task 8.

- [ ] **Step 5: Confirm CI is green**

```bash
gh pr checks --repo noctalia-dev/community-plugins
```

Expected: `validate` passes. Do not mark the PR ready for review without the repository owner's say-so.

---

## Self-Review

**Spec coverage:**

| Spec section | Task |
|---|---|
| 1. Architecture, second entry, no service change | 1 |
| 2. Segment model, groups, fixed widths, glyph vocabulary | 1, 3 |
| 3. Settings, per-instance | 1, 4, 5 |
| 3. Custom icons, `icon_file_active` | 7 |
| 4. Tooltip rows, complement rule | 6 |
| 5. Flare, intervals, `flame` options, `always` armed at load and on config change | 5 |
| 6. Absent metrics, placeholders, vertical bars | 2, 3 |
| 7. Testing | every task; the assertion table in the spec maps onto Tasks 1-5 |
| 8. Documentation, translations, screenshots | 8 |
| 9. Release process | 8, 9 |
| Out of scope: audio reactivity, thresholds, per-core, gradients | no task, by design |

**Placeholder scan:** none. Every code step carries the code to write; every test step carries the assertions.

**Type consistency:** `M.readConfig` field names match the `plugin.toml` setting keys exactly and are used unchanged in `M.formatSegments`, `M.buildTree`, `fillFor` and `M.tooltipRows`. `M.buildTree` grows parameters across Tasks 3 and 5 — `(m, gm, config)` → `(m, gm, config, vertical)` → `(m, gm, config, vertical, phase)` — with trailing parameters optional, so earlier call sites keep working. Tooltip rows use `{ key, value }` in both `monitor.luau` and `widget.luau`. `PLACEHOLDER` is defined in Task 2 and reused in Task 6.
