--!nonstrict
--
-- Gamer Mode panel. Like the widget it owns no state: it renders what the service
-- publishes and sends commands back through `noctalia.state`.
--
-- Interactive props (onClick/onChange) must be the *names* of global functions -- the
-- ui bridge resolves handlers by name and cannot call a Lua closure.

local MIB_PER_GIB = 1024

local M = {}

local metrics = noctalia.state.get("metrics") or { available = false }
local gameMode = noctalia.state.get("game_mode") or { enabled = false, busy = false, suspended = {} }
local power = noctalia.state.get("power") or { available = false, profiles = {} }
local nonceCounter = 0

local function tr(key, subst)
    return noctalia.tr(key, subst)
end

local function clamp(value)
    local number = tonumber(value) or 0
    return math.max(0, math.min(1, number))
end

local function percent(fraction)
    return string.format("%d%%", math.floor(clamp(fraction) * 100 + 0.5))
end

local function gibibytes(mib)
    return (tonumber(mib) or 0) / MIB_PER_GIB
end

local function usedOfTotal(usedMib, totalMib)
    return string.format("%.1f / %.1f GiB", gibibytes(usedMib), gibibytes(totalMib))
end

local function withTemp(detail, showTemps, temp)
    if showTemps and tonumber(temp) then
        return detail .. string.format("   %d°C", math.floor(tonumber(temp) + 0.5))
    end
    return detail
end

-- buildRows produces one entry per reading the machine actually reports. Unsupported
-- readings are absent rather than drawn as an empty bar, which would look like a real
-- idle reading.
function M.buildRows(m, showTemps)
    local rows = {}
    if type(m) ~= "table" or not m.available then
        return rows
    end

    rows[#rows + 1] = {
        label = "CPU",
        glyph = "cpu-usage",
        progress = clamp(m.cpuPerc),
        detail = withTemp(percent(m.cpuPerc), showTemps, m.cpuTemp),
    }
    rows[#rows + 1] = {
        label = "RAM",
        glyph = "memory",
        progress = clamp(m.memPerc),
        detail = usedOfTotal(m.memUsedMb, m.memTotalMb),
    }

    if m.gpuAvailable and m.gpuPerc then
        rows[#rows + 1] = {
            label = "GPU",
            glyph = "gpu-usage",
            progress = clamp(m.gpuPerc),
            detail = withTemp(percent(m.gpuPerc), showTemps, m.gpuTemp),
        }
    end
    if m.vramUsedMb and m.vramTotalMb then
        rows[#rows + 1] = {
            label = "VRAM",
            glyph = "storage",
            progress = clamp(m.vramPerc),
            detail = usedOfTotal(m.vramUsedMb, m.vramTotalMb),
        }
    end
    return rows
end

function M.suspendedLines(gm)
    local lines = {}
    for _, target in ipairs((type(gm) == "table" and gm.suspended) or {}) do
        -- Frozen and stopped are materially different to a user reading this list: one
        -- resumes exactly where it left off, the other was shut down and restarted.
        local state = target.action == "freeze" and tr("panel.frozen") or tr("panel.stopped")
        lines[#lines + 1] = string.format("%s (%s, %s)", tostring(target.match), tostring(target.kind), state)
    end
    return lines
end

-- M.powerProfileAt resolves the zero-based index the select reports back to a profile
-- name, or nil when the index no longer matches the published list.
function M.powerProfileAt(index)
    local position = (tonumber(index) or -1) + 1
    local profiles = (type(power) == "table" and power.profiles) or {}
    return profiles[position]
end

local function selectedPowerIndex()
    for index, profile in ipairs(power.profiles or {}) do
        if profile == power.active then
            return index - 1
        end
    end
    return 0
end

-- ── rendering ──

local function metricRow(row)
    return ui.column({ gap = 4 }, {
        ui.row({ align = "center", gap = 8 }, {
            ui.glyph({ name = row.glyph, size = 14, color = "on_surface_variant" }),
            ui.label({ text = row.label, color = "on_surface_variant", width = 48 }),
            ui.label({
                text = row.detail,
                color = "on_surface_variant",
                fontSize = 11,
                flexGrow = 1,
                align = "end",
            }),
        }),
        ui.progress({
            height = 4,
            progress = row.progress,
            fill = "primary",
            track = "surface_variant",
            radius = 2,
        }),
    })
end

local function toggleButton()
    if gameMode.busy then
        return ui.button({ text = tr("panel.working"), enabled = false, variant = "ghost" })
    end
    return ui.button({
        text = gameMode.enabled and tr("panel.disable") or tr("panel.enable"),
        glyph = gameMode.enabled and "player-stop-filled" or "player-play-filled",
        selected = gameMode.enabled,
        onClick = "onToggleGameMode",
    })
end

local function header()
    return ui.row({ align = "center", gap = 8 }, {
        ui.glyph({ name = "device-gamepad-2", size = 18, color = gameMode.enabled and "primary" or "on_surface" }),
        ui.label({ text = tr("panel.title"), fontSize = 16, fontWeight = "bold", flexGrow = 1 }),
        toggleButton(),
    })
end

local function powerRow()
    if not power.available then
        return ui.label({ text = tr("panel.power_unavailable"), color = "on_surface_variant", fontSize = 11 })
    end
    return ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = tr("panel.power_profile"), color = "on_surface_variant", width = 110 }),
        ui.select({
            options = power.profiles,
            selectedIndex = selectedPowerIndex(),
            flexGrow = 1,
            onChange = "onPowerProfileChanged",
        }),
    })
