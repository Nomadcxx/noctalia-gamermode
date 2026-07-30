-- Shell command construction per target kind, and the mapping from command output back
-- to a recorded state.
package.path = "./tests/?.lua;" .. package.path
local helpers = require("helpers")

helpers.newNoctalia()
local svc = dofile("gamer-mode/service.luau")

-- Probes.
assert(svc.probeCmd({ kind = "process", match = "gslapper" }) == "pgrep -x 'gslapper'", "probe process")
assert(
    svc.probeCmd({ kind = "user-service", match = "a.service" }) == "systemctl --user is-active 'a.service'",
    "probe user service"
)
assert(
    svc.probeCmd({ kind = "system-service", match = "a.service" }) == "systemctl is-active 'a.service'",
    "probe system service"
)
assert(
    svc.probeCmd({ kind = "container", match = "x" }) == "docker inspect -f '{{.State.Running}}' 'x'",
    "probe container"
)

-- Probing a system service needs no sudo: is-active is readable unprivileged.
assert(not svc.probeCmd({ kind = "system-service", match = "a.service" }):find("sudo", 1, true), "probe needs no sudo")

-- Stops.
assert(svc.stopCmd({ kind = "process", match = "gslapper" }) == "pkill -x 'gslapper'", "stop process")
assert(
    svc.stopCmd({ kind = "user-service", match = "a.service" }) == "systemctl --user stop 'a.service'",
    "stop user service"
)
assert(
    svc.stopCmd({ kind = "system-service", match = "a.service" }) == "systemctl stop 'a.service'",
    "stop system service"
)
assert(svc.stopCmd({ kind = "container", match = "x" }) == "docker stop 'x'", "stop container")

-- Starts. Processes have no generic relaunch: gamer mode does not know the argv, the
-- environment or the working directory a bare process name was started with.
assert(
    svc.startCmd({ kind = "user-service", match = "a.service" }) == "systemctl --user start 'a.service'",
    "start user service"
)
assert(
    svc.startCmd({ kind = "system-service", match = "a.service" }) == "systemctl start 'a.service'",
    "start system service"
)
assert(svc.startCmd({ kind = "container", match = "x" }) == "docker start 'x'", "start container")
assert(svc.startCmd({ kind = "process", match = "gslapper" }) == nil, "processes have no generic start")

-- No builder shells out to sudo. systemctl reaches systemd over D-Bus and lets polkit ask
-- the desktop's authentication agent, which can actually prompt; `sudo -n` cannot, so it
-- failed outright on every machine without a NOPASSWD rule.
for _, build in ipairs({ svc.stopCmd, svc.startCmd, svc.freezeCmd, svc.thawCmd, svc.probeCmd }) do
    for _, kind in ipairs({ "system-service", "system-timer", "user-service", "process", "container" }) do
        local command = build({ kind = kind, match = "a" })
        assert(not (command and command:find("sudo", 1, true)), "no sudo in: " .. tostring(command))
    end
end

-- Batched system-unit commands elevate once through pkexec, because neither a process per
-- unit nor one process naming every unit avoids a prompt per unit.
local units = {
    { kind = "system-service", match = "a.service" },
    { kind = "system-timer", match = "b.timer" },
}
local batched = svc.batchCmd("stop", units)
assert(batched == "pkexec /usr/bin/systemctl stop 'a.service' 'b.timer'", "batched stop, got " .. tostring(batched))
assert(svc.batchCmd("start", units) == "pkexec /usr/bin/systemctl start 'a.service' 'b.timer'", "batched start")

