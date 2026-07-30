-- Panel: the pure row/line builders, plus the handler wiring. The declarative ui.*
-- tree is captured so the test can assert on what was actually rendered.
package.path = "./tests/?.lua;" .. package.path
local helpers = require("helpers")

-- ui.* constructors record their kind and spec so the rendered tree is inspectable.
_G.ui = setmetatable({}, {
    __index = function(_, name)
        return function(spec, children)
            return { kind = name, spec = spec or {}, children = children }
        end
    end,
})

local rendered = nil
_G.panel = {
    render = function(tree)
        rendered = tree
    end,
    close = function()
        _G.panel.closed = true
    end,
}

local mock = helpers.newNoctalia({
    config = { profile = "light", auto_performance = true, show_temps = true },
})
mock.published.metrics = {
    available = true,
    cpuPerc = 0.5,
    cpuTemp = 58,
    memPerc = 0.5,
    memUsedMb = 16384,
    memTotalMb = 32768,
    gpuAvailable = true,
    gpuPerc = 0.4,
    gpuTemp = 60,
    vramUsedMb = 4096,
    vramTotalMb = 8188,
    vramPerc = 0.5,
}
mock.published.game_mode = {
    enabled = true,
    busy = false,
    profile = "light",
    suspended = { { match = "gslapper", kind = "process" }, { match = "spotifyd.service", kind = "user-service" } },
}
mock.published.power = { available = true, active = "performance", profiles = { "balanced", "performance", "power-saver" } }

local p = dofile("gamermode/panel.luau")

-- ── metric rows ──

