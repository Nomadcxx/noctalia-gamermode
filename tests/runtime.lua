-- Service runtime: published state shapes, the enable/disable flow, and the
-- nonce-guarded command handler. runAsync is scripted to stand in for a real system.
package.path = "./tests/?.lua;" .. package.path
local helpers = require("helpers")

local DATA_DIR = "/tmp/gamermode-test-runtime"
local SNAPSHOT = DATA_DIR .. "/session.json"

-- `powerprofilesctl list` marks the active profile with a leading star.
local function powerList(activeProfile)
    local lines = {}
    for _, name in ipairs({ "balanced", "performance", "power-saver" }) do
        lines[#lines + 1] = (name == activeProfile and "* " or "  ") .. name .. ":"
        lines[#lines + 1] = "    Driver:\tamd_pstate"
        lines[#lines + 1] = "    Degraded:   no"
        lines[#lines + 1] = ""
    end
    return table.concat(lines, "\n")
end

local POWER_LIST = powerList("balanced")

-- The scripted world. `live` drives probe answers so the same target can be reported
-- running during enable and down during disable.
local live = {
    ["gslapper"] = "4242",
    ["spotifyd.service"] = "active",
    ["adb"] = "",
    ["kokoro-tts"] = "true",
}
local powerProfile = "balanced"
local failures = {}

local function respond(command)
    for match, output in pairs(live) do
        if command:find("'" .. match .. "'", 1, true) then
            if command:find("is-active", 1, true) or command:find("pgrep", 1, true) or command:find("inspect", 1, true) then
                return { stdout = output, exitCode = output == "" and 1 or 0 }
            end
        end
    end
    if command == "powerprofilesctl get" then
        return { stdout = powerProfile .. "\n" }
    elseif command == "powerprofilesctl list" then
        return { stdout = powerList(powerProfile) }
    elseif command:find("^powerprofilesctl set ") then
        powerProfile = command:match("set '?([%w%-]+)'?")
        return { stdout = "" }
    end
    for _, failing in ipairs(failures) do
        if command:find(failing, 1, true) then
            return { exitCode = 1, stderr = "scripted failure" }
        end
    end
    return { stdout = "" }
end

-- An explicit target list, so this suite exercises the runtime flow rather than whatever
-- happens to ship as the defaults -- tests/defaults.lua owns those.
local RUNTIME_TARGETS = table.concat({
    '[{"match":"gslapper","kind":"process","action":"stop","profiles":["light","heavy"]}',
    '{"match":"spotifyd.service","kind":"user-service","action":"stop","profiles":["light","heavy"]}',
    '{"match":"adb","kind":"process","action":"stop","profiles":["light","heavy"]}',
    '{"match":"kokoro-tts","kind":"container","action":"stop","profiles":["light","heavy"]}',
    '{"match":"sonarr.service","kind":"system-service","action":"stop","profiles":["heavy"]}',
    '{"match":"radarr.service","kind":"system-service","action":"stop","profiles":["heavy"]}]',
}, ",")

helpers.resetDir(DATA_DIR)
local mock = helpers.newNoctalia({
    dataDir = DATA_DIR,
    config = {
        profile = "light",
        auto_performance = true,
        poll_interval = "3",
        show_temps = true,
        targets = RUNTIME_TARGETS,
    },
    respond = respond,
})

local svc = dofile("gamer-mode/service.luau")

-- ── power profile listing ──

local profiles, active = svc.parsePowerProfiles(POWER_LIST)
assert(#profiles == 3, "three profiles parsed, got " .. #profiles)
assert(profiles[1] == "balanced" and profiles[2] == "performance" and profiles[3] == "power-saver", "profile order")
assert(active == "balanced", "active profile marked with *, got " .. tostring(active))
local none, noActive = svc.parsePowerProfiles("garbage output")
assert(#none == 0 and noActive == nil, "unparseable listing yields nothing")

-- ── init ──

-- Loading the service publishes every state key the UI reads, so a panel opened before
-- the first poll still renders.
assert(type(mock.published.metrics) == "table", "metrics published at init")
assert(mock.published.metrics.available == true, "metrics available")
assert(math.abs(mock.published.metrics.cpuPerc - 0.25) < 0.0001, "metrics normalized from systemStats")
assert(type(mock.published.game_mode) == "table", "game_mode published at init")
assert(mock.published.game_mode.enabled == false, "disabled without a session file")
assert(mock.published.game_mode.profile == "light", "profile falls back to the setting")
assert(#mock.published.game_mode.suspended == 0, "nothing suspended")
assert(type(mock.published.power) == "table" and mock.published.power.available == true, "power published at init")
assert(mock.published.power.active == "balanced", "active power profile published")

-- ── enable ──

svc.toggle()

local gameMode = mock.published.game_mode
assert(gameMode.enabled == true, "enabled after the first toggle")
assert(gameMode.busy == false, "not busy once the flow settles")
assert(gameMode.profile == "light", "enabled with the configured profile")

-- Only the three targets that were actually up are reported as suspended; `adb` was
-- already down.
assert(#gameMode.suspended == 3, "three targets suspended, got " .. #gameMode.suspended)
local suspendedByMatch = {}
for _, entry in ipairs(gameMode.suspended) do
    suspendedByMatch[entry.match] = entry.kind
end
assert(suspendedByMatch["gslapper"] == "process", "gslapper suspended")
assert(suspendedByMatch["spotifyd.service"] == "user-service", "spotifyd suspended")
assert(suspendedByMatch["kokoro-tts"] == "container", "container suspended")
assert(suspendedByMatch["adb"] == nil, "an already-down target is not reported as suspended")

-- Probes ran for every light target, stops only for the ones that were up.
assert(helpers.ranCommand(mock, "pgrep -x 'gslapper'"), "probed the process target")
assert(helpers.ranCommand(mock, "pgrep -x 'adb'"), "probed the already-down target")
assert(helpers.ranCommand(mock, "systemctl --user is-active 'spotifyd.service'"), "probed the user service")
assert(helpers.ranCommand(mock, "docker inspect -f '{{.State.Running}}' 'kokoro-tts'"), "probed the container")

assert(helpers.ranCommand(mock, "pkill -x 'gslapper'"), "stopped the running process")
assert(helpers.ranCommand(mock, "systemctl --user stop 'spotifyd.service'"), "stopped the active user service")
assert(helpers.ranCommand(mock, "docker stop 'kokoro-tts'"), "stopped the running container")
assert(not helpers.ranCommand(mock, "pkill -x 'adb'"), "did not stop an already-down target")

-- Heavy-only defaults are untouched under the light profile.
assert(not helpers.ranCommand(mock, "sonarr.service"), "heavy-only target skipped under light")

assert(helpers.ranCommand(mock, "powerprofilesctl set 'performance'"), "switched to the performance profile")
assert(powerProfile == "performance", "power profile actually changed")
assert(mock.published.power.active == "performance", "power state republished after the switch")

-- The session survives a shell restart: it is on disk, and the previous power profile is
-- recorded so disable can hand it back.
assert(mock.fileExists(SNAPSHOT), "session file written")
local persisted = svc.readSnapshot()
assert(persisted and #persisted.targets == 4, "session records all four probed targets")
assert(persisted.power_profile_before == "balanced", "captured the pre-enable power profile")

assert(#mock.notifications == 1 and mock.notifications[1].kind == "info", "notified on enable")

-- Enabling again is a no-op: no second round of stops, and the session is not rewritten.
local commandsBefore = #mock.commands
svc.enable()
assert(#mock.commands == commandsBefore, "enable is idempotent while a session exists")
assert(svc.readSnapshot().power_profile_before == "balanced", "session untouched by a redundant enable")

-- ── disable ──

-- The user restarted spotifyd by hand while gamer mode was on. It must not be touched.
live["gslapper"] = ""
live["spotifyd.service"] = "active"
live["kokoro-tts"] = "false"
mock.commands = {}
mock.notifications = {}

svc.toggle()

assert(mock.published.game_mode.enabled == false, "disabled after the second toggle")
assert(mock.published.game_mode.busy == false, "not busy once disable settles")
assert(#mock.published.game_mode.suspended == 0, "nothing reported suspended once disabled")
assert(not mock.fileExists(SNAPSHOT), "session file deleted")

-- Restarted only what was down. A process has no start command, so it is skipped.
assert(helpers.ranCommand(mock, "docker start 'kokoro-tts'"), "restarted the still-down container")
assert(not helpers.ranCommand(mock, "systemctl --user start 'spotifyd.service'"), "manual restart not stomped")
assert(not helpers.ranCommand(mock, "start 'gslapper'"), "a bare process is not relaunched")
assert(not helpers.ranCommand(mock, "start 'adb'"), "a target that was already down is not started")
assert(not helpers.ranCommand(mock, "'adb'"), "an already-down target is not even probed on disable")

assert(helpers.ranCommand(mock, "powerprofilesctl set 'balanced'"), "restored the previous power profile")
assert(powerProfile == "balanced", "power profile handed back")
assert(#mock.notifications == 1, "notified on disable")

-- Disabling with no session is a no-op.
mock.commands = {}
svc.disable()
assert(#mock.commands == 0, "disable without a session runs nothing")
assert(mock.published.game_mode.enabled == false, "still disabled")

-- ── command handler ──

-- Commands arrive as state writes. A nonce that has already been handled is ignored, so
-- a replayed or duplicated write cannot double-toggle.
noctalia.state.set("command", { nonce = 10, action = "enable" })
assert(mock.published.game_mode.enabled == true, "enable command honoured")
noctalia.state.set("command", { nonce = 10, action = "disable" })
assert(mock.published.game_mode.enabled == true, "stale nonce ignored")
noctalia.state.set("command", { nonce = 11, action = "disable" })
assert(mock.published.game_mode.enabled == false, "fresh nonce honoured")

noctalia.state.set("command", { nonce = 12, action = "toggle" })
assert(mock.published.game_mode.enabled == true, "toggle command honoured")
noctalia.state.set("command", { nonce = 13, action = "toggle" })
assert(mock.published.game_mode.enabled == false, "toggle command toggles back")

-- Unknown actions and malformed commands are logged, not fatal.
local logsBefore = #mock.logs
noctalia.state.set("command", { nonce = 14, action = "self-destruct" })
noctalia.state.set("command", "not a table")
noctalia.state.set("command", { nonce = 15 })
assert(#mock.logs > logsBefore, "unknown commands are logged")
assert(mock.published.game_mode.enabled == false, "unknown commands change nothing")

-- Power profile command: only profiles the system actually offers are accepted.
noctalia.state.set("command", { nonce = 16, action = "set-power-profile", profile = "power-saver" })
assert(powerProfile == "power-saver", "power profile set through a command")
assert(mock.published.power.active == "power-saver", "power state republished")
noctalia.state.set("command", { nonce = 17, action = "set-power-profile", profile = "turbo" })
assert(powerProfile == "power-saver", "an unsupported profile is refused")

-- ── enabling a chosen profile ──

-- The panel offers a profile per enable, because a plugin can read its own settings and
-- cannot write them. An enable command may therefore carry a profile that overrides the
-- configured one for that session.
helpers.resetDir(DATA_DIR)
mock.config.profile = "light"
mock.commands = {}
noctalia.state.set("command", { nonce = 18, action = "enable", profile = "heavy" })
assert(mock.published.game_mode.enabled == true, "enabled with an override")
assert(mock.published.game_mode.profile == "heavy", "override wins over the setting")
assert(svc.readSnapshot().profile == "heavy", "the session records the profile actually used")
-- sonarr is heavy-only in this suite's target list, so it proves the heavy set ran.
assert(helpers.ranCommand(mock, "sonarr.service"), "heavy-only target was probed")
noctalia.state.set("command", { nonce = 19, action = "disable" })

-- Without an override the configured profile applies.
mock.commands = {}
noctalia.state.set("command", { nonce = 20, action = "enable" })
assert(mock.published.game_mode.profile == "light", "no override falls back to the setting")
assert(not helpers.ranCommand(mock, "sonarr.service"), "heavy-only target skipped under light")
noctalia.state.set("command", { nonce = 21, action = "disable" })

-- A bogus override is refused rather than silently treated as one of the real profiles.
mock.commands = {}
local logsBeforeOverride = #mock.logs
noctalia.state.set("command", { nonce = 22, action = "enable", profile = "ludicrous" })
assert(mock.published.game_mode.enabled == true, "enable still completes")
assert(mock.published.game_mode.profile == "light", "bogus override falls back to the setting")
assert(#mock.logs > logsBeforeOverride, "the bogus override is logged")
noctalia.state.set("command", { nonce = 23, action = "disable" })

-- toggle carries an override too, so one panel button can enable a chosen profile.
mock.commands = {}
noctalia.state.set("command", { nonce = 24, action = "toggle", profile = "heavy" })
assert(mock.published.game_mode.profile == "heavy", "toggle honours the override")
noctalia.state.set("command", { nonce = 25, action = "toggle" })
assert(mock.published.game_mode.enabled == false, "toggle back off ignores the override")

-- ── failure handling ──

-- A stop that fails (no NOPASSWD rule for a system unit, say) is logged and the rest of
-- the flow still completes: the session is written so the user can still disable.
failures = { "sudo -n systemctl stop" }
mock.config.profile = "heavy"
live["sonarr.service"] = "active"
live["radarr.service"] = "inactive"
logsBefore = #mock.logs
noctalia.state.set("command", { nonce = 26, action = "enable" })
assert(mock.published.game_mode.enabled == true, "enable completes despite a failing stop")
assert(#mock.logs > logsBefore, "the failing stop is logged")
assert(helpers.ranCommand(mock, "sudo -n systemctl stop 'sonarr.service'"), "attempted the system unit stop")
assert(not helpers.ranCommand(mock, "sudo -n systemctl stop 'radarr.service'"), "inactive system unit not stopped")
noctalia.state.set("command", { nonce = 27, action = "disable" })
assert(mock.published.game_mode.enabled == false, "disabled again")
failures = {}
mock.config.profile = "light"

-- runAsync refusing to start (command capacity exhausted) must not wedge the flow.
mock.startFail = function(command)
    return command:find("pgrep", 1, true) ~= nil
end
noctalia.state.set("command", { nonce = 28, action = "enable" })
assert(mock.published.game_mode.enabled == true, "enable completes when a probe cannot start")
assert(mock.published.game_mode.busy == false, "flow is not left busy")
local unstarted = svc.readSnapshot()
local processWas
for _, entry in ipairs(unstarted.targets) do
    if entry.match == "gslapper" then
        processWas = entry.was
    end
end
assert(processWas == "down", "a probe that could not run records down, never a guess")
mock.startFail = nil
noctalia.state.set("command", { nonce = 29, action = "disable" })

-- ── metrics polling ──

mock.stats = {
    cpu = { usagePercent = 90 },
    ram = { usagePercent = 75, usedMb = 24576, totalMb = 32768 },
    gpu = {},
}
svc.pollMetrics()
assert(math.abs(mock.published.metrics.cpuPerc - 0.9) < 0.0001, "poll republishes metrics")
assert(mock.published.metrics.gpuAvailable == false, "gpu reported unavailable")

-- No system monitor at all: metrics are published as unavailable rather than as zeroes.
mock.stats = false
svc.pollMetrics()
assert(mock.published.metrics.available == false, "unavailable metrics flagged")
assert(mock.published.metrics.cpuPerc == nil, "no fabricated readings")

-- update() is the tick entry point the shell calls (there is no onTick).
mock.stats = { cpu = { usagePercent = 10 }, ram = {}, gpu = {} }
assert(type(update) == "function", "update global defined for the tick")
update()
assert(math.abs(mock.published.metrics.cpuPerc - 0.1) < 0.0001, "update() polls metrics")

-- ── no powerprofilesctl ──

-- A system without powerprofilesctl reports the power group unavailable and never
-- shells out to it, so gamer mode still works without power switching.
local bareMock = helpers.newNoctalia({
    dataDir = DATA_DIR,
    config = { profile = "light", auto_performance = true, targets = RUNTIME_TARGETS },
    respond = respond,
    missingCommands = { powerprofilesctl = true },
})
helpers.resetDir(DATA_DIR)
local bare = dofile("gamer-mode/service.luau")
assert(bareMock.published.power.available == false, "power unavailable")
assert(not helpers.ranCommand(bareMock, "powerprofilesctl"), "powerprofilesctl never invoked")
bare.enable()
assert(bareMock.published.game_mode.enabled == true, "enable works without powerprofilesctl")
assert(not helpers.ranCommand(bareMock, "powerprofilesctl"), "still never invoked")
bare.disable()
assert(bareMock.published.game_mode.enabled == false, "disable works without powerprofilesctl")

-- ── mixed stop + freeze flow ──

-- A frozen process still appears in pgrep, so the was-up-and-still-down probe cannot
-- decide whether to thaw it. Freeze targets are therefore thawed unconditionally, which
-- is safe because SIGCONT to a running process is a verified no-op.
local MIXED_DIR = "/tmp/gamermode-test-mixed"
local MIXED_TARGETS = '[{"match":"brave","kind":"process","action":"freeze","profiles":["light"]},'
    .. '{"match":"nzbget.service","kind":"system-service","action":"stop","profiles":["light"]},'
    .. '{"match":"idle-thing","kind":"process","action":"freeze","profiles":["light"]}]'

local mixedLive = { ["brave"] = "4242", ["nzbget.service"] = "active", ["idle-thing"] = "" }

local function mixedRespond(command)
    for match, output in pairs(mixedLive) do
        if command:find("'" .. match .. "'", 1, true) then
            if command:find("is-active", 1, true) or command:find("pgrep", 1, true) then
                return { stdout = output, exitCode = output == "" and 1 or 0 }
            end
        end
    end
    return { stdout = "" }
end

helpers.resetDir(MIXED_DIR)
local mixedMock = helpers.newNoctalia({
    dataDir = MIXED_DIR,
    config = { profile = "light", auto_performance = false, targets = MIXED_TARGETS },
    respond = mixedRespond,
})
local mixed = dofile("gamer-mode/service.luau")

mixed.enable()

-- The freeze target that was up is frozen, not killed.
assert(helpers.ranCommand(mixedMock, "pkill -STOP -x 'brave'"), "running freeze target is frozen")
assert(not helpers.ranCommand(mixedMock, "pkill -x 'brave'"), "freeze target is never killed")
-- The stop target that was up is stopped.
assert(helpers.ranCommand(mixedMock, "sudo -n systemctl stop 'nzbget.service'"), "stop target is stopped")
-- The freeze target that was already down is left alone.
assert(not helpers.ranCommand(mixedMock, "pkill -STOP -x 'idle-thing'"), "down target is not frozen")

-- The published state distinguishes the two, so the panel can label them.
local suspendedActions = {}
for _, entry in ipairs(mixedMock.published.game_mode.suspended) do
    suspendedActions[entry.match] = entry.action
end
assert(suspendedActions["brave"] == "freeze", "frozen target published with its action")
assert(suspendedActions["nzbget.service"] == "stop", "stopped target published with its action")
assert(suspendedActions["idle-thing"] == nil, "already-down target not listed")

-- The session records the action so a restore after a shell restart still knows which
-- half of the restore each target belongs to.
local mixedSnap = mixed.readSnapshot()
local recorded = {}
for _, entry in ipairs(mixedSnap.targets) do
    recorded[entry.match] = entry.action
end
assert(recorded["brave"] == "freeze" and recorded["nzbget.service"] == "stop", "actions persisted")

-- ── disable ──

mixedMock.commands = {}
-- brave is still frozen (pgrep still finds it); nzbget is still down.
mixedLive["nzbget.service"] = ""
mixed.disable()

-- Freeze targets are thawed with no probe at all.
assert(helpers.ranCommand(mixedMock, "pkill -CONT -x 'brave'"), "freeze target thawed")
assert(not helpers.ranCommand(mixedMock, "pgrep -x 'brave'"), "thaw needs no probe")
-- Stop targets keep the still-down probe before being started.
assert(helpers.ranCommand(mixedMock, "systemctl is-active 'nzbget.service'"), "stop target probed")
assert(helpers.ranCommand(mixedMock, "sudo -n systemctl start 'nzbget.service'"), "stop target started")
-- Nothing touches the target that was already down.
assert(not helpers.ranCommand(mixedMock, "'idle-thing'"), "already-down target untouched on restore")

assert(mixedMock.published.game_mode.enabled == false, "disabled after the mixed flow")

-- A stop target the user restarted by hand is not stomped, but a freeze target is thawed
-- regardless -- SIGCONT to a running process changes nothing.
helpers.resetDir(MIXED_DIR)
mixedLive["nzbget.service"] = "active"
mixedLive["brave"] = "4242"
mixed.enable()
mixedMock.commands = {}
mixedLive["nzbget.service"] = "active" -- the user restarted it during gamer mode
mixed.disable()
assert(not helpers.ranCommand(mixedMock, "sudo -n systemctl start 'nzbget.service'"), "manual restart kept")
assert(helpers.ranCommand(mixedMock, "pkill -CONT -x 'brave'"), "freeze target thawed anyway")

print("runtime: passed")
