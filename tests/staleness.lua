-- A session file outlives a reboot. Enabled units come back on their own, so without a
-- staleness check the panel reports gamer mode ON forever over a suspend list of
-- processes that are all running again.
package.path = "./tests/?.lua;" .. package.path
local helpers = require("helpers")

local DIR = "/tmp/gamermode-test-stale"

local TARGETS = '[{"match":"nzbget.service","kind":"system-service","action":"stop","profiles":["light"]},'
    .. '{"match":"brave","kind":"process","action":"freeze","profiles":["light"]}]'

local function newService(opts)
    helpers.resetDir(DIR)
    local mock = helpers.newNoctalia({
        dataDir = DIR,
        bootId = opts.bootId,
        config = { profile = "light", auto_performance = false, targets = TARGETS },
        respond = opts.respond or function()
            return { stdout = "" }
        end,
    })
    return mock, dofile("gamer-mode/service.luau")
end

-- Everything is up, so enable has something to suspend.
local function allUp(command)
    if command:find("pgrep", 1, true) then
        return { stdout = "1234" }
    elseif command:find("is-active", 1, true) then
        return { stdout = "active" }
    end
    return { stdout = "" }
end

-- ── the boot id is recorded ──

local mock, svc = newService({ bootId = "boot-one" })
assert(svc.currentBootId() == "boot-one", "boot id read and trimmed, got " .. tostring(svc.currentBootId()))

local snap = svc.buildSnapshot("light", "balanced", {})
assert(snap.boot_id == "boot-one", "buildSnapshot records the boot id")
assert(svc.writeSnapshot(snap), "written")
assert(svc.readSnapshot().boot_id == "boot-one", "boot id round-trips")

-- ── same boot: the session is kept ──

-- Within one boot a session that looks stale is deliberately kept: that is exactly the
-- case where something may still be frozen and needs thawing.
local sameMock, same = newService({ bootId = "boot-one", respond = allUp })
same.enable()
assert(sameMock.published.game_mode.enabled == true, "enabled")
sameMock.commands = {}

-- Reloading the service on the same boot must not clear the session.
local sameAgain = dofile("gamer-mode/service.luau")
assert(sameMock.published.game_mode.enabled == true, "session survives a reload on the same boot")
assert(not helpers.ranCommand(sameMock, "systemctl start"), "no restore on the same boot")
assert(not helpers.ranCommand(sameMock, "pkill -CONT"), "no thaw on the same boot")
assert(sameAgain.readSnapshot() ~= nil, "session file still present")

-- ── different boot: restore, then clear ──

local rebootMock, reboot = newService({ bootId = "boot-one", respond = allUp })
reboot.enable()
assert(rebootMock.published.game_mode.enabled == true, "enabled before the reboot")
assert(reboot.readSnapshot().boot_id == "boot-one", "session carries the pre-reboot boot id")

-- Simulate the reboot: a new boot id, and the stopped unit is still down.
rebootMock.bootId = "boot-two"
rebootMock.commands = {}
rebootMock.logs = {}
rebootMock.respond = function(command)
    if command:find("is-active", 1, true) then
        return { stdout = "inactive", exitCode = 3 }
    end
    return { stdout = "" }
end

local afterReboot = dofile("gamer-mode/service.luau")

assert(rebootMock.published.game_mode.enabled == false, "reports disabled after a reboot")
assert(afterReboot.readSnapshot() == nil, "stale session cleared")
-- A stopped unit that is not `enabled` really is still down, and the promise was to put it
-- back.
assert(helpers.ranCommand(rebootMock, "sudo -n systemctl start 'nzbget.service'"), "stop target restored")
-- The frozen process died with the reboot, so its thaw is a harmless no-op.
assert(helpers.ranCommand(rebootMock, "pkill -CONT -x 'brave'"), "freeze target thawed harmlessly")
local logged = false
for _, line in ipairs(rebootMock.logs) do
    if line:find("boot", 1, true) then
        logged = true
    end
end
assert(logged, "the stale session is logged")

-- ── a v1 session without a boot id is treated as current ──

-- Inventing staleness would abandon targets that may still be suspended.
local legacyMock = helpers.newNoctalia({
    dataDir = DIR,
    bootId = "boot-one",
    config = { profile = "light", auto_performance = false, targets = TARGETS },
    respond = allUp,
})
helpers.resetDir(DIR)
assert(legacyMock.writeFile(
    DIR .. "/session.json",
    '{"version":1,"profile":"light","power_profile_before":"balanced","targets":'
        .. '[{"match":"nzbget.service","kind":"system-service","action":"stop","was":"active"}]}'
), "legacy fixture written")
legacyMock.commands = {}
local legacyReload = dofile("gamer-mode/service.luau")
assert(legacyMock.published.game_mode.enabled == true, "a session with no boot id is kept")
assert(legacyReload.readSnapshot() ~= nil, "legacy session not cleared")
assert(not helpers.ranCommand(legacyMock, "systemctl start"), "no restore for a legacy session")

-- ── an unreadable boot id degrades to "current" ──

local blindMock = helpers.newNoctalia({
    dataDir = DIR,
    bootId = false,
    config = { profile = "light", auto_performance = false, targets = TARGETS },
    respond = allUp,
})
helpers.resetDir(DIR)
assert(blindMock.currentBootIdUnreadable == nil, "sanity")
assert(blindMock.writeFile(
    DIR .. "/session.json",
    '{"version":1,"profile":"light","boot_id":"boot-one","targets":'
        .. '[{"match":"nzbget.service","kind":"system-service","action":"stop","was":"active"}]}'
), "fixture written")
blindMock.commands = {}
local blind = dofile("gamer-mode/service.luau")
assert(blind.currentBootId() == nil, "an unreadable boot id reads as nil")
assert(blindMock.published.game_mode.enabled == true, "unreadable boot id keeps the session")
assert(blind.readSnapshot() ~= nil, "session kept when staleness cannot be determined")

print("staleness: passed")
