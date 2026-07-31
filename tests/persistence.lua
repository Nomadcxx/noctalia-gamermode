-- Enable must not suspend anything it cannot later restore.
--
-- The session file is the only record of what was running before gamer mode touched it.
-- A process frozen with SIGSTOP or a unit stopped with no matching entry on disk is
-- unrecoverable through the plugin: disable reads the session, finds nothing, and returns.
-- So persistence is ordered ahead of the suspensions, and a write that fails aborts the
-- enable rather than reporting success over a half-applied machine.
package.path = "./tests/?.lua;" .. package.path
local helpers = require("helpers")

local DATA_DIR = "/tmp/gamermode-test-persistence"
local SNAPSHOT = DATA_DIR .. "/session.json"

local TARGETS = table.concat({
    '[{"match":"gslapper","kind":"process","action":"stop","profiles":["light"]}',
    '{"match":"qbittorrent-nox","kind":"process","action":"freeze","profiles":["light"]}',
    '{"match":"spotifyd.service","kind":"user-service","action":"stop","profiles":["light"]}]',
}, ",")

-- Every target is up, so each one has a suspension to lose.
local UP = {
    ["gslapper"] = "4242",
    ["qbittorrent-nox"] = "2074",
    ["spotifyd.service"] = "active",
}

local powerProfile = "balanced"

-- Set once a suspension command is seen while no session file is on disk. This is the
-- failure the ordering exists to prevent, and it is checked in both phases.
local suspendedWithoutSession = nil

local function isSuspendCommand(command)
    return command:find("pkill", 1, true) ~= nil
        or command:find("stop '", 1, true) ~= nil
        or command:find("kill --kill-whom", 1, true) ~= nil
end

local function respond(command)
    if isSuspendCommand(command) and not suspendedWithoutSession then
        local file = io.open(SNAPSHOT, "r")
        if file then
            file:close()
        else
            suspendedWithoutSession = command
        end
    end

    for match, output in pairs(UP) do
        if command:find("'" .. match .. "'", 1, true) then
            if command:find("is-active", 1, true) or command:find("pgrep", 1, true) then
                return { stdout = output, exitCode = 0 }
            end
        end
    end
    if command == "powerprofilesctl get" then
        return { stdout = powerProfile .. "\n" }
    elseif command == "powerprofilesctl list" then
        return { stdout = "* balanced:\n    Driver:\tamd_pstate\n\n  performance:\n    Driver:\tamd_pstate\n" }
    elseif command:find("^powerprofilesctl set ") then
        powerProfile = command:match("set '?([%w%-]+)'?")
        return { stdout = "" }
    end
    return { stdout = "" }
end

helpers.resetDir(DATA_DIR)
local mock = helpers.newNoctalia({
    dataDir = DATA_DIR,
    config = {
        profile = "light",
        auto_performance = true,
        poll_interval = "3",
        targets = TARGETS,
    },
    respond = respond,
})

local svc = dofile("gamer-mode/service.luau")

-- ── the write fails ──

-- Stands in for a full disk, a read-only data dir, or a shell that could not hand one
-- over. writeSnapshot already reports each of those as false; the question here is only
-- what enable does with that answer.
local realWriteFile = mock.writeFile
mock.writeFile = function(path, contents)
    if path:find("session.json", 1, true) then
        return false
    end
    return realWriteFile(path, contents)
end

mock.commands = {}
mock.notifications = {}
mock.logs = {}

svc.enable("light")

assert(not mock.fileExists(SNAPSHOT), "no session file, which is the premise of this phase")

-- Probing is harmless and has to happen first: the snapshot is built from what it finds.
assert(helpers.ranCommand(mock, "pgrep -x 'gslapper'"), "targets are still probed")

-- Nothing was suspended, so there is nothing stranded.
assert(not helpers.ranCommand(mock, "pkill -x 'gslapper'"), "did not stop a process it could not restore")
assert(not helpers.ranCommand(mock, "pkill -STOP"), "did not freeze a process it could not thaw")
assert(not helpers.ranCommand(mock, "systemctl --user stop 'spotifyd.service'"),
    "did not stop a unit it could not restart")

-- Nor was the machine changed in any other way that disable is expected to hand back.
assert(not helpers.ranCommand(mock, "powerprofilesctl set"), "power profile left alone")
assert(powerProfile == "balanced", "power profile actually unchanged")

-- The published state says off, and it is telling the truth.
assert(mock.published.game_mode.enabled == false, "gamer mode published as off")
assert(mock.published.game_mode.busy == false, "busy cleared, so the user can try again")
assert(#mock.published.game_mode.suspended == 0, "nothing reported suspended")

-- Silence would leave the user with a bar icon that did not change and no reason why.
assert(#mock.notifications == 1, "the user is told, got " .. #mock.notifications .. " notifications")
assert(mock.notifications[1].kind == "error", "reported as an error, got " .. tostring(mock.notifications[1].kind))

local logged = false
for _, entry in ipairs(mock.logs) do
    if entry:find("could not write the session file", 1, true) then
        logged = true
    end
end
assert(logged, "the underlying write failure is in the log")

-- A failed enable is not a half-enable: enabling again starts from scratch rather than
-- being turned away by the idempotence guard.
mock.writeFile = realWriteFile

-- ── the write succeeds ──

mock.commands = {}
mock.notifications = {}

svc.enable("light")

assert(mock.fileExists(SNAPSHOT), "session file written")
assert(mock.published.game_mode.enabled == true, "gamer mode published as on")
assert(#mock.published.game_mode.suspended == 3, "all three targets recorded")

assert(helpers.ranCommand(mock, "pkill -x 'gslapper'"), "stopped the process target")
assert(helpers.ranCommand(mock, "pkill -STOP -x 'qbittorrent-nox'"), "froze the freeze target")
assert(helpers.ranCommand(mock, "systemctl --user stop 'spotifyd.service'"), "stopped the user service")
assert(powerProfile == "performance", "switched to the performance profile")

-- The ordering, checked against the filesystem at the moment each suspension was issued
-- rather than inferred from the command list.
assert(suspendedWithoutSession == nil,
    "every suspension ran with a session already on disk, but this one did not: "
        .. tostring(suspendedWithoutSession))

-- A snapshot written before the suspensions can name a target that was never suspended,
-- if the suspend command itself then failed. That direction is safe and is what makes
-- this ordering the right one: disable thaws unconditionally, which is a no-op on a
-- process that was never frozen, and restarts a stop target only after a live probe says
-- it is still down.
local snap = svc.readSnapshot()
assert(snap and #snap.targets == 3, "the snapshot records what was probed, not what succeeded")

print("persistence: passed")
