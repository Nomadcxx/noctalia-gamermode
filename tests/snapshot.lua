-- Snapshot engine: what gamer mode recorded on enable, and what it is allowed to
-- restart on disable. Persisted as JSON so it survives a shell restart.
package.path = "./tests/?.lua;" .. package.path
local helpers = require("helpers")

local DATA_DIR = "/tmp/gamermode-test-snapshot"
local SNAPSHOT = DATA_DIR .. "/session.json"

local mock = helpers.newNoctalia({ dataDir = DATA_DIR })
local svc = dofile("gamermode/service.luau")

helpers.resetDir(DATA_DIR)

local probed = {
    { match = "gslapper", kind = "process", was = "running" },
    { match = "spotifyd.service", kind = "user-service", was = "active" },
    { match = "gone.service", kind = "user-service", was = "down" },
}

-- Header carries what disable needs: which profile was applied and which power profile
-- to hand back.
local snap = svc.buildSnapshot("light", "balanced", probed)
assert(snap.version == 1, "snapshot version")
assert(snap.profile == "light" and snap.power_profile_before == "balanced", "snapshot header")
assert(#snap.targets == 3, "snapshot records every probed target, including the down ones")

-- Restore plan: only targets that were up when gamer mode started AND are still down
-- now. Never stomp something the user restarted by hand, never start something that
-- was already off.
local current = { ["gslapper"] = "down", ["spotifyd.service"] = "active", ["gone.service"] = "down" }
local plan = svc.restorePlan(snap, function(match)
    return current[match]
end)
assert(#plan == 1 and plan[1].match == "gslapper", "was-up and still-down only, got " .. #plan)

-- A snapshot where nothing was up restores nothing.
local nothingUp = svc.buildSnapshot("light", "balanced", {
    { match = "a", kind = "process", was = "down" },
})
assert(#svc.restorePlan(nothingUp, function() return "down" end) == 0, "nothing to restore")

-- Missing/unknown live state is treated as "not still down", i.e. left alone.
local unknown = svc.restorePlan(snap, function() return nil end)
assert(#unknown == 0, "unknown live state restores nothing")

-- Persistence round-trip.
assert(svc.writeSnapshot(snap), "writeSnapshot")
assert(mock.fileExists(SNAPSHOT), "snapshot file written to the plugin data dir")
local loaded = svc.readSnapshot()
assert(loaded, "readSnapshot")
assert(loaded.profile == "light" and loaded.power_profile_before == "balanced", "header round-trip")
assert(#loaded.targets == 3, "targets round-trip, got " .. #loaded.targets)
assert(loaded.targets[1].match == "gslapper" and loaded.targets[1].was == "running", "target order and fields")
assert(loaded.targets[2].kind == "user-service", "kind round-trip")

-- An empty target list round-trips as an empty list, not as nil.
assert(svc.writeSnapshot(svc.buildSnapshot("heavy", "performance", {})), "write empty snapshot")
local empty = svc.readSnapshot()
assert(empty and type(empty.targets) == "table" and #empty.targets == 0, "empty targets round-trip")

svc.deleteSnapshot()
assert(svc.readSnapshot() == nil, "deleted snapshot reads as nil")
assert(not mock.fileExists(SNAPSHOT), "snapshot file removed")
assert(svc.readSnapshot() == nil, "absent snapshot reads as nil without error")

-- Corruption and version drift are tolerated: a snapshot that cannot be trusted is
-- treated as "no session", which leaves gamer mode reporting disabled.
for _, corrupt in ipairs({
    "{{{",
    "",
    "null",
    "[]",
    '{"version":2,"profile":"light","targets":[]}',
    '{"profile":"light","targets":[]}',
    '{"version":1,"profile":"light"}',
    '{"version":1,"profile":"light","targets":"nope"}',
}) do
    assert(mock.writeFile(SNAPSHOT, corrupt), "fixture written")
    assert(svc.readSnapshot() == nil, "rejected as untrustworthy: " .. corrupt)
end

-- A single unusable entry does not cost the whole session: the readable targets are
-- kept so they can still be restored, and the loss is logged.
assert(mock.writeFile(
    SNAPSHOT,
    '{"version":1,"profile":"light","power_profile_before":"balanced","targets":['
        .. '{"match":"good","kind":"process","was":"running"},'
        .. '{"kind":"process","was":"running"},'
        .. '{"match":"bad-kind","kind":"nope","was":"running"}]}'
), "partial fixture written")
local partial = svc.readSnapshot()
assert(partial and #partial.targets == 1 and partial.targets[1].match == "good", "usable entries survive")

-- A session with a missing power profile still loads; disable simply skips the restore.
assert(mock.writeFile(SNAPSHOT, '{"version":1,"profile":"heavy","targets":[]}'), "no-power fixture")
local noPower = svc.readSnapshot()
assert(noPower and noPower.profile == "heavy" and noPower.power_profile_before == nil, "optional power profile")

svc.deleteSnapshot()

-- Deleting a snapshot that does not exist is not an error.
svc.deleteSnapshot()
svc.deleteSnapshot()

-- No plugin data dir at all (shell could not provide one): persistence degrades to
-- "no session" instead of erroring.
mock.pluginDataDir = function()
    return nil
end
assert(svc.writeSnapshot(snap) == false, "write without a data dir reports failure")
assert(svc.readSnapshot() == nil, "read without a data dir is nil")
svc.deleteSnapshot()

print("snapshot: passed")
