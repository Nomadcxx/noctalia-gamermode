-- The shell caps how many child processes may run at once and refuses further starts
-- rather than queueing them. A fan-out over the full target list has to respect that cap:
-- a probe that never runs reports no output, which reads as "down", which silently turns
-- enable into a no-op on a machine that had plenty to suspend. This suite drives enable
-- against a mock that enforces a cap the way the real shell does.
package.path = "./tests/?.lua;" .. package.path
local helpers = require("helpers")

local DATA_DIR = "/tmp/gamermode-test-concurrency"

-- The cap observed in the shell this was written against. The plugin must stay under it
-- without being told what it is.
local SHELL_CAPACITY = 8

-- Processes the scripted machine is running. Every one sits past the cap in the default
-- ordering, so each is a target that the unqueued fan-out lost.
local RUNNING = {
    ["qbittorrent-nox"] = "2074",
    ["gslapper"] = "296899",
    ["adb"] = "31337",
}
local RUNNING_NAMES = { "qbittorrent-nox", "gslapper", "adb" }

-- Active system units: the targets whose stop needs authorisation, and so the ones that
-- must be serialised behind a single password prompt.
local ACTIVE_UNITS = {
    "sonarr.service",
    "radarr.service",
    "prowlarr.service",
    "jackett.service",
    "fstrim.timer",
    "smartd.timer",
}

-- Units the scripted machine has since had stopped, filled in before the disable phase.
local STOPPED = {}

local function respond(command)
    if command == "powerprofilesctl get" then
        return { stdout = "balanced\n" }
    elseif command == "powerprofilesctl list" then
        return { stdout = "* balanced:\n    Driver:\tamd_pstate\n" }
    end
    -- Plain-text find: process names carry hyphens, which are pattern quantifiers.
    for name, pids in pairs(RUNNING) do
        if command == "pgrep -x '" .. name .. "'" then
            return { stdout = pids .. "\n", exitCode = 0 }
        end
    end
    for _, unit in ipairs(ACTIVE_UNITS) do
        if command == "systemctl is-active '" .. unit .. "'" then
            -- STOPPED lets the same scripted machine answer "active" during enable and
            -- "down" during disable, which is what the restore probes read.
            if STOPPED[unit] then
                return { stdout = "inactive\n", exitCode = 1 }
            end
            return { stdout = "active\n", exitCode = 0 }
        end
    end
    -- Everything else is absent: pgrep and systemctl both report failure.
    return { stdout = "", exitCode = 1 }
end

-- A systemctl call against a system unit: neither --user nor a read-only probe. These are
-- the calls polkit challenges.
local function isPrivileged(command)
    return command:find("^systemctl ") ~= nil
        and not command:find("--user", 1, true)
        and not command:find("is-active", 1, true)
end

local mock = helpers.newNoctalia({
    dataDir = DATA_DIR,
    capacity = SHELL_CAPACITY,
    respond = respond,
    config = { profile = "heavy", auto_performance = false },
})
local svc = dofile("gamer-mode/service.luau")

helpers.resetDir(DATA_DIR)

