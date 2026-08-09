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

print("monitor: passed")
