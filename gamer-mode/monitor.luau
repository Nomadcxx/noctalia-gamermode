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
