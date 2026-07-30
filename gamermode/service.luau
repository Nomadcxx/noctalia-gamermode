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

-- ── suspend targets ──

local VALID_KINDS = {
    process = true,
    ["user-service"] = true,
    ["system-service"] = true,
    container = true,
}

-- Defaults are deliberately conservative: `light` covers wallpaper/media-adjacent
-- helpers, `heavy` adds the self-hosted media stack. Users override the whole list
-- through the advanced `targets` setting.
M.DEFAULT_TARGETS = {
    { match = "gslapper", kind = "process", profiles = { "light", "heavy" } },
    { match = "spotifyd.service", kind = "user-service", profiles = { "light", "heavy" } },
    { match = "adb", kind = "process", profiles = { "light", "heavy" } },
    { match = "kokoro-tts", kind = "container", profiles = { "light", "heavy" } },
    { match = "sonarr.service", kind = "system-service", profiles = { "heavy" } },
    { match = "radarr.service", kind = "system-service", profiles = { "heavy" } },
}

-- Every match string is interpolated into a shell command, so control characters are
-- refused outright rather than escaped.
local function validateShellValue(value)
    if type(value) ~= "string" or value == "" or value:find("[\n\r%z]") then
        return nil
    end
    return value
end

M.validateShellValue = validateShellValue

local function validEntry(entry)
    if type(entry) ~= "table" or not VALID_KINDS[entry.kind] then
        return false
    end
    if not validateShellValue(entry.match) then
        return false
    end
    if type(entry.profiles) ~= "table" or #entry.profiles == 0 then
        return false
    end
    for _, profile in ipairs(entry.profiles) do
        if type(profile) ~= "string" or profile == "" then
            return false
        end
    end
    return true
end

local function copyTargets(list)
    local out = {}
    for index, entry in ipairs(list) do
        local profiles = {}
        for profileIndex, profile in ipairs(entry.profiles) do
            profiles[profileIndex] = profile
        end
        out[index] = { match = entry.match, kind = entry.kind, profiles = profiles }
    end
    return out
end

-- parseTargets decodes the `targets` setting, dropping individual invalid entries.
-- An unset, unparseable or wholly invalid setting falls back to DEFAULT_TARGETS so a
-- typo can never leave gamer mode with an empty kill list and no explanation.
function M.parseTargets(raw)
    if type(raw) == "string" and raw ~= "" then
        local decoded, decodeError = noctalia.json.decode(raw)
        if type(decoded) ~= "table" then
            noctalia.log("gamermode: ignoring invalid targets setting: " .. tostring(decodeError or "not a JSON array"))
        else
            local out = {}
            local rejected = 0
            for _, entry in ipairs(decoded) do
                if validEntry(entry) then
                    out[#out + 1] = { match = entry.match, kind = entry.kind, profiles = entry.profiles }
                else
                    rejected = rejected + 1
                end
            end
            if rejected > 0 then
                noctalia.log("gamermode: dropped " .. rejected .. " invalid target entries")
            end
            if #out > 0 then
                return copyTargets(out)
            end
            noctalia.log("gamermode: targets setting had no usable entries, using defaults")
        end
    end
    return copyTargets(M.DEFAULT_TARGETS)
end

function M.targetsForProfile(targets, profile)
    local out = {}
    for _, target in ipairs(targets) do
        for _, tagged in ipairs(target.profiles) do
            if tagged == profile then
                out[#out + 1] = target
                break
            end
        end
    end
    return out
end

-- ── session snapshot ──

local SNAPSHOT_VERSION = 1
local UP_STATES = { running = true, active = true }

local function snapshotPath()
    local directory = noctalia.pluginDataDir()
    if not directory then
        return nil
    end
    return directory .. "/session.json"
end

function M.buildSnapshot(profile, powerProfileBefore, probedTargets)
    return {
        version = SNAPSHOT_VERSION,
        profile = profile,
        power_profile_before = powerProfileBefore,
        targets = probedTargets,
    }
end

-- restorePlan answers "what may gamer mode start back up?". A target qualifies only if
-- it was up when gamer mode began and is still down now: that keeps a manual restart
-- from being stomped and keeps something that was already off from being started.
-- `stateOf` returns the live state string, or nil when it could not be determined -- in
-- which case the target is left alone.
function M.restorePlan(snap, stateOf)
    local plan = {}
    for _, target in ipairs((snap and snap.targets) or {}) do
        if UP_STATES[target.was] and stateOf(target.match) == "down" then
            plan[#plan + 1] = target
        end
    end
    return plan
end

local function validSnapshotTarget(entry)
    return type(entry) == "table"
        and validateShellValue(entry.match) ~= nil
        and VALID_KINDS[entry.kind] ~= nil
        and type(entry.was) == "string"
end

function M.writeSnapshot(snap)
    local path = snapshotPath()
    if not path then
        noctalia.log("gamermode: no plugin data dir, cannot persist the session")
        return false
    end

    local encoded, encodeError = noctalia.json.encode(snap)
    if not encoded then
        noctalia.log("gamermode: could not encode the session: " .. tostring(encodeError))
        return false
    end

    noctalia.mkdirAll(noctalia.pluginDataDir())
    -- Write-then-rename: a shell crash mid-write must not leave a half-written session
    -- that would be read back as "no session" while targets are still suspended.
    local temporary = path .. ".tmp"
    if not noctalia.writeFile(temporary, encoded) then
        noctalia.log("gamermode: could not write the session file")
        return false
    end
    if not noctalia.renameFile(temporary, path) then
        noctalia.removeFile(temporary)
        noctalia.log("gamermode: could not replace the session file")
        return false
    end
    return true
end

-- readSnapshot returns nil for anything it cannot trust. Callers treat nil as "gamer
-- mode is off", which is the safe reading: it never invents targets to restart.
function M.readSnapshot()
    local path = snapshotPath()
    if not path then
        return nil
    end
    local contents = noctalia.readFile(path)
    if not contents then
        return nil
    end

    local decoded, decodeError = noctalia.json.decode(contents)
    if type(decoded) ~= "table" then
        noctalia.log("gamermode: ignoring unreadable session file: " .. tostring(decodeError or "not an object"))
        return nil
    end
    if decoded.version ~= SNAPSHOT_VERSION then
        noctalia.log("gamermode: ignoring session file with version " .. tostring(decoded.version))
        return nil
    end
    if type(decoded.targets) ~= "table" then
        noctalia.log("gamermode: ignoring session file without a target list")
        return nil
    end

    -- Keep the entries that are still usable rather than discarding the whole session:
    -- dropping it would report gamer mode as off while targets stay suspended.
    local targets = {}
    local dropped = 0
    for _, entry in ipairs(decoded.targets) do
        if validSnapshotTarget(entry) then
            targets[#targets + 1] = { match = entry.match, kind = entry.kind, was = entry.was }
        else
            dropped = dropped + 1
        end
    end
    if dropped > 0 then
        noctalia.log("gamermode: dropped " .. dropped .. " unusable entries from the session file")
    end

    return {
        version = decoded.version,
        profile = type(decoded.profile) == "string" and decoded.profile or "light",
        power_profile_before = type(decoded.power_profile_before) == "string" and decoded.power_profile_before or nil,
        targets = targets,
    }
end

function M.deleteSnapshot()
    local path = snapshotPath()
    if path then
        noctalia.removeFile(path)
    end
end

return M