local rows = p.buildRows(mock.published.metrics, true)
assert(#rows == 4, "cpu/ram/gpu/vram rows, got " .. #rows)
assert(rows[1].label == "CPU" and math.abs(rows[1].progress - 0.5) < 0.0001, "cpu row")
assert(rows[1].detail:find("50%%"), "cpu detail has a percentage, got: " .. rows[1].detail)
assert(rows[1].detail:find("58"), "cpu detail has the temperature")
assert(rows[2].label == "RAM" and rows[2].detail:find("16.0"), "ram detail in GiB, got: " .. rows[2].detail)
assert(rows[2].detail:find("32"), "ram detail shows the total")
assert(rows[3].label == "GPU" and math.abs(rows[3].progress - 0.4) < 0.0001, "gpu row")
assert(rows[4].label == "VRAM" and math.abs(rows[4].progress - 0.5) < 0.0001, "vram row uses the reported ratio")
assert(rows[4].detail:find("4.0"), "vram detail in GiB, got: " .. rows[4].detail)

-- Temperatures follow the setting.
local noTemps = p.buildRows(mock.published.metrics, false)
assert(not noTemps[1].detail:find("58"), "cpu temp hidden, got: " .. noTemps[1].detail)
assert(not noTemps[3].detail:find("60"), "gpu temp hidden")
assert(noTemps[1].detail:find("50%%"), "usage still shown")

-- No GPU: two rows, and neither invents a zeroed GPU bar.
local noGpu = p.buildRows(
    { available = true, cpuPerc = 0.1, memPerc = 0.2, memUsedMb = 1024, memTotalMb = 2048, gpuAvailable = false },
    true
)
assert(#noGpu == 2, "cpu and ram only, got " .. #noGpu)

-- Partial GPU: usage row present, VRAM row absent.
local partialGpu = p.buildRows(
    { available = true, cpuPerc = 0.1, memPerc = 0.2, memUsedMb = 1, memTotalMb = 2, gpuAvailable = true, gpuPerc = 0.3 },
    true
)
assert(#partialGpu == 3 and partialGpu[3].label == "GPU", "gpu row without a vram row")

-- No sample yet: no rows at all rather than a wall of zeroes.
assert(#p.buildRows({ available = false }, true) == 0, "no rows before the first sample")
assert(#p.buildRows(nil, true) == 0, "nil metrics build no rows")

-- Progress values stay inside 0-1 even if a reading is wild.
local clamped = p.buildRows({ available = true, cpuPerc = 4, memPerc = -1, memUsedMb = 0, memTotalMb = 0 }, true)
assert(clamped[1].progress == 1 and clamped[2].progress == 0, "row progress clamped")

-- ── suspended list ──

local lines = p.suspendedLines(mock.published.game_mode)
assert(#lines == 2, "two suspended entries, got " .. #lines)
assert(lines[1]:find("gslapper", 1, true) and lines[1]:find("process", 1, true), "entry names its kind: " .. lines[1])
assert(#p.suspendedLines({ enabled = false, suspended = {} }) == 0, "nothing listed while disabled")
assert(#p.suspendedLines(nil) == 0, "nil game_mode lists nothing")
assert(#p.suspendedLines({ enabled = true }) == 0, "missing suspended list is tolerated")

-- ── rendered tree ──

onOpen()
assert(type(rendered) == "table", "onOpen renders")

-- Collect every node so the test can assert on content without depending on layout.
local function flatten(node, out)
    out = out or {}
    if type(node) ~= "table" then
        return out
    end
    if node.kind then
        out[#out + 1] = node
    end
    for _, child in ipairs(node.children or {}) do
        flatten(child, out)
    end
    if node.children and node.children.kind then
        flatten(node.children, out)
    end
    return out
end

local nodes = flatten(rendered)
local byKind = {}
for _, node in ipairs(nodes) do
    byKind[node.kind] = (byKind[node.kind] or 0) + 1
end
assert(byKind.progress == 4, "a progress bar per metric row, got " .. tostring(byKind.progress))
assert(byKind.button and byKind.button >= 2, "master toggle and settings buttons present")
assert(byKind.select == 1, "a power profile select is present")

-- Handlers are named globals: the ui bridge resolves onClick/onChange by name and
-- cannot call a Lua closure.
for _, node in ipairs(nodes) do
    for _, prop in ipairs({ "onClick", "onChange" }) do
        local handler = node.spec[prop]
        if handler ~= nil then
            assert(type(handler) == "string", node.kind .. "." .. prop .. " must be a global name, not a closure")
            assert(type(_G[handler]) == "function", "handler global is missing: " .. handler)
        end
    end
end

-- The toggle button reflects and drives the current state.
local function findButton(text)
    for _, node in ipairs(nodes) do
        if node.kind == "button" and node.spec.text == text then
            return node
        end
    end
    return nil
end
assert(findButton("panel.disable"), "shows Disable while gamer mode is on")
assert(not findButton("panel.enable"), "does not offer Enable while already on")

-- ── handlers ──

mock.published.command = nil
onToggleGameMode()
local command = mock.published.command
assert(type(command) == "table" and command.action == "toggle", "the toggle button sends a toggle command")
assert(type(command.nonce) == "number", "command carries a nonce")

local firstNonce = command.nonce
onToggleGameMode()
assert(mock.published.command.nonce > firstNonce, "each press uses a fresh nonce")

-- The select reports a zero-based index into the published profile list.
onPowerProfileChanged(0)
assert(mock.published.command.action == "set-power-profile", "power select sends a command")
assert(mock.published.command.profile == "balanced", "index 0 maps to the first profile")
onPowerProfileChanged(2)
assert(mock.published.command.profile == "power-saver", "index 2 maps to the third profile")

-- An out-of-range index sends nothing rather than a wrong profile.
mock.published.command = nil
onPowerProfileChanged(99)
assert(mock.published.command == nil, "out-of-range index is ignored")

onOpenSettings()
assert(mock.settingsOpened == true, "settings button opens settings")

-- ── live updates ──

noctalia.state.set("metrics", { available = true, cpuPerc = 0.9, memPerc = 0.1, memUsedMb = 1, memTotalMb = 2 })
local afterMetrics = flatten(rendered)
local sawNinety = false
for _, node in ipairs(afterMetrics) do
    if node.kind == "label" and type(node.spec.text) == "string" and node.spec.text:find("90%%") then
        sawNinety = true
    end
end
assert(sawNinety, "a metrics write re-renders the panel")

-- While disabled the suspended section is gone and the button offers Enable.
noctalia.state.set("game_mode", { enabled = false, busy = false, profile = "heavy", suspended = {} })
nodes = flatten(rendered)
local sawEnable, sawSuspendedHeading = false, false
for _, node in ipairs(nodes) do
    if node.kind == "button" and node.spec.text == "panel.enable" then
        sawEnable = true
    end
    if node.kind == "label" and node.spec.text == "panel.suspended" then
        sawSuspendedHeading = true
    end
end
assert(sawEnable, "offers Enable while off")
assert(not sawSuspendedHeading, "no suspended section while off")

-- While a flow is in flight the button is disabled so a double click cannot race.
noctalia.state.set("game_mode", { enabled = false, busy = true, profile = "light", suspended = {} })
nodes = flatten(rendered)
local busyButton = nil
for _, node in ipairs(nodes) do
    if node.kind == "button" and node.spec.text == "panel.working" then
        busyButton = node
    end
end
assert(busyButton, "shows the working label while busy")
assert(busyButton.spec.enabled == false, "the toggle is disabled while busy")

-- Without powerprofilesctl the select is replaced by an explanation, not left broken.
noctalia.state.set("power", { available = false, profiles = {} })
nodes = flatten(rendered)
local selects, sawUnavailable = 0, false
for _, node in ipairs(nodes) do
    if node.kind == "select" then
        selects = selects + 1
    end
    if node.kind == "label" and node.spec.text == "panel.power_unavailable" then
        sawUnavailable = true
    end
end
assert(selects == 0, "no power select without powerprofilesctl")
assert(sawUnavailable, "explains why the power row is missing")

-- Nil state writes must not break rendering.
noctalia.state.set("metrics", nil)
noctalia.state.set("game_mode", nil)
noctalia.state.set("power", nil)
assert(type(rendered) == "table", "panel still renders after nil writes")

print("panel: passed")