end

-- The suspend profile is a plugin setting, and plugins cannot write their own settings,
-- so it is shown read-only with a route to the settings window.
local function modeProfileRow()
    return ui.row({ align = "center", gap = 8 }, {
        ui.label({ text = tr("panel.mode_profile"), color = "on_surface_variant", width = 110 }),
        ui.label({ text = tr("panel.profiles." .. tostring(gameMode.profile or "light")), flexGrow = 1 }),
    })
end

local function suspendedSection(children)
    if not gameMode.enabled then
        return
    end
    children[#children + 1] = ui.label({ text = tr("panel.suspended"), color = "on_surface_variant", fontSize = 12 })
    local lines = M.suspendedLines(gameMode)
    if #lines == 0 then
        children[#children + 1] = ui.label({ text = tr("panel.nothing_suspended"), fontSize = 11 })
        return
    end
    for _, line in ipairs(lines) do
        children[#children + 1] = ui.label({ text = line, fontSize = 11 })
    end
end

local function body()
    local showTemps = noctalia.getConfig("show_temps") ~= false
    local children = {}

    local rows = M.buildRows(metrics, showTemps)
    if #rows == 0 then
        children[#children + 1] = ui.label({
            text = tr("panel.metrics_unavailable"),
            color = "on_surface_variant",
            fontSize = 11,
        })
    else
        children[#children + 1] = ui.label({
            text = tr("panel.performance"),
            color = "on_surface_variant",
            fontSize = 12,
        })
        for _, row in ipairs(rows) do
            children[#children + 1] = metricRow(row)
        end
        if not metrics.gpuAvailable then
            children[#children + 1] = ui.label({
                text = tr("panel.gpu_unsupported"),
                color = "on_surface_variant",
                fontSize = 11,
            })
        end
    end

    children[#children + 1] = ui.separator({})
    children[#children + 1] = powerRow()
    children[#children + 1] = modeProfileRow()
    suspendedSection(children)

    return ui.column({ gap = 10, flexGrow = 1 }, children)
end

local function footer()
    return ui.row({ align = "center", gap = 8 }, {
        ui.spacer({ flexGrow = 1 }),
        ui.button({ text = tr("panel.settings"), glyph = "plugin", variant = "ghost", onClick = "onOpenSettings" }),
    })
end

local function render()
    panel.render(ui.column({ padding = 16, gap = 10, flexGrow = 1 }, {
        header(),
        ui.scroll({ flexGrow = 1, gap = 10 }, { body() }),
        footer(),
    }))
end

local function sendCommand(action, extra)
    nonceCounter = nonceCounter + 1
    local command = { nonce = noctalia.nowMs() * 1000 + nonceCounter, action = action }
    for key, value in pairs(extra or {}) do
        command[key] = value
    end
    noctalia.state.set("command", command)
end

-- ── shell entry points (must be globals) ──

function onOpen()
    metrics = noctalia.state.get("metrics") or metrics
    gameMode = noctalia.state.get("game_mode") or gameMode
    power = noctalia.state.get("power") or power
    render()
end

function onToggleGameMode()
    sendCommand("toggle")
end

function onPowerProfileChanged(index)
    local profile = M.powerProfileAt(index)
    if not profile then
        noctalia.log("gamermode: ignoring an out-of-range power profile selection")
        return
    end
    sendCommand("set-power-profile", { profile = profile })
end

function onOpenSettings()
    noctalia.openSettings()
end

function onCloseClicked()
    panel.close()
end

noctalia.state.watch("metrics", function(value)
    metrics = type(value) == "table" and value or { available = false }
    render()
end)

noctalia.state.watch("game_mode", function(value)
    gameMode = type(value) == "table" and value or { enabled = false, busy = false, suspended = {} }
    render()
end)

noctalia.state.watch("power", function(value)
    power = type(value) == "table" and value or { available = false, profiles = {} }
    render()
end)

return M
