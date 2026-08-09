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
