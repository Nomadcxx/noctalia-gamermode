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
local PLACEHOLDER = "—"
-- A role with an alpha suffix rather than a hex value, so the tint follows the theme.
local PILL_FILL = "primary/0.15"
-- Noctalia frames its own bar widgets with a stadium: resolvedBarCapsuleRadius is
-- min(width, height) * 0.5 (shell widget.cpp). Ask for more than any bar is tall and the
-- renderer clamps to that same half-height, so the pill matches the built-in capsules
-- instead of guessing a corner size.
local PILL_RADIUS = 999

-- The readout is driven by state.watch, so the tick only exists for animation. It cannot
-- be switched off, so idle is slowed from the 250ms default instead.
local IDLE_INTERVAL_MS = 1000
local FLARE_INTERVAL_MS = 33
local FLARE_DURATION_MS = 900

local FLAME_COLUMNS = 28
local FLAME_HEIGHT = 12
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

local M = {}

local initialMetrics = noctalia.state.get("metrics")
local initialGameMode = noctalia.state.get("game_mode")
local metrics = type(initialMetrics) == "table" and initialMetrics or { available = false }
local gameMode = type(initialGameMode) == "table" and initialGameMode or { enabled = false, suspended = {} }
local nonceCounter = 0
local flameField = {}
for i = 1, FLAME_COLUMNS do
    flameField[i] = 0
end
local flareStartedMs = nil
local wasEnabled = gameMode.enabled == true

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
    if value >= 1024 * 1024 * 1024 then
        return string.format("%.1fG", value / (1024 * 1024 * 1024))
    elseif value >= 1024 * 1024 then
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
        tip = function(m) return m.cpuTemp and string.format("%d°C", math.floor(m.cpuTemp + 0.5)) or nil end,
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
        tip = function(m) return m.gpuTemp and string.format("%d°C", math.floor(m.gpuTemp + 0.5)) or nil end,
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
        highlight_gamer_mode = bool("highlight_gamer_mode", true),
        flame = noctalia.getConfig("flame") or "flare",
        flame_style = noctalia.getConfig("flame_style") or "graph",
    }
end

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

-- The bar and the tooltip are complements: a segment the user put on the bar is left out
-- of the tooltip, so hovering always adds something.
function M.tooltipRows(m, gm, config)
    m = type(m) == "table" and m or {}
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

    local validGm = type(gm) == "table" and gm or {}
    local suspended = type(validGm.suspended) == "table" and validGm.suspended or {}
    rows[#rows + 1] = {
        key = noctalia.tr("widget.gamer_mode"),
        value = validGm.enabled == true
            and noctalia.trp("widget.gamer_mode_on", #suspended)
            or noctalia.tr("widget.gamer_mode_off"),
    }
    return rows
end

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
            fillOpacity = 1.0,
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

-- The pill belongs to whichever root the layout produced. Padding and radius are
-- unconditional in both orientations: painting the fill must not change the layout, or
-- every digit shifts the moment gamer mode is toggled.
-- A 12px band along one edge is easy to miss on a glance at a busy bar. The capsule
-- itself carries the heat as well, shifting off the theme tint into ember as the machine
-- works, so a loaded machine is obvious without looking for the flame.
local function pillFill(burning)
    if burning == nil then
        return PILL_FILL
    end
    local alpha = math.floor(0x24 + math.max(0, math.min(1, burning)) * 0x5c)
    return string.format("#ff5a00%02x", alpha)
end

local function pillProps(config, gm, vertical, burning)
    local props = vertical
            and { align = "center", gap = 2, paddingH = 3, paddingV = 6, radius = PILL_RADIUS }
            or { align = "stretch", gap = 1, paddingH = 6, paddingV = 3, radius = PILL_RADIUS }
    if config.highlight_gamer_mode and gm and gm.enabled then
        props.fill = pillFill(burning)
    end
    return props
end

-- Segments of the same group sit close together and groups sit further apart, which is
-- what makes three clusters read as three clusters rather than one run of numbers.
function M.buildTree(m, gm, config, vertical, burning)
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
        return ui.column(pillProps(config, gm, true, nil), rows)
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
    local props = pillProps(config, gm, false, burning)
    local lit = config.highlight_gamer_mode and gm and gm.enabled

    local stack = { ui.row({ align = "center", gap = 12 }, children) }
    -- Absent, not flat: a band drawn at zero height is still a node to reconcile, and it
    -- reads as a dead strip under the numbers.
    if lit and burning ~= nil then
        stack[#stack + 1] = M.flameBand(flameField, config.flame_style)
    end
    return ui.column(props, stack)
end

local function burningLevel(config)
    if barWidget.isVertical() or config.flame == "off" then
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

noctalia.state.watch("metrics", function(value)
    metrics = type(value) == "table" and value or { available = false }
    render()
end)

noctalia.state.watch("game_mode", function(value)
    gameMode = type(value) == "table" and value or { enabled = false, suspended = {} }
    local config = M.readConfig()
    local enabled = gameMode.enabled == true
    local horizontal = not barWidget.isVertical()

    if enabled and not wasEnabled and config.highlight_gamer_mode and horizontal then
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

-- Called by the shell on its timer. It does nothing at all unless something is burning,
-- which is what keeps the idle cost to one no-op call a second.
function update()
    local config = M.readConfig()
    if barWidget.isVertical() then
        flareStartedMs = nil
        noctalia.setUpdateInterval(IDLE_INTERVAL_MS)
        return
    end
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
    if barWidget.isVertical() or config.flame == "off" or not (gameMode.enabled and config.highlight_gamer_mode) then
        flareStartedMs = nil
        noctalia.setUpdateInterval(IDLE_INTERVAL_MS)
    elseif config.flame == "always" then
        noctalia.setUpdateInterval(FLARE_INTERVAL_MS)
    elseif flareStartedMs == nil then
        noctalia.setUpdateInterval(IDLE_INTERVAL_MS)
    end
    render()
end

noctalia.setUpdateInterval(IDLE_INTERVAL_MS)
-- `always` is a free-running loop, not an edge: gamer mode may already be on when the
-- widget loads, and no transition will fire to start it.
local bootConfig = M.readConfig()
if not barWidget.isVertical()
        and bootConfig.flame == "always"
        and gameMode.enabled
        and bootConfig.highlight_gamer_mode then
    noctalia.setUpdateInterval(FLARE_INTERVAL_MS)
end
render()

return M
