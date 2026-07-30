-- Timer kinds and the stop/freeze action matrix.
package.path = "./tests/?.lua;" .. package.path
local helpers = require("helpers")

local mock = helpers.newNoctalia()
local svc = dofile("gamer-mode/service.luau")

-- ── timer kinds ──

-- Stopping a service does not stop its timer from re-firing it mid-game, so timers are
-- their own kind. Probing a timer needs no privilege.
assert(
    svc.probeCmd({ kind = "system-timer", match = "fstrim.timer" }) == "systemctl is-active 'fstrim.timer'",
    "probe system timer"
)
assert(
    svc.probeCmd({ kind = "user-timer", match = "backup.timer" })
        == "systemctl --user is-active 'backup.timer'",
    "probe user timer"
)
assert(
    svc.stopCmd({ kind = "system-timer", match = "fstrim.timer" })
        == "sudo -n systemctl stop 'fstrim.timer'",
    "stop system timer needs sudo -n"
)
assert(
    svc.startCmd({ kind = "system-timer", match = "fstrim.timer" })
        == "sudo -n systemctl start 'fstrim.timer'",
    "start system timer"
)
assert(
    svc.stopCmd({ kind = "user-timer", match = "backup.timer" })
        == "systemctl --user stop 'backup.timer'",
    "stop user timer needs no sudo"
)
assert(
    svc.startCmd({ kind = "user-timer", match = "backup.timer" })
        == "systemctl --user start 'backup.timer'",
    "start user timer"
)

-- Timers are restartable, so unlike processes they have a real start command.
assert(svc.startCmd({ kind = "system-timer", match = "a.timer" }) ~= nil, "timers restore")

-- The .timer suffix is mandatory: `systemctl is-active fstrim` silently resolves to
-- fstrim.service, which is the wrong unit.
local bare = svc.parseTargets('[{"match":"fstrim","kind":"system-timer","profiles":["light"]}]')
assert(#bare == #svc.DEFAULT_TARGETS, "a timer target without .timer is rejected")
local suffixed = svc.parseTargets('[{"match":"fstrim.timer","kind":"system-timer","profiles":["light"]}]')
assert(#suffixed == 1 and suffixed[1].match == "fstrim.timer", "a .timer target is accepted")
local wrongSuffix = svc.parseTargets('[{"match":"fstrim.service","kind":"user-timer","profiles":["light"]}]')
assert(#wrongSuffix == #svc.DEFAULT_TARGETS, "a .service name under a timer kind is rejected")

-- ── freeze / thaw ──

-- freeze is SIGSTOP and thaw is SIGCONT. Measured: pkill -STOP puts a process in state T,
-- pkill -CONT returns it to S, and SIGCONT to a process that is not stopped exits 0 as a
-- harmless no-op. That last property is why restore can thaw unconditionally.
assert(svc.freezeCmd({ kind = "process", match = "brave" }) == "pkill -STOP -x 'brave'", "freeze process")
assert(svc.thawCmd({ kind = "process", match = "brave" }) == "pkill -CONT -x 'brave'", "thaw process")

-- Freezing a unit must reach every process in its cgroup, not just the main one.
-- --kill-whom=all is explicit because systemctl kill --help does not state its default.
assert(
    svc.freezeCmd({ kind = "user-service", match = "a.service" })
        == "systemctl --user kill --kill-whom=all -s SIGSTOP 'a.service'",
    "freeze user service"
)
assert(
    svc.thawCmd({ kind = "user-service", match = "a.service" })
        == "systemctl --user kill --kill-whom=all -s SIGCONT 'a.service'",
    "thaw user service"
)
assert(
    svc.freezeCmd({ kind = "system-service", match = "a.service" })
        == "sudo -n systemctl kill --kill-whom=all -s SIGSTOP 'a.service'",
    "freeze system service"
)
assert(
    svc.thawCmd({ kind = "system-service", match = "a.service" })
        == "sudo -n systemctl kill --kill-whom=all -s SIGCONT 'a.service'",
    "thaw system service"
)

-- docker pause is the cgroup freezer: an exact match for freeze semantics.
assert(svc.freezeCmd({ kind = "container", match = "x" }) == "docker pause 'x'", "freeze container")
assert(svc.thawCmd({ kind = "container", match = "x" }) == "docker unpause 'x'", "thaw container")

-- Timers have no process to signal.
assert(svc.freezeCmd({ kind = "system-timer", match = "a.timer" }) == nil, "timers cannot be frozen")
assert(svc.thawCmd({ kind = "user-timer", match = "a.timer" }) == nil, "timers cannot be thawed")

-- The denylist and quoting guards apply to the new builders too.
assert(svc.freezeCmd({ kind = "process", match = "steam" }) == nil, "freeze refuses protected targets")
assert(svc.thawCmd({ kind = "process", match = "niri" }) == nil, "thaw refuses protected targets")
assert(svc.freezeCmd({ kind = "process", match = "a\nb" }) == nil, "freeze refuses control characters")
assert(svc.freezeCmd({ kind = "process", match = "a'b" }) == "pkill -STOP -x 'a'\\''b'", "freeze quotes")

-- ── the action field ──

assert(svc.actionOf({ kind = "process", match = "a" }) == "stop", "action defaults to stop")
assert(svc.actionOf({ kind = "process", match = "a", action = "stop" }) == "stop", "explicit stop")
assert(svc.actionOf({ kind = "process", match = "a", action = "freeze" }) == "freeze", "explicit freeze")

-- A valid action round-trips through parsing.
local frozen = svc.parseTargets('[{"match":"brave","kind":"process","action":"freeze","profiles":["heavy"]}]')
assert(#frozen == 1 and frozen[1].action == "freeze", "action survives parsing")
local defaulted = svc.parseTargets('[{"match":"brave","kind":"process","profiles":["heavy"]}]')
assert(#defaulted == 1 and svc.actionOf(defaulted[1]) == "stop", "absent action means stop")

-- An unknown action is a typo, not a silent fallback to stop.
local bogus = svc.parseTargets('[{"match":"brave","kind":"process","action":"nuke","profiles":["heavy"]}]')
assert(#bogus == #svc.DEFAULT_TARGETS, "unknown action rejected")

-- freeze on a timer kind is rejected at parse time, not just at command build time.
local frozenTimer = svc.parseTargets(
    '[{"match":"a.timer","kind":"system-timer","action":"freeze","profiles":["light"]}]'
)
assert(#frozenTimer == #svc.DEFAULT_TARGETS, "freeze rejected for timer kinds")

-- process + stop is permitted but warned: there is no argv to relaunch a bare process.
mock.logs = {}
local killed = svc.parseTargets('[{"match":"foo","kind":"process","action":"stop","profiles":["light"]}]')
assert(#killed == 1, "process + stop is still allowed")
local warned = false
for _, line in ipairs(mock.logs) do
    if line:find("unrecoverable", 1, true) then
        warned = true
    end
end
assert(warned, "process + stop logs an unrecoverability warning")

print("actions: passed")