local targets = svc.targetsForProfile(svc.parseTargets(nil), "heavy")
assert(#targets > SHELL_CAPACITY * 4,
    "this suite is only meaningful with far more targets than the cap, got " .. #targets)

svc.refreshPower(function() end)
mock.drain()

mock.commands = {}
mock.peakInFlight = 0
mock.refused = 0

svc.enable("heavy")

-- Draining stands in for the shell completing children. Each completion lets the plugin
-- start the next queued command, so the work finishes over several rounds rather than in
-- the single burst that lost 165 of 173 commands.
local rounds = 0
while mock.drain() > 0 do
    rounds = rounds + 1
    assert(rounds < 500, "the queue never emptied")
end
assert(rounds > 1, "the whole run fit in one burst, so the cap was never exercised")

-- ── the cap is respected ──

assert(mock.refused == 0,
    "no command may be refused for capacity, saw " .. mock.refused .. " refusals")
assert(mock.peakInFlight <= SHELL_CAPACITY,
    "stayed within the shell cap, peaked at " .. mock.peakInFlight)
assert(mock.peakInFlight > 1, "commands still run in parallel, peaked at " .. mock.peakInFlight)

for _, entry in ipairs(mock.logs) do
    assert(not entry:find("could not start command", 1, true),
        "nothing was dropped for capacity: " .. entry)
end

-- ── every target was actually probed ──

local probed = {}
for _, command in ipairs(mock.commands) do
    local match = command:match("^pgrep %-x '(.+)'$")
        or command:match("is%-active '(.+)'$")
    if match then
        probed[match] = true
    end
end
for _, target in ipairs(targets) do
    assert(probed[target.match], "target never probed: " .. target.match)
end

-- ── and the answers reached the snapshot ──

local snap = svc.readSnapshot()
assert(snap, "a session was written")
assert(#snap.targets == #targets, "every target recorded, got " .. #snap.targets)

local recorded = {}
for _, entry in ipairs(snap.targets) do
    recorded[entry.match] = entry.was
end
for name in pairs(RUNNING) do
    assert(recorded[name] == "running",
        name .. " was running and must be recorded as such, got " .. tostring(recorded[name]))
end

-- The regression this suite exists for: a lost probe looks exactly like an idle machine.
local up = 0
for _, entry in ipairs(snap.targets) do
    if entry.was == "running" or entry.was == "active" then
        up = up + 1
    end
end
assert(up == #RUNNING_NAMES + #ACTIVE_UNITS, "exactly the up targets were seen as up, got " .. up)

-- Suspension followed, rather than the run reporting nothing to do.
local suspends = 0
for _, command in ipairs(mock.commands) do
    if command:find("^pkill %-STOP %-x '") then
        suspends = suspends + 1
    end
end
assert(suspends == #RUNNING_NAMES, "each running process got a freeze command, got " .. suspends)

-- ── every system unit goes out in one invocation ──

-- polkit retains an administrator's answer against the subject that gave it, and the
-- subject systemd reports is the calling systemctl process. One process per unit is one
-- subject per unit, so nothing is reused and the user answers a dialog per unit -- measured
-- at seven prompts for seven units on a real machine. A single invocation prompts once.
local privileged = {}
for _, command in ipairs(mock.commands) do
    if isPrivileged(command) then
        privileged[#privileged + 1] = command
    end
end
assert(#privileged == 1,
    "all system units must go out in one invocation, got " .. #privileged .. ": "
        .. table.concat(privileged, " | "))

-- And that one invocation has to actually carry every unit, or the rest go unstopped.
for _, unit in ipairs(ACTIVE_UNITS) do
    assert(privileged[1]:find("'" .. unit .. "'", 1, true),
        unit .. " missing from the batch: " .. privileged[1])
end
assert(privileged[1]:find("^systemctl stop "), "batched as a stop: " .. privileged[1])

-- Inactive units stay out of it: a batch that names them would prompt for work with
-- nothing to do.
assert(not privileged[1]:find("jellyfin", 1, true), "inactive units excluded: " .. privileged[1])

for index, round in ipairs(mock.rounds) do
    local concurrent = {}
    for _, command in ipairs(round) do
        if isPrivileged(command) then
            concurrent[#concurrent + 1] = command
        end
    end
    assert(#concurrent <= 1,
        "round " .. index .. " ran " .. #concurrent .. " privileged commands at once: "
            .. table.concat(concurrent, ", "))
end

-- And they get long enough to survive a human reading a dialog and typing.
for _, command in ipairs(mock.commands) do
    local timeout = mock.timeoutFor[command]
    if isPrivileged(command) then
        assert(timeout and timeout >= 60000,
            "a command that can wait on a password dialog needs a generous timeout, "
                .. command .. " got " .. tostring(timeout))
    else
        assert(timeout and timeout <= 30000,
            "unprivileged commands stay snappy, " .. command .. " got " .. tostring(timeout))
    end
end

-- ── disable batches too ──

-- Turning gamer mode off restarts the same units, so it faces the same prompt-per-unit
-- problem. It also has a probe phase in front of the starts, which must not leak a
-- privileged command per target.
for _, unit in ipairs(ACTIVE_UNITS) do
    STOPPED[unit] = true
end
mock.commands = {}
mock.rounds = {}

svc.disable()
rounds = 0
while mock.drain() > 0 do
    rounds = rounds + 1
    assert(rounds < 500, "the disable queue never emptied")
end

local restarts = {}
for _, command in ipairs(mock.commands) do
    if isPrivileged(command) then
        restarts[#restarts + 1] = command
    end
end
assert(#restarts == 1,
    "one invocation restarts every unit, got " .. #restarts .. ": " .. table.concat(restarts, " | "))
assert(restarts[1]:find("^systemctl start "), "batched as a start: " .. restarts[1])
for _, unit in ipairs(ACTIVE_UNITS) do
    assert(restarts[1]:find("'" .. unit .. "'", 1, true), unit .. " not restarted: " .. restarts[1])
end

-- The frozen processes are thawed, and the session is gone.
local thaws = 0
for _, command in ipairs(mock.commands) do
    if command:find("^pkill %-CONT %-x '") then
        thaws = thaws + 1
    end
end
assert(thaws == #RUNNING_NAMES, "each frozen process was thawed, got " .. thaws)
assert(svc.readSnapshot() == nil, "the session is cleared once disable finishes")

print("concurrency: passed")
