--!nonstrict
--
-- Gamer Mode service: publishes system metrics and owns the snapshot-based game-mode
-- engine. The panel and widget are thin readers of `noctalia.state`; every mutation
-- arrives here as a `command` state write.
--
-- Luau's sandbox gives plugins no `io`, no `os.execute`/`os.remove` and no `load`, so
-- all filesystem access goes through noctalia.readFile/writeFile/removeFile/mkdirAll
-- and the snapshot is stored as JSON via noctalia.json.

local M = {}

local BYTES_PER_MIB = 1048576

local function clampFraction(percent)
    local value = tonumber(percent)
    if not value then
        return 0
    end
    return math.max(0, math.min(1, value / 100))
end

-- normalize converts a noctalia.systemStats() sample into the published `metrics`
-- shape: percentages as 0-1 fractions, memory in MiB.
--
-- Optional readings stay nil rather than becoming zero, so the UI can say "unsupported"
-- instead of drawing an empty bar that looks like a real 0% reading.
function M.normalize(raw)
    if type(raw) ~= "table" then
        return nil
    end

    local cpu = type(raw.cpu) == "table" and raw.cpu or {}
    local ram = type(raw.ram) == "table" and raw.ram or {}
    local gpu = type(raw.gpu) == "table" and raw.gpu or {}

    local metrics = {
        cpuPerc = clampFraction(cpu.usagePercent),
        cpuTemp = tonumber(cpu.tempC),
        memPerc = clampFraction(ram.usagePercent),
        memUsedMb = tonumber(ram.usedMb) or 0,
        memTotalMb = tonumber(ram.totalMb) or 0,
        gpuAvailable = false,
    }

    local gpuPercent = tonumber(gpu.usagePercent)
    if gpuPercent then
        metrics.gpuPerc = clampFraction(gpuPercent)
        metrics.gpuAvailable = true
    end
    local gpuTemp = tonumber(gpu.tempC)
    if gpuTemp then
        metrics.gpuTemp = gpuTemp
        metrics.gpuAvailable = true
    end

    -- VRAM needs both halves: a used figure without a total cannot be drawn as a ratio.
    local vramUsed = tonumber(gpu.vramUsedBytes)
    local vramTotal = tonumber(gpu.vramTotalBytes)
    if vramUsed and vramTotal and vramTotal > 0 then
        metrics.vramUsedMb = vramUsed / BYTES_PER_MIB
        metrics.vramTotalMb = vramTotal / BYTES_PER_MIB
        metrics.vramPerc = math.max(0, math.min(1, vramUsed / vramTotal))
        metrics.gpuAvailable = true
    end

    return metrics
end

return M
