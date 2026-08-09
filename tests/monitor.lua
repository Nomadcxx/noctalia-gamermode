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

local fastNet = helpers.copy(FULL)
fastNet.netRxPerSec = 1.25 * 1024 * 1024 * 1024
local fastSegments = monitor.formatSegments(fastNet, config)
assert(fastSegments[6].text == "1.2G", "GiB rates stay inside the fixed label, got " .. fastSegments[6].text)

-- ── it renders on load and on every state change ──

assert(rendered ~= nil, "the widget renders as soon as it loads")

rendered = nil
mock.state.set("metrics", helpers.copy(FULL))
assert(rendered ~= nil, "a new metrics sample re-renders")

rendered = nil
mock.state.set("game_mode", { enabled = true, suspended = {} })
assert(rendered ~= nil, "a gamer-mode change re-renders")

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

-- A vertical bar grows no flame band, but it is still gamer mode and still gets the tint.
local litVertical = monitor.buildTree(FULL, on, defaults, true)
local darkVertical = monitor.buildTree(FULL, off, defaults, true)
assert(litVertical.spec.fill == "primary/0.15", "vertical is tinted too, got " .. tostring(litVertical.spec.fill))
assert(darkVertical.spec.fill == nil, "vertical is untinted while gamer mode is off")
assert(litVertical.spec.paddingH == darkVertical.spec.paddingH, "vertical padding identical on and off")

-- ── config and clicks ──

rendered = nil
onConfigChanged()
assert(rendered ~= nil, "a config change re-renders")

mock.config.click_action = "open_panel"
mock.toggledPanel = nil
mock.published.command = nil
onClick()
assert(mock.toggledPanel == "nomadcxx/gamer-mode:main", "left-click opens the shared panel")
assert(mock.published.command == nil, "opening the panel sends no command")

mock.config.click_action = "toggle"
mock.toggledPanel = nil
onClick()
local leftCommand = mock.published.command
assert(type(leftCommand) == "table" and leftCommand.action == "toggle", "toggle click sends a command")

onRightClick()
assert(mock.published.command.action == "toggle", "right-click always toggles")
assert(mock.published.command.nonce > leftCommand.nonce, "click commands carry fresh nonces")
assert(mock.toggledPanel == nil, "right-click does not open the panel")

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
assert(litTree.spec.align == "stretch", "the column stretches the graph to the readout width")

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

mock.config.flame = "flare"
mock.config.flame_style = "graph"

-- Task 1's test left gamer mode on, and under the finished watcher that off-to-on edge
-- already armed a flare. Settle it first: the on-to-off edge restores the idle interval
-- through the real code path, so the assertion still earns its keep.
mock.state.set("game_mode", { enabled = false, suspended = {} })
assert(mock.updateIntervalMs == 1000,
    "gamer mode going off restores the idle tick, got " .. tostring(mock.updateIntervalMs))

-- The same constant through the other door: nothing burning, so a config change settles.
mock.updateIntervalMs = nil
onConfigChanged()
assert(mock.updateIntervalMs == 1000,
    "a config change with nothing burning settles to idle, got " .. tostring(mock.updateIntervalMs))

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

vertical = true
mock.state.set("game_mode", { enabled = false, suspended = {} })
mock.state.set("game_mode", { enabled = true, suspended = {} })
assert(mock.updateIntervalMs == 1000,
    "a vertical bar leaves the invisible flame at the idle tick, got " .. tostring(mock.updateIntervalMs))
vertical = false

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

-- Third arm/disarm path: the highlight switched off while `always` is running. There is
-- no state edge for this either, so onConfigChanged has to catch it or the loop runs on
-- over a pill that is no longer painted.
mock.config.highlight_gamer_mode = false
mock.updateIntervalMs = nil
onConfigChanged()
assert(mock.updateIntervalMs == 1000,
    "turning the highlight off stops the always loop, got " .. tostring(mock.updateIntervalMs))
mock.config.highlight_gamer_mode = nil

-- Opting out during a flare must stop the expensive tick immediately, not after the
-- remaining animation window.
mock.config.flame = "flare"
mock.state.set("game_mode", { enabled = false, suspended = {} })
mock.state.set("game_mode", { enabled = true, suspended = {} })
assert(mock.updateIntervalMs == 33, "flare armed for the mid-flight opt-out check")
mock.config.flame = "off"
onConfigChanged()
assert(mock.updateIntervalMs == 1000, "switching flame off mid-flare settles immediately")

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

local loadingRows = monitor.tooltipRows({ available = false }, nil, defaults)
assert(loadingRows[1].key == "widget.tooltip_loading", "unknown metrics retain the loading row")
assert(loadingRows[#loadingRows].key == "widget.gamer_mode", "unknown state still gets a gamer-mode row")

-- `always` also has to arm at load: there is no state edge when the widget appears after
-- gamer mode was already enabled.
local bootBar = { rendered = nil }
_G.barWidget = {
    render = function(tree) bootBar.rendered = tree end,
    setTooltip = function(value) bootBar.tooltip = value end,
    isVertical = function() return false end,
}
local bootMock = helpers.newNoctalia({ config = { flame = "always" } })
bootMock.published.metrics = helpers.copy(FULL)
bootMock.published.game_mode = { enabled = true, suspended = {} }
dofile("gamer-mode/monitor.luau")
assert(bootMock.updateIntervalMs == 33, "always arms at load when gamer mode is already on")
assert(bootBar.rendered ~= nil, "the already-enabled widget still renders at load")

local invalidBar = {}
_G.barWidget = {
    render = function(tree) invalidBar.rendered = tree end,
    setTooltip = function(value) invalidBar.tooltip = value end,
    isVertical = function() return false end,
}
local invalidMock = helpers.newNoctalia()
invalidMock.published.metrics = "unknown"
invalidMock.published.game_mode = 42
local loaded = pcall(dofile, "gamer-mode/monitor.luau")
assert(loaded, "unknown initial state must not take down the bar")
assert(invalidBar.rendered ~= nil and type(invalidBar.tooltip) == "table", "unknown state renders loading rows")

print("monitor: passed")
