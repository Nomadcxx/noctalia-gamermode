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

local widget = dofile("gamermode/widget.luau")

assert(bar.glyph == "device-gamepad-2", "glyph applied from the setting, got " .. tostring(bar.glyph))
assert(type(bar.tooltip) == "string" and bar.tooltip ~= "", "a tooltip is set before the first sample")

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

local tip = widget.formatTooltip(full, true, { enabled = false })
assert(tip:find("CPU 25%%"), "cpu percentage, got: " .. tip)
assert(tip:find("59°C"), "cpu temp shown, rounded to whole degrees, got: " .. tip)
assert(tip:find("RAM 10.9G"), "ram in GiB, got: " .. tip)
assert(tip:find("GPU 18%%"), "gpu percentage")
assert(tip:find("61"), "gpu temp shown")
assert(tip:find("VRAM 2.5G"), "vram in GiB, got: " .. tip)

-- Temperatures are suppressed without inventing a unit-free number. "CPU" itself
-- contains a C, so check for the degree suffix specifically.
local noTemps = widget.formatTooltip(full, false, { enabled = false })
assert(not noTemps:find("%d°C"), "no temperature suffix when show_temps is off, got: " .. noTemps)
assert(not noTemps:find("58") and not noTemps:find("61"), "no temperature values")
assert(noTemps:find("CPU 25%%") and noTemps:find("GPU 18%%"), "usage still shown")

-- Missing GPU: no GPU or VRAM segment at all, rather than a zeroed one.
local noGpu = widget.formatTooltip(
    { available = true, cpuPerc = 0.5, memPerc = 0.5, memUsedMb = 1024, memTotalMb = 2048, gpuAvailable = false },
    true,
    { enabled = false }
)
assert(not noGpu:find("GPU"), "no gpu segment when unavailable, got: " .. noGpu)
assert(not noGpu:find("VRAM"), "no vram segment when unavailable")
assert(noGpu:find("CPU 50%%"), "cpu still shown")

-- Absent optional readings are skipped, not rendered as zero.
local partial = widget.formatTooltip(
    { available = true, cpuPerc = 0.1, memPerc = 0.2, memUsedMb = 512, memTotalMb = 2048, gpuAvailable = true, gpuPerc = 0.4 },
    true,
    { enabled = false }
)
assert(partial:find("GPU 40%%"), "gpu usage shown")
assert(not partial:find("VRAM"), "vram omitted when the reading is absent")
assert(not partial:find("°C"), "no temperature when none was reported")

-- Before the first sample the tooltip says so instead of showing zeroes.
local unavailable = widget.formatTooltip({ available = false }, true, { enabled = false })
assert(not unavailable:find("0%%"), "no fabricated zeroes, got: " .. unavailable)
assert(unavailable:find("tooltip_loading"), "falls back to the loading string")

-- Gamer mode being on is visible in the tooltip.
local enabled = widget.formatTooltip(full, true, { enabled = true, suspended = { { match = "a" }, { match = "b" } } })
assert(enabled:find("notify.enabled_title", 1, true) or enabled:find("ON", 1, true), "on-state marked, got: " .. enabled)
assert(enabled ~= tip, "on-state tooltip differs from the off-state one")

-- ── live updates ──

-- State writes drive the bar; the widget never polls.
noctalia.state.set("metrics", full)
assert(bar.tooltip:find("CPU 25%%"), "tooltip refreshed from the metrics state")
noctalia.state.set("game_mode", { enabled = true, suspended = {} })
assert(bar.glyphColor == "primary", "glyph tinted while gamer mode is on, got " .. tostring(bar.glyphColor))
noctalia.state.set("game_mode", { enabled = false, suspended = {} })
assert(bar.glyphColor ~= "primary", "tint cleared once gamer mode is off")

-- A nil or malformed state write must not blank the bar or error.
noctalia.state.set("metrics", nil)
assert(type(bar.tooltip) == "string" and bar.tooltip ~= "", "tooltip survives a nil metrics write")
noctalia.state.set("game_mode", nil)
assert(type(bar.tooltip) == "string", "tooltip survives a nil game_mode write")

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
assert(mock.toggledPanel == "nomadcxx/gamermode:main", "opens the panel, got " .. tostring(mock.toggledPanel))
assert(mock.published.command == nil, "no command sent when opening the panel")

-- Left-click opens the panel by default, so a first-time user sees the metrics before
-- anything gets suspended.
mock.config.click_action = nil
mock.toggledPanel = nil
mock.published.command = nil
onClick()
assert(mock.toggledPanel == "nomadcxx/gamermode:main", "an unset click_action opens the panel")
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