-- Timers have no process to signal, so they are left out of a freeze rather than making
-- systemctl fail the whole batch.
local frozen, covered = svc.batchCmd("freeze", units)
assert(frozen == "pkexec /usr/bin/systemctl kill --kill-whom=all -s SIGSTOP 'a.service'", "freeze skips timers, got " .. tostring(frozen))
assert(#covered == 1 and covered[1].match == "a.service", "covered reports what actually went in")

-- User units and processes never enter a batch: they need no authorisation, and batching
-- them would only blur which one failed.
assert(svc.batchCmd("stop", { { kind = "user-service", match = "u.service" } }) == nil, "user units are not batched")
assert(svc.batchCmd("stop", { { kind = "process", match = "p" } }) == nil, "processes are not batched")
assert(svc.batchCmd("bogus", units) == nil, "unknown verb builds nothing")

-- Without pkexec the plugin still works, at the cost of the prompt-per-unit behaviour.
svc.canElevate = false
assert(svc.batchCmd("stop", units) == "systemctl stop 'a.service' 'b.timer'", "falls back to plain systemctl")
svc.canElevate = true

-- Which kinds need authorisation, and so must be serialised behind one password prompt.
assert(svc.needsPrivilege("system-service"), "system services need privilege")
assert(svc.needsPrivilege("system-timer"), "system timers need privilege")
assert(not svc.needsPrivilege("user-service"), "user units are the caller's own")
assert(not svc.needsPrivilege("user-timer"), "user timers are the caller's own")
assert(not svc.needsPrivilege("process"), "signalling your own process needs nothing")
assert(not svc.needsPrivilege("container"), "docker group membership covers containers")

-- Unknown kinds build nothing.
assert(svc.probeCmd({ kind = "bogus", match = "x" }) == nil, "unknown kind probes nothing")
assert(svc.stopCmd({ kind = "bogus", match = "x" }) == nil, "unknown kind stops nothing")
assert(svc.startCmd({ kind = "bogus", match = "x" }) == nil, "unknown kind starts nothing")

-- Quoting: an apostrophe is closed, escaped and reopened.
assert(svc.probeCmd({ kind = "process", match = "a'b" }) == "pgrep -x 'a'\\''b'", "apostrophe quoted")
assert(svc.stopCmd({ kind = "container", match = "a'b" }) == "docker stop 'a'\\''b'", "apostrophe quoted in stop")
assert(svc.probeCmd({ kind = "process", match = "a; rm -rf /" }) == "pgrep -x 'a; rm -rf /'", "metacharacters inert")

-- Control characters cannot be quoted safely, so nothing is built at all.
assert(svc.probeCmd({ kind = "process", match = "a\nb" }) == nil, "newline refused")
assert(svc.stopCmd({ kind = "process", match = "a\nb" }) == nil, "newline refused in stop")
assert(svc.startCmd({ kind = "container", match = "a\rb" }) == nil, "carriage return refused")
assert(svc.probeCmd({ kind = "process", match = "" }) == nil, "empty match refused")

-- Probe output to recorded state.
assert(svc.wasState("process", "123\n124\n") == "running", "pids mean running")
assert(svc.wasState("process", "") == "down", "no pids mean down")
assert(svc.wasState("process", "\n  \n") == "down", "whitespace-only output means down")
assert(svc.wasState("process", nil) == "down", "absent output means down")

assert(svc.wasState("user-service", "active") == "active", "active")
assert(svc.wasState("user-service", "active\n") == "active", "trailing newline trimmed")
assert(svc.wasState("user-service", "inactive") == "down", "inactive means down")
assert(svc.wasState("user-service", "failed") == "down", "failed means down")
assert(svc.wasState("system-service", "active") == "active", "system service active")

-- `systemctl is-active` reports "activating"/"deactivating" mid-transition. Those are
-- not recorded as up: restoring something that was only half-started is worse than
-- leaving it, and the stop below will settle it either way.
assert(svc.wasState("user-service", "activating") == "down", "activating is not recorded as up")

assert(svc.wasState("container", "true") == "running", "docker true")
assert(svc.wasState("container", "false") == "down", "docker false")
assert(svc.wasState("container", "") == "down", "missing container means down")

print("commands: passed")
