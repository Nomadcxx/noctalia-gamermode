-- Bar widget: glyph, live tooltip, click behaviour.
package.path = "./tests/?.lua;" .. package.path
local helpers = require("helpers")

local bar = { glyph = nil, tooltip = nil, glyphColor = nil }
_G.barWidget = {
    setGlyph = function(value)
        bar.glyph = value
    end,
    setTooltip = function(value)
        bar.tooltip = value
    end,
    setGlyphColor = function(role)
        bar.glyphColor = role
    end,
}

local mock = helpers.newNoctalia({
    config = { glyph = "device-gamepad-2", click_action = "toggle", show_temps = true },
})
mock.published.game_mode = { enabled = false, suspended = {} }
mock.published.metrics = { available = false }

local widget = dofile("gamer-mode/widget.luau")

assert(bar.glyph == "device-gamepad-2", "glyph applied from the setting, got " .. tostring(bar.glyph))
assert(type(bar.tooltip) == "table" and #bar.tooltip > 0, "tooltip rows are set before the first sample")

-- ── tooltip ──

local full = {
    available = true,
    cpuPerc = 0.25,
    cpuTemp = 58.5,
    memPerc = 0.34,
    memUsedMb = 11200,
    memTotalMb = 32768,
    gpuAvailable = true,
    gpuPerc = 0.18,
    gpuTemp = 61,
    vramUsedMb = 2600,
    vramTotalMb = 8188,
}

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
assert(tip["widget.gamer_mode"] == "widget.gamer_mode_off", "off state is always reported")

local noTemps = rowMap(widget.tooltipRows(full, false, { enabled = false }))
assert(noTemps["widget.cpu_temp"] == nil, "no temperature row when show_temps is off")
assert(noTemps["widget.gpu_temp"] == nil, "no gpu temperature row when show_temps is off")
assert(noTemps["widget.cpu"] == "25%", "usage still shown")

local missingGpu = rowMap(widget.tooltipRows(
    { available = true, cpuPerc = 0.1, memUsedMb = 1024 },
    true,
    { enabled = false }
))
assert(missingGpu["widget.gpu"] == nil, "no gpu row on a machine without one")
assert(missingGpu["widget.vram"] == nil, "no vram row without a reading")

local partial = rowMap(widget.tooltipRows(
    { available = true, cpuPerc = 0.1, memUsedMb = 512, gpuAvailable = true, gpuPerc = 0.4 },
    true,
    { enabled = false }
))
assert(partial["widget.gpu"] == "40%", "gpu usage shown")
assert(partial["widget.vram"] == nil, "vram omitted when the reading is absent")
assert(partial["widget.gpu_temp"] == nil, "no temperature when none was reported")

local unavailable = rowMap(widget.tooltipRows({ available = false }, true, { enabled = false }))
assert(unavailable["widget.tooltip_loading"] == "—", "loading row instead of fabricated zeroes")
assert(unavailable["widget.gamer_mode"] ~= nil, "gamer-mode state remains visible while metrics load")

local enabled = rowMap(widget.tooltipRows(
    full,
    true,
    { enabled = true, suspended = { { match = "a" }, { match = "b" } } }
))
assert(enabled["widget.gamer_mode"]:find("2"), "on state includes the suspended count")

-- ── live updates ──

-- State writes drive the bar; the widget never polls.
noctalia.state.set("metrics", full)
assert(rowMap(bar.tooltip)["widget.cpu"] == "25%", "tooltip refreshed from the metrics state")
noctalia.state.set("game_mode", { enabled = true, suspended = {} })
assert(bar.glyphColor == "primary", "glyph tinted while gamer mode is on, got " .. tostring(bar.glyphColor))
noctalia.state.set("game_mode", { enabled = false, suspended = {} })
assert(bar.glyphColor ~= "primary", "tint cleared once gamer mode is off")

-- A nil or malformed state write must not blank the bar or error.
noctalia.state.set("metrics", nil)
assert(type(bar.tooltip) == "table" and #bar.tooltip > 0, "tooltip survives a nil metrics write")
noctalia.state.set("game_mode", nil)
assert(type(bar.tooltip) == "table", "tooltip survives a nil game_mode write")

-- ── click ──

-- click_action = toggle sends a command carrying a fresh nonce.
mock.published.command = nil
onClick()
local command = mock.published.command
assert(type(command) == "table" and command.action == "toggle", "click sends a toggle command")
assert(type(command.nonce) == "number", "command carries a nonce")

local firstNonce = command.nonce
onClick()
assert(mock.published.command.nonce > firstNonce, "each click uses a fresh nonce")
assert(mock.toggledPanel == nil, "toggle action does not open the panel")

-- click_action = open_panel opens the panel instead.
mock.config.click_action = "open_panel"
mock.published.command = nil
onClick()
assert(mock.toggledPanel == "nomadcxx/gamer-mode:main", "opens the panel, got " .. tostring(mock.toggledPanel))
assert(mock.published.command == nil, "no command sent when opening the panel")

-- Left-click opens the panel by default, so a first-time user sees the metrics before
-- anything gets suspended.
mock.config.click_action = nil
mock.toggledPanel = nil
mock.published.command = nil
onClick()
assert(mock.toggledPanel == "nomadcxx/gamer-mode:main", "an unset click_action opens the panel")
assert(mock.published.command == nil, "the default click suspends nothing")

-- Right-click toggles gamer mode whatever click_action says, so the fast path is always
-- available.
for _, setting in ipairs({ "open_panel", "toggle" }) do
    mock.config.click_action = setting
    mock.toggledPanel = nil
    mock.published.command = nil
    onRightClick()
    local right = mock.published.command
    assert(type(right) == "table" and right.action == "toggle",
        "right-click toggles with click_action=" .. setting)
    assert(type(right.nonce) == "number", "right-click command carries a nonce")
    assert(mock.toggledPanel == nil, "right-click does not open the panel")
end

-- Left and right click draw nonces from the same counter, so a click of either kind is
-- never mistaken for a replay of the other.
mock.config.click_action = "toggle"
onClick()
local afterLeft = mock.published.command.nonce
onRightClick()
assert(mock.published.command.nonce > afterLeft, "right-click after left-click uses a fresh nonce")

-- Config changes re-render with the new glyph.
mock.config.glyph = "flame"
onConfigChanged()
assert(bar.glyph == "flame", "glyph updated on config change")

print("widget: passed")
