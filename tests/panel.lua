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
    setNeedsFrameTick = function(wants)
        _G.panel.frameTick = wants
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
    suspended = {
        { match = "gslapper", kind = "process", action = "freeze" },
        { match = "ollama.service", kind = "system-service", action = "stop" },
    },
}
mock.published.power = { available = true, active = "performance", profiles = { "balanced", "performance", "power-saver" } }

local p = dofile("gamer-mode/panel.luau")

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
assert(lines[1]:find("gslapper", 1, true), "entry names the target: " .. lines[1])
assert(lines[1]:find("process", 1, true), "entry names the kind: " .. lines[1])
-- A frozen target and a stopped one are not the same thing to a user deciding whether to
-- worry about it, so the action is spelled out.
assert(lines[1]:find("panel.frozen", 1, true), "frozen target labelled: " .. lines[1])
assert(lines[2]:find("panel.stopped", 1, true), "stopped target labelled: " .. lines[2])
-- An entry with no action reads as stopped, matching the engine default.
local legacyLines = p.suspendedLines({ enabled = true, suspended = { { match = "x", kind = "process" } } })
assert(legacyLines[1]:find("panel.stopped", 1, true), "absent action reads as stopped: " .. legacyLines[1])
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
-- While gamer mode runs the profile is fixed by the session, so only the power select
-- shows. The suspend selector appears when it is off, asserted further down.
assert(byKind.select == 1, "only the power select while enabled, got " .. tostring(byKind.select))

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

-- ── suspend profile selection ──

-- A plugin reads its own settings and cannot write them, so choosing a profile in the
-- panel travels with the enable command instead of changing the setting.
assert(type(p.suspendProfiles) == "function", "suspendProfiles exposed")
local profiles = p.suspendProfiles()
assert(#profiles == 2 and profiles[1] == "light" and profiles[2] == "heavy", "light then heavy")

-- The selection starts on the configured profile.
assert(p.selectedProfile() == "light", "starts on the configured profile, got " .. tostring(p.selectedProfile()))

-- Picking heavy makes the toggle enable heavy, without touching the setting.
onSuspendProfileChanged(1)
assert(p.selectedProfile() == "heavy", "selection updated")
mock.published.command = nil
onToggleGameMode()
assert(mock.published.command.profile == "heavy", "the toggle carries the chosen profile")
assert(mock.config.profile == "light", "the setting itself is untouched")

-- Back to light.
onSuspendProfileChanged(0)
mock.published.command = nil
onToggleGameMode()
assert(mock.published.command.profile == "light", "light selected again")

-- An out-of-range index leaves the selection alone rather than picking a wrong profile.
onSuspendProfileChanged(42)
assert(p.selectedProfile() == "light", "out-of-range suspend index ignored")

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

-- With gamer mode off the suspend profile becomes selectable, so one press both picks the
-- profile and applies it.
local selectsWhileOff = 0
for _, node in ipairs(nodes) do
    if node.kind == "select" then
        selectsWhileOff = selectsWhileOff + 1
    end
end
assert(selectsWhileOff == 2, "power and suspend selects while off, got " .. selectsWhileOff)

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
local powerSelects, suspendSelects, sawUnavailable = 0, 0, false
for _, node in ipairs(nodes) do
    if node.kind == "select" then
        if node.spec.onChange == "onPowerProfileChanged" then
            powerSelects = powerSelects + 1
        elseif node.spec.onChange == "onSuspendProfileChanged" then
            suspendSelects = suspendSelects + 1
        end
    end
    if node.kind == "label" and node.spec.text == "panel.power_unavailable" then
        sawUnavailable = true
    end
end
assert(powerSelects == 0, "no power select without powerprofilesctl")
assert(sawUnavailable, "explains why the power row is missing")
-- Losing powerprofilesctl must not take the suspend selector with it.
assert(suspendSelects == 1, "the suspend profile is still selectable, got " .. suspendSelects)

-- Nil state writes must not break rendering.
noctalia.state.set("metrics", nil)
noctalia.state.set("game_mode", nil)
noctalia.state.set("power", nil)
assert(type(rendered) == "table", "panel still renders after nil writes")

print("panel: passed")

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

-- ── the mark ──

-- Two files, never one path rewritten. Textures are cached by {path, targetSize}, so
-- rewriting one logo in place would keep serving the previous theme's raster.
assert(p.logoVariant(true) == "logo-dark.svg", "dark theme picks the dark mark")
assert(p.logoVariant(false) == "logo-light.svg", "light theme picks the light mark")

-- ── halo ──

-- A glow behind the mark is impossible: there is no stack, overlay or z-index node, so
-- the halo is an animated border ring on the image itself. ui.image takes border and
-- borderWidth, and a hex colour carries its own alpha byte.
local calm = p.haloSpec(0, 0)
local fierce = p.haloSpec(0, 1)
assert(fierce.borderWidth > calm.borderWidth, "more heat means a thicker ring")
assert(string.match(fierce.border, "^#%x%x%x%x%x%x%x%x$"),
    "the ring carries its own alpha, got " .. tostring(fierce.border))

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

-- Opening with the mode already on must arm it too; watchers only fire on change.
_G.panel.frameTick = nil
noctalia.state.set("game_mode", { enabled = true, busy = false, suspended = {} })
_G.panel.frameTick = nil
onOpen()
assert(_G.panel.frameTick == true, "opening with the mode on arms the tick")

-- The rendered mark actually receives the ring.
local function findImage(node)
    if type(node) ~= "table" then return nil end
    if node.kind == "image" then return node end
    for _, child in ipairs(node.children or {}) do
        local hit = findImage(child)
        if hit then return hit end
    end
    return nil
end
local litMark = findImage(rendered)
assert(litMark and litMark.spec.border, "the lit mark carries a halo border")
noctalia.state.set("game_mode", { enabled = false, busy = false, suspended = {} })
local darkMark = findImage(rendered)
assert(darkMark and darkMark.spec.border == nil, "an idle mark has no ring")
assert(darkMark.spec.radius == litMark.spec.radius, "the mark does not change shape on toggle")

-- onFrameTick advances the phase and re-renders; it is inert while the mode is off.
rendered = nil
onFrameTick(16)
assert(rendered == nil, "an idle panel does not re-render on a stray tick")
noctalia.state.set("game_mode", { enabled = true, busy = false, suspended = {} })
rendered = nil
onFrameTick(16)
assert(type(rendered) == "table", "a tick re-renders while the mode is on")
