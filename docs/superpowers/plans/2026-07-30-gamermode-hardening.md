# GamerMode Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the suspend engine safe for arbitrary user setups: a non-overridable denylist, a reversible `freeze` action, systemd timer kinds, a generic default target list, and boot-ID staleness detection.

**Architecture:** All engine changes land in the single `gamermode/service.luau`. A target gains an `action` field (`stop` | `freeze`); restore splits into two passes — `stop` targets keep the was-up-and-still-down probe, `freeze` targets are thawed unconditionally because `SIGCONT` to a running process is a verified no-op. Two new kinds (`user-timer`, `system-timer`) close the scheduled-work gap.

**Tech Stack:** Noctalia V5 luau plugin API (`plugin_api = 19`), plain `lua` 5.5 for tests via the `tests/helpers.lua` mock.

**Spec:** `docs/superpowers/specs/2026-07-30-gamermode-hardening-design.md`

## Global Constraints

- **`service.luau` must stay one file.** The Luau sandbox provides no `require`, `load` or `dofile`. Do not attempt to split it into modules.
- **No `io`, no `os.execute`/`os.remove`/`os.rename`, no `load`.** All filesystem access goes through `noctalia.readFile` / `writeFile` / `renameFile` / `removeFile` / `mkdirAll`. `tests/sandbox.sh` enforces this and must stay green.
- **`runAsync(command, callback, timeoutMs)`**, callback receives one `result` table (`exitCode`, `stdout`, `stderr`, `timedOut`); the call returns a started boolean. Use the existing `run()` wrapper, which normalises both into "callback fires exactly once, nil means unknown".
- **`action` defaults to `stop`.** All nine existing suites must stay green unchanged.
- **Panel handler props are global function *names*** (strings), never closures.
- Run the whole suite with `./run-tests.sh`.
- Commit messages must not mention AI or agent attribution (a pre-commit hook rejects it).

---

### Task 1: Never-touch denylist

**Files:**
- Modify: `gamermode/service.luau`
- Test: `tests/denylist.lua`

**Interfaces:**
- Consumes: `validateShellValue`, `shellQuote`, `VALID_KINDS`, `parseTargets`, `probeCmd`, `stopCmd`, `startCmd` (all existing).
- Produces: `M.isDenied(match) -> boolean`. A `safeMatch(target)` local used by every command builder in place of `shellQuote(target.match)`. `validEntry(entry) -> ok, reason` (was `-> ok`).

- [ ] **Step 1: Write the failing test `tests/denylist.lua`**

```lua
-- The never-touch denylist: entries that would kill the session, the audio stack, the
-- network or the game itself must be impossible to act on.
package.path = "./tests/?.lua;" .. package.path
local helpers = require("helpers")

local mock = helpers.newNoctalia()
local svc = dofile("gamermode/service.luau")

-- Every protected name is recognised.
local PROTECTED = {
    "niri", "hyprland", "sway", "river", "wayfire", "labwc", "gnome-shell",
    "kwin_wayland", "plasmashell", "xorg", "xwayland", "greetd", "sddm", "gdm",
    "noctalia", "quickshell",
    "pipewire", "pipewire-pulse", "wireplumber", "pulseaudio",
    "systemd", "systemd-logind", "dbus-broker", "dbus-daemon", "elogind",
    "networkmanager", "wpa_supplicant", "iwd", "systemd-networkd",
    "steam", "steamwebhelper", "gamescope", "wine", "wineserver", "proton",
    "lutris", "heroic", "bottles", "gamemoded",
}
for _, name in ipairs(PROTECTED) do
    assert(svc.isDenied(name), "must be denied: " .. name)
end

-- Normalisation: case and unit suffixes must not be an escape route.
assert(svc.isDenied("Steam"), "case-insensitive")
assert(svc.isDenied("STEAM"), "upper case")
assert(svc.isDenied("steam.service"), ".service suffix stripped")
assert(svc.isDenied("NetworkManager.service"), "case + suffix")
assert(svc.isDenied("pipewire.socket"), ".socket suffix stripped")
assert(svc.isDenied("systemd-tmpfiles-clean.timer") == false, "unrelated timer is allowed")

-- Ordinary targets are not denied.
for _, name in ipairs({ "brave", "ollama.service", "fstrim.timer", "qbittorrent", "" }) do
    assert(not svc.isDenied(name), "must not be denied: " .. tostring(name))
end
assert(not svc.isDenied(nil), "nil is not denied")
assert(not svc.isDenied(42), "non-string is not denied")

-- Parse time: a denied entry is dropped and logged, the rest of the list survives.
mock.logs = {}
local parsed = svc.parseTargets(
    '[{"match":"niri","kind":"process","profiles":["light"]},'
        .. '{"match":"qbittorrent","kind":"process","profiles":["light"]}]'
)
assert(#parsed == 1 and parsed[1].match == "qbittorrent", "denied entry dropped, rest kept")
local logged = false
for _, line in ipairs(mock.logs) do
    if line:find("niri", 1, true) or line:find("protected", 1, true) then logged = true end
end
assert(logged, "the drop is logged")

-- A list of nothing but denied entries falls back to defaults rather than acting.
local allDenied = svc.parseTargets('[{"match":"pipewire","kind":"process","profiles":["light"]}]')
assert(#allDenied == #svc.DEFAULT_TARGETS, "all-denied list falls back to defaults")

-- Action time: every command builder refuses, even if a denied entry reaches it from a
-- session file written before the denylist existed.
for _, kind in ipairs({ "process", "user-service", "system-service", "container" }) do
    local target = { match = "steam", kind = kind }
    assert(svc.probeCmd(target) == nil, "probe refuses steam as " .. kind)
    assert(svc.stopCmd(target) == nil, "stop refuses steam as " .. kind)
    assert(svc.startCmd(target) == nil, "start refuses steam as " .. kind)
end
assert(svc.probeCmd({ match = "niri", kind = "process" }) == nil, "probe refuses the compositor")
assert(svc.stopCmd({ match = "PipeWire.service", kind = "user-service" }) == nil, "stop refuses audio")

print("denylist: passed")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua tests/denylist.lua`
Expected: FAIL — `attempt to call a nil value (field 'isDenied')`

- [ ] **Step 3: Add the denylist to `gamermode/service.luau`**

Insert immediately after the `VALID_KINDS` table:

```lua
-- Targets that must never be stopped or frozen. Acting on any of these ends the session,
-- kills audio or network, or kills the game gamer mode exists to serve. Deliberately not
-- overridable: the cost of a wrong entry is a dead session, and an override flag is
-- exactly the field a user copies from a forum post without reading.
local DENIED = {}
for _, name in ipairs({
    -- session and display
    "niri", "hyprland", "sway", "river", "wayfire", "labwc", "gnome-shell",
    "kwin_wayland", "plasmashell", "xorg", "xwayland", "greetd", "sddm", "gdm",
    -- the shell hosting this plugin
    "noctalia", "quickshell",
    -- audio
    "pipewire", "pipewire-pulse", "wireplumber", "pulseaudio",
    -- core IPC and session management
    "systemd", "systemd-logind", "dbus-broker", "dbus-daemon", "elogind",
    -- network
    "networkmanager", "wpa_supplicant", "iwd", "systemd-networkd",
    -- the game stack itself
    "steam", "steamwebhelper", "gamescope", "wine", "wineserver", "proton",
    "lutris", "heroic", "bottles", "gamemoded",
}) do
    DENIED[name] = true
end

local UNIT_SUFFIXES = { ".service", ".timer", ".socket" }

-- baseName lowercases and strips a unit suffix so "Steam", "steam" and "steam.service"
-- all collapse onto the same denylist key.
local function baseName(match)
    local name = tostring(match):lower()
    for _, suffix in ipairs(UNIT_SUFFIXES) do
        if #name > #suffix and name:sub(-#suffix) == suffix then
            return name:sub(1, #name - #suffix)
        end
    end
    return name
end

function M.isDenied(match)
    if type(match) ~= "string" or match == "" then
        return false
    end
    return DENIED[baseName(match)] == true
end
```

- [ ] **Step 4: Make `validEntry` report a reason and reject denied entries**

Replace the existing `validEntry` with:

```lua
local function validEntry(entry)
    if type(entry) ~= "table" then
        return false, "not an object"
    end
    if not VALID_KINDS[entry.kind] then
        return false, "unknown kind " .. tostring(entry.kind)
    end
    if not validateShellValue(entry.match) then
        return false, "match is empty or contains a control character"
    end
    if M.isDenied(entry.match) then
        return false, "'" .. entry.match .. "' is protected and can never be suspended"
    end
    if type(entry.profiles) ~= "table" or #entry.profiles == 0 then
        return false, "profiles must be a non-empty array"
    end
    for _, profile in ipairs(entry.profiles) do
        if type(profile) ~= "string" or profile == "" then
            return false, "profile names must be non-empty strings"
        end
    end
    return true
end
```

- [ ] **Step 5: Log the reason in `parseTargets`**

In `parseTargets`, replace the `for _, entry in ipairs(decoded) do ... end` loop body with:

```lua
            for _, entry in ipairs(decoded) do
                local ok, reason = validEntry(entry)
                if ok then
                    out[#out + 1] = { match = entry.match, kind = entry.kind, profiles = entry.profiles }
                else
                    rejected = rejected + 1
                    noctalia.log("gamermode: dropped target: " .. tostring(reason))
                end
            end
```

and delete the now-redundant `if rejected > 0 then noctalia.log(...) end` block that reported only a count.

- [ ] **Step 6: Route every command builder through a denylist guard**

Add above `M.probeCmd`:

```lua
-- safeMatch is the single choke point for shell interpolation: it refuses protected
-- targets and anything that cannot be quoted. Builders return nil rather than emitting a
-- command, so a denied entry surviving in an old session file still cannot act.
local function safeMatch(target)
    if M.isDenied(target.match) then
        noctalia.log("gamermode: refusing to act on protected target " .. tostring(target.match))
        return nil
    end
    return shellQuote(target.match)
end
```

Then in `M.probeCmd`, `M.stopCmd` and `M.startCmd`, replace the first line
`local match = shellQuote(target.match)` with `local match = safeMatch(target)`.

- [ ] **Step 7: Run the test to verify it passes**

Run: `lua tests/denylist.lua`
Expected: `denylist: passed`

- [ ] **Step 8: Verify no regressions**

Run: `./run-tests.sh`
Expected: all pass, including the nine existing suites.

- [ ] **Step 9: Commit**

```bash
git add gamermode/service.luau tests/denylist.lua
git commit -m "feat: never-touch denylist for session-critical targets

Refuses to suspend the compositor, the shell, audio, core IPC, network and the
game stack. Checked at parse time so a bad targets setting is caught, and again
in every command builder so a denied entry surviving in an old session file
still cannot act. Matching lowercases and strips unit suffixes, so Steam,
steam and steam.service all deny.

Not overridable: the cost of a wrong entry is a dead session."
```

---

### Task 2: systemd timer kinds

**Files:**
- Modify: `gamermode/service.luau`
- Test: `tests/actions.lua`

**Interfaces:**
- Consumes: `VALID_KINDS`, `validEntry`, `safeMatch`, `probeCmd`, `stopCmd`, `startCmd`.
- Produces: kinds `user-timer` and `system-timer` accepted by `parseTargets`; `TIMER_KINDS` local; a `.timer`-suffix validation rule.

- [ ] **Step 1: Write the failing test `tests/actions.lua`**

```lua
-- Timer kinds and the stop/freeze action matrix.
package.path = "./tests/?.lua;" .. package.path
local helpers = require("helpers")

local mock = helpers.newNoctalia()
local svc = dofile("gamermode/service.luau")

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

print("actions: timer kinds passed")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua tests/actions.lua`
Expected: FAIL — `probe system timer` (probeCmd returns nil for an unknown kind)

- [ ] **Step 3: Register the timer kinds**

Replace the `VALID_KINDS` table with:

```lua
local VALID_KINDS = {
    process = true,
    ["user-service"] = true,
    ["system-service"] = true,
    ["user-timer"] = true,
    ["system-timer"] = true,
    container = true,
}

-- Timer kinds share systemctl with the service kinds but must name a *.timer unit, and
-- cannot be frozen -- a timer has no process to signal.
local TIMER_KINDS = { ["user-timer"] = true, ["system-timer"] = true }
```

- [ ] **Step 4: Add the suffix rule to `validEntry`**

Insert after the `M.isDenied` check inside `validEntry`:

```lua
    if TIMER_KINDS[entry.kind] and baseName(entry.match) == entry.match:lower() then
        return false, "timer target '" .. entry.match .. "' must name a .timer unit"
    end
```

Note: `baseName` strips a recognised unit suffix, so it returns the input unchanged
exactly when there was no suffix to strip. A `.service` name under a timer kind is caught
by the same check because `baseName` would strip `.service`, making the comparison fail —
so add the explicit suffix test too:

```lua
    if TIMER_KINDS[entry.kind] and entry.match:lower():sub(-6) ~= ".timer" then
        return false, "timer target '" .. entry.match .. "' must name a .timer unit"
    end
```

Use only this second form; delete the first. It is the one that rejects both a bare name
and a `.service` name.

- [ ] **Step 5: Teach the three command builders about timers**

In `M.probeCmd`, replace the service branches so the timer kinds share them:

```lua
    if target.kind == "process" then
        return "pgrep -x " .. match
    elseif target.kind == "user-service" or target.kind == "user-timer" then
        return "systemctl --user is-active " .. match
    elseif target.kind == "system-service" or target.kind == "system-timer" then
        return "systemctl is-active " .. match
    elseif target.kind == "container" then
        return "docker inspect -f '{{.State.Running}}' " .. match
    end
    return nil
```

In `M.stopCmd`:

```lua
    if target.kind == "process" then
        return "pkill -x " .. match
    elseif target.kind == "user-service" or target.kind == "user-timer" then
        return "systemctl --user stop " .. match
    elseif target.kind == "system-service" or target.kind == "system-timer" then
        return "sudo -n systemctl stop " .. match
    elseif target.kind == "container" then
        return "docker stop " .. match
    end
    return nil
```

In `M.startCmd`:

```lua
    if target.kind == "user-service" or target.kind == "user-timer" then
        return "systemctl --user start " .. match
    elseif target.kind == "system-service" or target.kind == "system-timer" then
        return "sudo -n systemctl start " .. match
    elseif target.kind == "container" then
        return "docker start " .. match
    end
    return nil
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `lua tests/actions.lua`
Expected: `actions: timer kinds passed`

- [ ] **Step 7: Verify no regressions**

Run: `./run-tests.sh`
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add gamermode/service.luau tests/actions.lua
git commit -m "feat: user-timer and system-timer target kinds

Stopping foo.service does not stop foo.timer from re-firing it minutes later,
so scheduled work needs its own kind. fstrim, smartd, paccache and the
package-cache timers are all enabled by default on Arch and are all mid-game
I/O stalls.

The .timer suffix is mandatory, because systemctl is-active fstrim silently
resolves to fstrim.service -- the wrong unit."
```

---

### Task 3: `freeze` action

**Files:**
- Modify: `gamermode/service.luau`
- Test: `tests/actions.lua` (extend)

**Interfaces:**
- Consumes: `safeMatch`, `TIMER_KINDS`, `validEntry`, `copyTargets`.
- Produces: `M.freezeCmd(target) -> string|nil`, `M.thawCmd(target) -> string|nil`, `M.actionOf(target) -> "stop"|"freeze"`. `copyTargets` carries `action`.

- [ ] **Step 1: Extend `tests/actions.lua`**

Replace the final `print("actions: timer kinds passed")` line with:

```lua
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
    if line:find("unrecoverable", 1, true) or line:find("cannot be restarted", 1, true) then
        warned = true
    end
end
assert(warned, "process + stop logs an unrecoverability warning")

print("actions: passed")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua tests/actions.lua`
Expected: FAIL — `attempt to call a nil value (field 'freezeCmd')`

- [ ] **Step 3: Add `actionOf`, `freezeCmd` and `thawCmd`**

Insert after `M.startCmd`:

```lua
local VALID_ACTIONS = { stop = true, freeze = true }

-- actionOf normalises the optional `action` field. Absent means "stop", which keeps every
-- pre-existing config and session file meaning exactly what it did before.
function M.actionOf(target)
    return target.action == "freeze" and "freeze" or "stop"
end

-- freeze suspends a target in place: SIGSTOP for processes and units, docker pause for
-- containers. Unlike stop it is perfectly reversible and loses no state, which makes it
-- the right action for anything the user might return to -- a browser, an editor, an
-- animated wallpaper daemon.
function M.freezeCmd(target)
    local match = safeMatch(target)
    if not match then
        return nil
    end
    if target.kind == "process" then
        return "pkill -STOP -x " .. match
    elseif target.kind == "user-service" then
        return "systemctl --user kill --kill-whom=all -s SIGSTOP " .. match
    elseif target.kind == "system-service" then
        return "sudo -n systemctl kill --kill-whom=all -s SIGSTOP " .. match
    elseif target.kind == "container" then
        return "docker pause " .. match
    end
    -- Timer kinds fall through: there is no process to signal.
    return nil
end

function M.thawCmd(target)
    local match = safeMatch(target)
    if not match then
        return nil
    end
    if target.kind == "process" then
        return "pkill -CONT -x " .. match
    elseif target.kind == "user-service" then
        return "systemctl --user kill --kill-whom=all -s SIGCONT " .. match
    elseif target.kind == "system-service" then
        return "sudo -n systemctl kill --kill-whom=all -s SIGCONT " .. match
    elseif target.kind == "container" then
        return "docker unpause " .. match
    end
    return nil
end
```

- [ ] **Step 4: Validate the action field**

Insert into `validEntry`, after the timer-suffix check:

```lua
    if entry.action ~= nil and not VALID_ACTIONS[entry.action] then
        return false, "unknown action " .. tostring(entry.action)
    end
    if entry.action == "freeze" and TIMER_KINDS[entry.kind] then
        return false, "a timer cannot be frozen, only stopped"
    end
```

`VALID_ACTIONS` is declared in Step 3, which is textually below `validEntry`. Move the
`local VALID_ACTIONS = { stop = true, freeze = true }` line up so it sits immediately
above the `DENIED` table, and delete it from the Step 3 insertion.

- [ ] **Step 5: Warn on the unrecoverable combination**

At the end of `parseTargets`, immediately before `return copyTargets(out)`, add:

```lua
            for _, entry in ipairs(out) do
                if entry.kind == "process" and M.actionOf(entry) == "stop" then
                    noctalia.log(
                        "gamermode: '" .. entry.match .. "' is a process with action=stop, which is "
                            .. "unrecoverable -- a bare process has no argv to relaunch from. "
                            .. "Use action=freeze, or target the unit that supervises it."
                    )
                end
            end
```

- [ ] **Step 6: Carry `action` through `copyTargets`**

In `copyTargets`, change the entry construction to:

```lua
        out[index] = {
            match = entry.match,
            kind = entry.kind,
            action = entry.action,
            profiles = profiles,
        }
```

and in `parseTargets`, change the accepted-entry construction to:

```lua
                    out[#out + 1] = {
                        match = entry.match,
                        kind = entry.kind,
                        action = entry.action,
                        profiles = entry.profiles,
                    }
```

- [ ] **Step 7: Run the test to verify it passes**

Run: `lua tests/actions.lua`
Expected: `actions: passed`

- [ ] **Step 8: Verify no regressions**

Run: `./run-tests.sh`
Expected: all pass.

- [ ] **Step 9: Commit**

```bash
git add gamermode/service.luau tests/actions.lua
git commit -m "feat: freeze action as a reversible alternative to stop

freeze is SIGSTOP for processes and units and docker pause for containers.
Unlike stop it loses no state, which makes it the right action for anything the
user returns to -- a browser, an editor, a wallpaper daemon.

renice was measured and rejected: with RLIMIT_NICE=0 an unprivileged process
can lower priority but never raise it back, so it would permanently degrade
anything it touched.

--kill-whom=all is explicit because systemctl kill --help does not state its
default, and freezing a unit must reach every process in its cgroup.

process + action=stop is now warned as unrecoverable."
```

---

### Task 4: Split restore — freeze thawed unconditionally

**Files:**
- Modify: `gamermode/service.luau`
- Test: `tests/runtime.lua` (extend)

**Interfaces:**
- Consumes: `M.restorePlan`, `M.buildSnapshot`, `M.readSnapshot`, `validSnapshotTarget`, `enable`, `disable`, `stopAll`.
- Produces: `M.restorePlan(snap, stateOf)` now returns only `stop`-action targets. New `M.thawPlan(snap) -> targets`. Snapshot target entries carry `action`. `game_mode.suspended` entries carry `action`.

- [ ] **Step 1: Extend `tests/runtime.lua`**

Append before the final `print("runtime: passed")`:

```lua
-- ── mixed stop + freeze flow ──

-- A frozen process still appears in pgrep, so the was-up-and-still-down probe cannot
-- decide whether to thaw it. Freeze targets are therefore thawed unconditionally, which
-- is safe because SIGCONT to a running process is a verified no-op.
local MIXED_DIR = "/tmp/gamermode-test-mixed"
helpers.resetDir(MIXED_DIR)

local mixedLive = { ["brave"] = "4242", ["nzbget.service"] = "active", ["idle-thing"] = "" }
local mixedMock = helpers.newNoctalia({
    dataDir = MIXED_DIR,
    config = {
        profile = "light",
        auto_performance = false,
        targets = '[{"match":"brave","kind":"process","action":"freeze","profiles":["light"]},'
            .. '{"match":"nzbget.service","kind":"system-service","action":"stop","profiles":["light"]},'
            .. '{"match":"idle-thing","kind":"process","action":"freeze","profiles":["light"]}]',
    },
    respond = function(command)
        for match, output in pairs(mixedLive) do
            if command:find("'" .. match .. "'", 1, true) then
                if command:find("is-active", 1, true) or command:find("pgrep", 1, true) then
                    return { stdout = output, exitCode = output == "" and 1 or 0 }
                end
            end
        end
        return { stdout = "" }
    end,
})
local mixed = dofile("gamermode/service.luau")

mixed.enable()

-- The freeze target that was up is frozen, not killed.
assert(helpers.ranCommand(mixedMock, "pkill -STOP -x 'brave'"), "running freeze target is frozen")
assert(not helpers.ranCommand(mixedMock, "pkill -x 'brave'"), "freeze target is never killed")
-- The stop target that was up is stopped.
assert(helpers.ranCommand(mixedMock, "sudo -n systemctl stop 'nzbget.service'"), "stop target is stopped")
-- The freeze target that was already down is left alone.
assert(not helpers.ranCommand(mixedMock, "pkill -STOP -x 'idle-thing'"), "down target is not frozen")

-- The published state distinguishes the two, so the panel can label them.
local suspended = {}
for _, entry in ipairs(mixedMock.published.game_mode.suspended) do
    suspended[entry.match] = entry.action
end
assert(suspended["brave"] == "freeze", "frozen target published with its action")
assert(suspended["nzbget.service"] == "stop", "stopped target published with its action")
assert(suspended["idle-thing"] == nil, "already-down target not listed")

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
mixed.disable()

-- Freeze targets are thawed with no probe at all.
assert(helpers.ranCommand(mixedMock, "pkill -CONT -x 'brave'"), "freeze target thawed")
assert(not helpers.ranCommand(mixedMock, "pgrep -x 'brave'"), "thaw needs no probe")
-- Stop targets keep the still-down probe before being started.
assert(helpers.ranCommand(mixedMock, "systemctl is-active 'nzbget.service'"), "stop target probed")
assert(helpers.ranCommand(mixedMock, "sudo -n systemctl start 'nzbget.service'"), "stop target started")
-- Nothing touches the target that was already down.
assert(not helpers.ranCommand(mixedMock, "'idle-thing'"), "already-down target untouched on restore")

assert(mixedMock.published.game_mode.enabled == false, "disabled")

-- A stop target the user restarted by hand is not stomped, but a freeze target is thawed
-- regardless -- SIGCONT to a running process changes nothing.
helpers.resetDir(MIXED_DIR)
mixedLive["nzbget.service"] = "active"
mixed.enable()
mixedMock.commands = {}
mixedLive["nzbget.service"] = "active" -- user restarted it during gamer mode
mixed.disable()
assert(not helpers.ranCommand(mixedMock, "sudo -n systemctl start 'nzbget.service'"), "manual restart kept")
assert(helpers.ranCommand(mixedMock, "pkill -CONT -x 'brave'"), "freeze target thawed anyway")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua tests/runtime.lua`
Expected: FAIL — `running freeze target is frozen` (enable still only knows `stopCmd`)

- [ ] **Step 3: Restrict `restorePlan` to stop targets and add `thawPlan`**

Replace `M.restorePlan` with:

```lua
-- restorePlan answers "which stopped targets may be started again?". A target qualifies
-- only if it was up when gamer mode began and is still down now: that keeps a manual
-- restart from being stomped and keeps something that was already off from being started.
-- `stateOf` returns the live state string, or nil when it could not be determined -- in
-- which case the target is left alone.
--
-- Freeze targets are deliberately excluded; they go through thawPlan, which needs no
-- probe at all.
function M.restorePlan(snap, stateOf)
    local plan = {}
    for _, target in ipairs((snap and snap.targets) or {}) do
        if UP_STATES[target.was] and M.actionOf(target) == "stop" and stateOf(target.match) == "down" then
            plan[#plan + 1] = target
        end
    end
    return plan
end

-- thawPlan returns every frozen target, with no live check. A frozen process still shows
-- up in pgrep, so there is no probe that could distinguish "still frozen" from "running",
-- and SIGCONT to a process that is not stopped is a verified no-op. Thawing
-- unconditionally is therefore both simpler and strictly safer: it cannot misread a
-- state, cannot stomp a manual restart, and cannot leave something frozen because a probe
-- failed to start.
function M.thawPlan(snap)
    local plan = {}
    for _, target in ipairs((snap and snap.targets) or {}) do
        if UP_STATES[target.was] and M.actionOf(target) == "freeze" then
            plan[#plan + 1] = target
        end
    end
    return plan
end
```

- [ ] **Step 4: Persist and validate `action` in the snapshot**

In `validSnapshotTarget`, add an action check:

```lua
local function validSnapshotTarget(entry)
    return type(entry) == "table"
        and validateShellValue(entry.match) ~= nil
        and VALID_KINDS[entry.kind] ~= nil
        and type(entry.was) == "string"
        and (entry.action == nil or VALID_ACTIONS[entry.action] == true)
end
```

In `M.readSnapshot`, carry the action through when rebuilding targets:

```lua
            targets[#targets + 1] = {
                match = entry.match,
                kind = entry.kind,
                action = entry.action,
                was = entry.was,
            }
```

- [ ] **Step 5: Make `enable` suspend by action**

Rename the `stopAll` local to `suspendAll` and replace its body:

```lua
-- suspendAll suspends every target that was up, using each target's own action. A failure
-- is logged and the flow continues: a missing NOPASSWD rule for one system unit must not
-- abandon the rest.
local function suspendAll(probed, done)
    local jobs = {}
    for _, entry in ipairs(probed) do
        if UP_STATES[entry.was] then
            local action = M.actionOf(entry)
            local command = action == "freeze" and M.freezeCmd(entry) or M.stopCmd(entry)
            if command then
                jobs[#jobs + 1] = { entry = entry, command = command, action = action }
            else
                noctalia.log("gamermode: no " .. action .. " command for " .. tostring(entry.match))
            end
        end
    end

    local pending = #jobs
    if pending == 0 then
        done(0)
        return
    end
    local suspended = 0
    for _, job in ipairs(jobs) do
        run(job.command, function(result)
            if succeeded(result) then
                suspended = suspended + 1
            else
                noctalia.log(
                    "gamermode: could not " .. job.action .. " " .. job.entry.match
                        .. ": " .. describeFailure(result)
                )
            end
            pending = pending - 1
            if pending == 0 then
                done(suspended)
            end
        end)
    end
end
```

In `M.enable`, change the `stopAll(probed, function(stopped)` call to
`suspendAll(probed, function(stopped)`.

Also in `M.enable`, record the action on each probed entry. In `probeAll`, change the slot
assignment to carry it:

```lua
                slots[index] = {
                    match = target.match,
                    kind = target.kind,
                    action = M.actionOf(target),
                    was = M.wasState(target.kind, result and result.stdout),
                }
```

and in the no-command branch of `probeAll` nothing changes (the target is skipped).

- [ ] **Step 6: Make `disable` run both passes**

Replace the body of `M.disable` between the `busy = true` line and its closing `end`:

```lua
    busy = true
    M.publishGameMode()

    local thawTargets = M.thawPlan(snap)
    -- Filter to stop targets recorded as up; the "still down" half of the check is a live
    -- probe per target below, so a manual restart in the meantime wins.
    local candidates = M.restorePlan(snap, function()
        return "down"
    end)

    local pending = #thawTargets + #candidates
    local restored = 0

    local function finish()
        M.deleteSnapshot()
        busy = false
        M.publishGameMode()
        if autoPerformance() and snap.power_profile_before then
            M.setPowerProfile(snap.power_profile_before)
        end
        if restored > 0 then
            noctalia.notify(noctalia.tr("notify.disabled_title"), noctalia.trp("notify.restored_count", restored))
        else
            noctalia.notify(noctalia.tr("notify.disabled_title"), noctalia.tr("notify.nothing_restored"))
        end
    end

    if pending == 0 then
        finish()
        return
    end

    local function step()
        pending = pending - 1
        if pending == 0 then
            finish()
        end
    end

    -- Freeze targets: thaw unconditionally, no probe.
    for _, target in ipairs(thawTargets) do
        local command = M.thawCmd(target)
        if not command then
            noctalia.log("gamermode: no thaw command for " .. tostring(target.match))
            step()
        else
            run(command, function(result)
                if succeeded(result) then
                    restored = restored + 1
                else
                    noctalia.log(
                        "gamermode: could not thaw " .. target.match .. ": " .. describeFailure(result)
                    )
                end
                step()
            end)
        end
    end

    -- Stop targets: probe, then start only if still down.
    for _, target in ipairs(candidates) do
        local startCommand = M.startCmd(target)
        if not startCommand then
            noctalia.log("gamermode: cannot restart " .. tostring(target.match) .. " (" .. tostring(target.kind) .. ")")
            step()
        else
            run(M.probeCmd(target), function(probeResult)
                if M.wasState(target.kind, probeResult and probeResult.stdout) ~= "down" then
                    step()
                    return
                end
                run(startCommand, function(startResult)
                    if succeeded(startResult) then
                        restored = restored + 1
                    else
                        noctalia.log(
                            "gamermode: could not restart " .. target.match .. ": " .. describeFailure(startResult)
                        )
                    end
                    step()
                end)
            end)
        end
    end
```

- [ ] **Step 7: Publish the action in `game_mode.suspended`**

In `M.publishGameMode`, change the suspended entry construction to:

```lua
                suspended[#suspended + 1] = {
                    match = target.match,
                    kind = target.kind,
                    action = M.actionOf(target),
                }
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `lua tests/runtime.lua`
Expected: `runtime: passed`

- [ ] **Step 9: Verify no regressions**

Run: `./run-tests.sh`
Expected: all pass.

- [ ] **Step 10: Commit**

```bash
git add gamermode/service.luau tests/runtime.lua
git commit -m "feat: split restore so frozen targets are thawed unconditionally

A frozen process still appears in pgrep, so the was-up-and-still-down probe
cannot tell 'still frozen' from 'running'. Since SIGCONT to a running process
is a verified no-op, freeze targets are thawed with no probe at all -- simpler
than the probe path and strictly safer: it cannot misread a state, cannot stomp
a manual restart, and cannot leave something frozen because a probe failed to
start.

stop targets keep the existing still-down check. The session and the published
state now record each target's action so a restore after a shell restart knows
which pass a target belongs to."
```

---

### Task 5: Generic default target list

**Files:**
- Modify: `gamermode/service.luau`
- Test: `tests/defaults.lua`

**Interfaces:**
- Consumes: `M.DEFAULT_TARGETS`, `M.isDenied`, `M.actionOf`, `M.parseTargets`, `M.targetsForProfile`, `validEntry`.
- Produces: a rewritten `M.DEFAULT_TARGETS`.

- [ ] **Step 1: Write the failing test `tests/defaults.lua`**

```lua
-- The shipped default target list must obey every rule the plugin enforces on user input,
-- and must not contain a target that would be unrecoverable or catastrophic.
package.path = "./tests/?.lua;" .. package.path
local helpers = require("helpers")

helpers.newNoctalia()
local svc = dofile("gamermode/service.luau")

local defaults = svc.DEFAULT_TARGETS
assert(#defaults > 60, "the list is broad; absent software is a free no-op, got " .. #defaults)

local seen = {}
for _, entry in ipairs(defaults) do
    local label = tostring(entry.kind) .. ":" .. tostring(entry.match)

    -- Round-tripping through the encoder and parser proves each entry passes the same
    -- validation a user's JSON would.
    local encoded = assert(helpers.json.encode({ entry }))
    local parsed = svc.parseTargets(encoded)
    assert(#parsed == 1, "default entry must be valid on its own: " .. label)

    assert(not svc.isDenied(entry.match), "default must not be protected: " .. label)
    assert(not seen[label], "duplicate default entry: " .. label)
    seen[label] = true

    -- A bare process cannot be relaunched, so no default may rely on killing one.
    if entry.kind == "process" then
        assert(svc.actionOf(entry) == "freeze", "process defaults must freeze, not stop: " .. label)
    end

    -- Timer units must be named as such or systemctl resolves the wrong unit.
    if entry.kind == "user-timer" or entry.kind == "system-timer" then
        assert(entry.match:sub(-6) == ".timer", "timer default must end in .timer: " .. label)
        assert(svc.actionOf(entry) == "stop", "timers can only be stopped: " .. label)
    end

    -- Service and timer targets are named with their unit suffix for clarity.
    if entry.kind == "user-service" or entry.kind == "system-service" then
        assert(entry.match:sub(-8) == ".service", "service default must end in .service: " .. label)
    end
end

-- heavy is a strict superset of light.
local light = svc.targetsForProfile(defaults, "light")
local heavy = svc.targetsForProfile(defaults, "heavy")
assert(#light > 0 and #heavy > #light, "heavy strictly exceeds light: " .. #light .. " vs " .. #heavy)
local inHeavy = {}
for _, entry in ipairs(heavy) do
    inHeavy[entry.kind .. ":" .. entry.match] = true
end
for _, entry in ipairs(light) do
    assert(inHeavy[entry.kind .. ":" .. entry.match], "light entry missing from heavy: " .. entry.match)
end

-- Named guarantees from the spec.
local byMatch = {}
for _, entry in ipairs(defaults) do
    byMatch[entry.match] = entry
end

-- VRAM only frees on a real stop, and a bare process cannot be restarted, so AI runtimes
-- ship as services.
for _, unit in ipairs({ "ollama.service", "localai.service", "comfyui.service", "open-webui.service" }) do
    assert(byMatch[unit], "AI runtime default missing: " .. unit)
    assert(byMatch[unit].kind == "system-service", unit .. " must be a service, not a process")
    assert(svc.actionOf(byMatch[unit]) == "stop", unit .. " must stop to release VRAM")
end
assert(not byMatch["ollama"], "no bare-process ollama default (unrecoverable)")

-- swww was archived and renamed to awww; support both.
assert(byMatch["awww-daemon"], "awww-daemon (the current name) must be present")
assert(byMatch["swww-daemon"], "swww-daemon (the archived name) kept for un-migrated users")

-- The scheduled-work gap is actually covered.
assert(byMatch["fstrim.timer"], "fstrim.timer must be a default: TRIM stalls I/O mid-game")

-- Game runtimes must never be default targets, even though they burn CPU: Minecraft and
-- every PrismLauncher instance run as `java`, Unity and .NET titles as `dotnet`.
for _, runtime in ipairs({ "java", "dotnet", "node" }) do
    assert(not byMatch[runtime], runtime .. " is a game runtime and must not be a default")
end

-- Things users want alive during a game.
for _, keep in ipairs({
    "discord", "vesktop", "slack", "element-desktop", "zoom",
    "spotify", "spotifyd", "mpd", "mpv", "vlc",
    "obs", "gpu-screen-recorder",
}) do
    assert(not byMatch[keep], keep .. " must not be a default (voice/music/streaming)")
end

-- Blunt instruments that cannot be restored correctly.
for _, blunt in ipairs({
    "docker.service", "containerd.service", "podman.service",
    "libvirtd.service", "virtqemud.service", "waydroid",
    "postgresql.service", "mysqld.service", "redis.service",
}) do
    assert(not byMatch[blunt], blunt .. " must not be a default")
end

-- v1 defaults specific to one developer's machine are gone.
assert(not byMatch["kokoro-tts"], "machine-specific default removed")
assert(byMatch["gslapper"] and svc.actionOf(byMatch["gslapper"]) == "freeze", "gslapper now freezes")
assert(byMatch["adb"] and svc.actionOf(byMatch["adb"]) == "freeze", "adb now freezes")

print("defaults: passed")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua tests/defaults.lua`
Expected: FAIL — `the list is broad; absent software is a free no-op, got 6`

- [ ] **Step 3: Replace `M.DEFAULT_TARGETS`**

Replace the whole `M.DEFAULT_TARGETS` table with:

```lua
-- Defaults aim to be plausible on an arbitrary Linux desktop rather than tuned to one
-- machine. Breadth is close to free: a target that is not running probes as `down`, so it
-- is never acted on and never restored -- an entry for absent software costs one pgrep.
-- The risk is never "too many entries", it is "an entry that is present but should not be
-- touched", which is what the denylist above exists for.
--
-- `light` is background-only: nothing the user could be interacting with, and nothing that
-- produces sound, voice or video they would want during a game. `heavy` adds the big
-- foreground consumers as freezes plus the self-hosted service stacks as stops.
local LIGHT = { "light", "heavy" }
local HEAVY = { "heavy" }

local function target(match, kind, action, profiles)
    return { match = match, kind = kind, action = action, profiles = profiles }
end

local function processes(names, profiles, out)
    for _, name in ipairs(names) do
        -- Always freeze: a bare process has no argv to relaunch from, so stopping one is
        -- unrecoverable.
        out[#out + 1] = target(name, "process", "freeze", profiles)
    end
    return out
end

local function units(names, kind, profiles, out)
    for _, name in ipairs(names) do
        out[#out + 1] = target(name, kind, "stop", profiles)
    end
    return out
end

local function buildDefaults()
    local out = {}

    -- ── light: wallpaper and desktop-effect daemons ──
    -- Animated and video wallpapers cost real GPU time. Freezing stops the rendering,
    -- which is the entire win, and SIGCONT restores it perfectly -- where killing the
    -- daemon would need a full relaunch-and-rewallpaper dance.
    -- swww was archived and renamed to awww in Oct 2025; both names ship.
    processes({
        "awww-daemon", "swww-daemon", "hyprpaper", "swaybg", "wpaperd", "mpvpaper",
        "glpaper", "wbg", "oguri", "linux-wallpaperengine", "gslapper",
    }, LIGHT, out)

    -- ── light: torrent and usenet ──
    -- Sustained disk I/O plus network saturation; usenet unpack and par2 repair also burn
    -- a lot of CPU.
    processes({
        "qbittorrent", "qbittorrent-nox", "transmission-daemon", "transmission-gtk",
        "deluged", "deluge-gtk", "rtorrent", "aria2c", "ktorrent",
        "sabnzbd", "sabnzbdplus", "nzbget",
    }, LIGHT, out)
    units({
        "transmission.service", "qbittorrent-nox.service", "deluged.service",
        "aria2.service", "sabnzbd.service", "nzbget.service",
    }, "system-service", LIGHT, out)

    -- ── light: cloud sync ──
    processes({
        "syncthing", "dropbox", "nextcloud", "insync", "megasync", "onedrive",
        "maestral", "rclone", "seafile-applet", "owncloud",
    }, LIGHT, out)
    units({ "syncthing.service", "onedrive.service" }, "user-service", LIGHT, out)

    -- ── light: backup ──
    processes({ "borg", "restic", "duplicati", "rsnapshot", "kopia" }, LIGHT, out)
    units({
        "borgmatic.timer", "restic-backup.timer", "snapper-timeline.timer",
        "snapper-cleanup.timer", "duplicati.timer",
    }, "system-timer", LIGHT, out)

    -- ── light: file indexers ──
    processes({
        "baloo_file", "baloo_file_extractor", "tracker-miner-fs-3", "tracker-extract-3",
        "recollindex", "updatedb", "plocate",
    }, LIGHT, out)
    units({ "plocate-updatedb.timer", "updatedb.timer", "mlocate.timer" }, "system-timer", LIGHT, out)

    -- ── light: scheduled maintenance ──
    -- Stopping a service does nothing if its timer re-fires it mid-game. fstrim in
    -- particular stalls I/O hard.
    units({
        "fstrim.timer", "smartd.timer", "paccache.timer", "pamac-cleancache.timer",
        "reflector.timer", "archlinux-keyring-wkd-sync.timer", "pacman-filesdb-refresh.timer",
        "systemd-tmpfiles-clean.timer", "man-db.timer", "dnf-makecache.timer",
        "snapd.refresh.timer", "flatpak-system-update.timer", "e2scrub_all.timer",
    }, "system-timer", LIGHT, out)

    -- ── light: update daemons ──
    units({
        "packagekit.service", "pamac-daemon.service", "snapd.service",
        "unattended-upgrades.service",
    }, "system-service", LIGHT, out)

    -- ── light: AI / LLM runtimes ──
    -- These hold VRAM, which only a real stop releases -- freezing keeps every page
    -- resident. Service-kind only, because process + stop is unrecoverable.
    units({
        "ollama.service", "localai.service", "comfyui.service", "open-webui.service",
    }, "system-service", LIGHT, out)

    -- ── light: antivirus and telemetry ──
    units({
        "clamav-daemon.service", "clamd.service", "clamav-freshclam.service",
    }, "system-service", LIGHT, out)
    units({ "clamav-freshclam.timer", "rkhunter.timer" }, "system-timer", LIGHT, out)
    units({
        "whoopsie.service", "apport.service", "abrtd.service", "teamviewerd.service",
        "anydesk.service",
    }, "system-service", LIGHT, out)

    -- ── light: phone and emulator tooling ──
    processes({ "adb", "scrcpy" }, LIGHT, out)

    -- ── heavy: browsers ──
    -- Usually the single largest consumer of both RAM and CPU. Frozen, not killed: nobody
    -- wants their tabs gone when they quit a game.
    processes({
        "brave", "chrome", "google-chrome", "chromium", "firefox", "librewolf",
        "vivaldi-bin", "opera", "microsoft-edge", "thorium", "zen-browser", "waterfox",
        "qutebrowser",
    }, HEAVY, out)

    -- ── heavy: editors, language servers, builds ──
    -- `java`, `dotnet` and `node` are deliberately absent: they are game runtimes as well
    -- as build tools. Minecraft and every PrismLauncher instance run as `java`, Unity and
    -- .NET titles as `dotnet` -- freezing them would freeze the game.
    processes({
        "code", "codium", "code-oss", "cursor", "zed", "idea", "pycharm", "webstorm",
        "clion", "goland", "rider", "rustrover", "android-studio", "sublime_text",
    }, HEAVY, out)
    processes({
        "rust-analyzer", "gopls", "clangd", "pylsp", "pyright",
        "typescript-language-server", "jdtls", "lua-language-server", "omnisharp", "ccls",
    }, HEAVY, out)
    processes({
        "cargo", "rustc", "gradle", "tsc", "webpack", "vite", "esbuild", "ninja", "make",
        "cc1plus", "ccache", "sccache", "distccd",
    }, HEAVY, out)
    processes({ "claude", "opencode", "codex", "aider" }, HEAVY, out)

    -- ── heavy: CI runners ──
    units({
        "gitlab-runner.service", "buildkite-agent.service", "jenkins.service",
    }, "system-service", HEAVY, out)

    -- ── heavy: self-hosted media stack ──
    units({
        "sonarr.service", "radarr.service", "lidarr.service", "readarr.service",
        "prowlarr.service", "bazarr.service", "jackett.service", "jellyseerr.service",
        "overseerr.service", "ombi.service", "tautulli.service",
    }, "system-service", HEAVY, out)
    units({
        "jellyfin.service", "plexmediaserver.service", "emby-server.service",
        "audiobookshelf.service", "navidrome.service", "komga.service", "kavita.service",
        "photoprism.service", "calibre-server.service",
    }, "system-service", HEAVY, out)

    -- ── heavy: JVM databases ──
    -- Multi-gigabyte heaps. Other databases (postgres, mysql, redis) are omitted because
    -- other services depend on them.
    units({ "elasticsearch.service", "opensearch.service" }, "system-service", HEAVY, out)

    return out
end

M.DEFAULT_TARGETS = buildDefaults()
```

- [ ] **Step 4: Run the test to verify it passes**

Run: `lua tests/defaults.lua`
Expected: `defaults: passed`

- [ ] **Step 5: Verify no regressions**

Run: `./run-tests.sh`
Expected: all pass. Note `tests/targets.lua` asserts `#heavy >= #light` and that light
entries are light-tagged, both of which still hold.

- [ ] **Step 6: Commit**

```bash
git add gamermode/service.luau tests/defaults.lua
git commit -m "feat: generic default target list

Replaces six machine-specific defaults with a broad list organised by category
and plausible on an arbitrary desktop. Breadth is close to free: a target that
is not running probes as down, so an entry for absent software costs one pgrep.

Every bare-process default now freezes rather than stops, because stopping one
is unrecoverable. AI runtimes ship as services with action=stop, since VRAM only
frees on a real stop. Timers cover the scheduled work that stopping a service
alone cannot suppress.

swww was archived and renamed to awww; both names ship. java, dotnet and node
are excluded despite burning CPU, because they are game runtimes -- freezing
java freezes Minecraft. Voice chat, music, streaming, wholesale container and VM
daemons, and shared databases are all excluded and documented instead."
```

---

### Task 6: Boot-ID staleness detection

**Files:**
- Modify: `gamermode/service.luau`, `tests/helpers.lua`
- Test: `tests/staleness.lua`

**Interfaces:**
- Consumes: `M.buildSnapshot`, `M.readSnapshot`, `M.writeSnapshot`, `M.disable`, `M.publishGameMode`, `M.init`, `M.refreshPower`.
- Produces: `M.currentBootId() -> string|nil`; `buildSnapshot` records `boot_id`; `M.reconcileSession()` called from `init` after power state is known.

- [ ] **Step 1: Let the mock serve a boot id**

In `tests/helpers.lua`, inside `newNoctalia`, add a `bootId` field to the mock table
(alongside `clock`):

```lua
        bootId = opts.bootId or "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee",
```

and make `readFile` serve the kernel path from it, by replacing `mock.readFile` with:

```lua
    mock.readFile = function(path)
        -- The kernel boot id is served from the mock so tests can simulate a reboot.
        if path == "/proc/sys/kernel/random/boot_id" then
            if mock.bootId == false then
                return nil, "unreadable"
            end
            return mock.bootId .. "\n"
        end
        local file = io.open(path, "r")
        if not file then
            return nil, "not found"
        end
        local contents = file:read("*a")
        file:close()
        return contents
    end
```

- [ ] **Step 2: Write the failing test `tests/staleness.lua`**

```lua
-- A session file outlives a reboot. Enabled units come back on their own, so without a
-- staleness check the panel reports gamer mode ON forever over a suspend list of
-- processes that are all running.
package.path = "./tests/?.lua;" .. package.path
local helpers = require("helpers")

local DIR = "/tmp/gamermode-test-stale"

local function newService(opts)
    helpers.resetDir(DIR)
    local mock = helpers.newNoctalia({
        dataDir = DIR,
        bootId = opts.bootId,
        config = { profile = "light", auto_performance = false, targets = opts.targets },
        respond = opts.respond or function()
            return { stdout = "" }
        end,
    })
    return mock, dofile("gamermode/service.luau")
end

local TARGETS = '[{"match":"nzbget.service","kind":"system-service","action":"stop","profiles":["light"]},'
    .. '{"match":"brave","kind":"process","action":"freeze","profiles":["light"]}]'

-- ── the boot id is recorded ──

local mock, svc = newService({ bootId = "boot-one", targets = TARGETS })
assert(svc.currentBootId() == "boot-one", "boot id read and trimmed, got " .. tostring(svc.currentBootId()))

local snap = svc.buildSnapshot("light", "balanced", {})
assert(snap.boot_id == "boot-one", "buildSnapshot records the boot id")
assert(svc.writeSnapshot(snap), "written")
assert(svc.readSnapshot().boot_id == "boot-one", "boot id round-trips")

-- ── same boot: the session is kept ──

-- Within one boot a session that looks stale is deliberately kept: that is exactly the
-- case where something may still be frozen and needs thawing.
local sameMock, same = newService({
    bootId = "boot-one",
    targets = TARGETS,
    respond = function(command)
        if command:find("is-active", 1, true) or command:find("pgrep", 1, true) then
            return { stdout = command:find("pgrep", 1, true) and "1234" or "active" }
        end
        return { stdout = "" }
    end,
})
same.enable()
assert(sameMock.published.game_mode.enabled == true, "enabled")
sameMock.commands = {}
-- Reloading the service on the same boot must not clear the session.
local sameAgain = dofile("gamermode/service.luau")
assert(sameMock.published.game_mode.enabled == true, "session survives a reload on the same boot")
assert(not helpers.ranCommand(sameMock, "systemctl start"), "no restore on the same boot")
assert(sameAgain.readSnapshot() ~= nil, "session file still present")

-- ── different boot: restore, then clear ──

local rebootMock, reboot = newService({
    bootId = "boot-one",
    targets = TARGETS,
    respond = function(command)
        if command:find("pgrep", 1, true) then
            return { stdout = "1234" }
        elseif command:find("is-active", 1, true) then
            return { stdout = "active" }
        end
        return { stdout = "" }
    end,
})
reboot.enable()
assert(rebootMock.published.game_mode.enabled == true, "enabled before the reboot")

-- Simulate the reboot: new boot id, and the stopped unit is still down.
rebootMock.bootId = "boot-two"
rebootMock.commands = {}
rebootMock.respond = function(command)
    if command:find("is-active", 1, true) then
        return { stdout = "inactive", exitCode = 3 }
    end
    return { stdout = "" }
end

local afterReboot = dofile("gamermode/service.luau")

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
local legacyMock, legacy = newService({ bootId = "boot-one", targets = TARGETS })
assert(legacyMock.writeFile(
    DIR .. "/session.json",
    '{"version":1,"profile":"light","power_profile_before":"balanced","targets":'
        .. '[{"match":"nzbget.service","kind":"system-service","action":"stop","was":"active"}]}'
), "legacy fixture written")
legacyMock.commands = {}
local legacyReload = dofile("gamermode/service.luau")
assert(legacyMock.published.game_mode.enabled == true, "a session with no boot id is kept")
assert(legacyReload.readSnapshot() ~= nil, "legacy session not cleared")

-- ── an unreadable boot id degrades to "current" ──

local blindMock, _ = newService({ bootId = false, targets = TARGETS })
assert(blindMock.writeFile(
    DIR .. "/session.json",
    '{"version":1,"profile":"light","boot_id":"boot-one","targets":'
        .. '[{"match":"nzbget.service","kind":"system-service","action":"stop","was":"active"}]}'
), "fixture written")
local blind = dofile("gamermode/service.luau")
assert(blindMock.published.game_mode.enabled == true, "unreadable boot id keeps the session")
assert(blind.readSnapshot() ~= nil, "session kept when staleness cannot be determined")

print("staleness: passed")
```

- [ ] **Step 3: Run test to verify it fails**

Run: `lua tests/staleness.lua`
Expected: FAIL — `attempt to call a nil value (field 'currentBootId')`

- [ ] **Step 4: Read and record the boot id**

Add above `M.buildSnapshot`:

```lua
-- The kernel boot id changes on every boot, which makes it an exact staleness marker for
-- a session file. Cheaper and more reliable than inferring staleness from live state: a
-- frozen process still appears in pgrep, so "is everything running again?" false-positives
-- on freeze targets.
function M.currentBootId()
    local contents = noctalia.readFile("/proc/sys/kernel/random/boot_id")
    if not contents then
        return nil
    end
    local id = contents:gsub("%s+", "")
    return id ~= "" and id or nil
end
```

Change `M.buildSnapshot` to record it:

```lua
function M.buildSnapshot(profile, powerProfileBefore, probedTargets)
    return {
        version = SNAPSHOT_VERSION,
        profile = profile,
        power_profile_before = powerProfileBefore,
        boot_id = M.currentBootId(),
        targets = probedTargets,
    }
end
```

Carry it through `M.readSnapshot`'s return value:

```lua
    return {
        version = decoded.version,
        profile = type(decoded.profile) == "string" and decoded.profile or "light",
        power_profile_before = type(decoded.power_profile_before) == "string" and decoded.power_profile_before or nil,
        boot_id = type(decoded.boot_id) == "string" and decoded.boot_id or nil,
        targets = targets,
    }
```

- [ ] **Step 5: Add `reconcileSession` and call it from `init`**

Add immediately above `M.init`:

```lua
-- reconcileSession decides what a session file found at startup means. A session from a
-- previous boot is stale: nothing it froze still exists, and units it stopped may have
-- come back on their own. It still gets a full restore pass before being cleared, because
-- a stopped unit that is not `enabled` really is still down and putting it back is what
-- the user was told would happen.
--
-- Within the same boot a session is always kept, even if everything looks running -- that
-- is precisely the case where something may still be frozen and needs thawing.
function M.reconcileSession()
    local snap = M.readSnapshot()
    if not snap then
        M.publishGameMode()
        return
    end

    local current = M.currentBootId()
    -- A snapshot with no boot id was written by an older version; treat it as current
    -- rather than abandoning targets that may still be suspended. Likewise if the boot id
    -- cannot be read at all.
    if not snap.boot_id or not current or snap.boot_id == current then
        M.publishGameMode()
        return
    end

    noctalia.log("gamermode: session predates the current boot, restoring and clearing it")
    M.disable()
end
```

Replace `M.init` with:

```lua
function M.init()
    local directory = noctalia.pluginDataDir()
    if directory then
        noctalia.mkdirAll(directory)
    end
    -- Publish immediately so a panel opened before the first poll is not empty.
    M.publishGameMode()
    M.publishMetrics()
    -- Reconciliation can restore the previous power profile, so it waits until the power
    -- state is known.
    M.refreshPower(function()
        M.reconcileSession()
    end)

    local seconds = tonumber(noctalia.getConfig("poll_interval")) or DEFAULT_POLL_SECONDS
    noctalia.setUpdateInterval(math.max(1, seconds) * 1000)
end
```

- [ ] **Step 6: Run the test to verify it passes**

Run: `lua tests/staleness.lua`
Expected: `staleness: passed`

- [ ] **Step 7: Verify no regressions**

Run: `./run-tests.sh`
Expected: all pass.

- [ ] **Step 8: Commit**

```bash
git add gamermode/service.luau tests/helpers.lua tests/staleness.lua
git commit -m "feat: detect a stale session by kernel boot id

session.json outlives a reboot, so without this the panel reports gamer mode ON
forever over a suspend list of processes that are all running again.

The boot id is exact where inferring staleness from live state is not: a frozen
process still appears in pgrep, so 'is everything running again?' would
false-positive on every freeze target.

A stale session gets a full restore pass before being cleared, because a stopped
unit that is not enabled really is still down. A session from the same boot is
always kept -- that is the case where something may still be frozen. A session
with no boot id, or an unreadable boot id, is treated as current rather than
abandoning targets that may still be suspended."
```

---

### Task 7: Panel shows the action, plus translations

**Files:**
- Modify: `gamermode/panel.luau`, `gamermode/translations/en.json`
- Test: `tests/panel.lua`

**Interfaces:**
- Consumes: `game_mode.suspended` entries now carrying `action` (Task 4).
- Produces: `M.suspendedLines(gm)` renders the action word.

- [ ] **Step 1: Extend `tests/panel.lua`**

Change the `mock.published.game_mode` fixture near the top of the file so its suspended
entries carry actions:

```lua
mock.published.game_mode = {
    enabled = true,
    busy = false,
    profile = "light",
    suspended = {
        { match = "gslapper", kind = "process", action = "freeze" },
        { match = "ollama.service", kind = "system-service", action = "stop" },
    },
}
```

Then replace the existing suspended-list assertions with:

```lua
local lines = p.suspendedLines(mock.published.game_mode)
assert(#lines == 2, "two suspended entries, got " .. #lines)
assert(lines[1]:find("gslapper", 1, true), "entry names the target: " .. lines[1])
assert(lines[1]:find("process", 1, true), "entry names the kind: " .. lines[1])
-- A frozen target and a stopped one are not the same thing to a user deciding whether to
-- worry about it, so the action is spelled out.
assert(lines[1]:find("panel.frozen", 1, true), "frozen target labelled: " .. lines[1])
assert(lines[2]:find("panel.stopped", 1, true), "stopped target labelled: " .. lines[2])
-- An entry with no action reads as stopped, matching the engine default.
local legacy = p.suspendedLines({ enabled = true, suspended = { { match = "x", kind = "process" } } })
assert(legacy[1]:find("panel.stopped", 1, true), "absent action reads as stopped: " .. legacy[1])
assert(#p.suspendedLines({ enabled = false, suspended = {} }) == 0, "nothing listed while disabled")
assert(#p.suspendedLines(nil) == 0, "nil game_mode lists nothing")
assert(#p.suspendedLines({ enabled = true }) == 0, "missing suspended list is tolerated")
```

- [ ] **Step 2: Run test to verify it fails**

Run: `lua tests/panel.lua`
Expected: FAIL — `frozen target labelled: gslapper (process)`

- [ ] **Step 3: Render the action in `gamermode/panel.luau`**

Replace `M.suspendedLines` with:

```lua
function M.suspendedLines(gm)
    local lines = {}
    for _, target in ipairs((type(gm) == "table" and gm.suspended) or {}) do
        -- Frozen and stopped are materially different to a user reading this list: one
        -- resumes exactly, the other was shut down and restarted.
        local state = target.action == "freeze" and tr("panel.frozen") or tr("panel.stopped")
        lines[#lines + 1] = string.format("%s (%s, %s)", tostring(target.match), tostring(target.kind), state)
    end
    return lines
end
```

- [ ] **Step 4: Add the two strings to `gamermode/translations/en.json`**

In the `panel` object, after `"nothing_suspended"`, add:

```json
    "frozen": "frozen",
    "stopped": "stopped",
```

- [ ] **Step 5: Run the tests to verify they pass**

Run: `lua tests/panel.lua && sh tests/scaffold.sh`
Expected: `panel: passed` then `scaffold: passed`

- [ ] **Step 6: Verify no regressions**

Run: `./run-tests.sh`
Expected: all pass.

- [ ] **Step 7: Commit**

```bash
git add gamermode/panel.luau gamermode/translations/en.json tests/panel.lua
git commit -m "feat: label frozen and stopped targets in the panel

Frozen and stopped are materially different to someone reading the suspend
list: one resumes exactly where it left off, the other was shut down and
restarted. An entry with no action reads as stopped, matching the engine
default."
```

---

### Task 8: Documentation, full verification, push

**Files:**
- Modify: `README.md`
- Modify: `gamermode/plugin.toml`, `catalog.toml` (version bump)

- [ ] **Step 1: Bump the version to 0.2.0 in both manifests**

In `gamermode/plugin.toml` and `catalog.toml`, change `version = "0.1.0"` to
`version = "0.2.0"`. `tests/scaffold.sh` fails if the two drift.

- [ ] **Step 2: Rewrite the README's kill-list section**

Replace the "The kill list" section through "System services need passwordless sudo" with
documentation covering, in this order:

1. The `action` field: `stop` frees RAM and VRAM but shuts the target down; `freeze`
   (SIGSTOP / `docker pause`) resumes exactly and loses nothing but frees no memory.
   Default is `stop` for backward compatibility, but every shipped process default uses
   `freeze`.
2. The full kind × action matrix, copied from the spec's §2 table.
3. `kind: process` + `action: stop` is unrecoverable — no argv to relaunch from. The
   plugin logs a warning. Target the supervising unit instead.
4. The two timer kinds, with the explanation that stopping `foo.service` does not stop
   `foo.timer` from re-firing it, and that the `.timer` suffix is mandatory because
   `systemctl is-active fstrim` resolves to `fstrim.service`.
5. The denylist: the full list, and why it is not overridable.
6. The sudoers snippet (unchanged from v1, listing individual units).
7. A "not in the defaults, on purpose" section with copy-paste JSON for voice chat, music,
   streaming, containers, VMs and shared databases, each with its one-line reason —
   including that `java`/`dotnet`/`node` are game runtimes.
8. Boot-ID restore behaviour under "Restore semantics".

- [ ] **Step 3: Run the full suite**

Run: `./run-tests.sh`
Expected: all 13 suites pass.

- [ ] **Step 4: Mutation-test the safety-critical paths**

Each of these must make the suite FAIL. Restore the file after each.

```bash
S=gamermode/service.luau; cp $S /tmp/svc.bak
mut() { cp /tmp/svc.bak $S; sed -i "$2" $S; if ./run-tests.sh >/dev/null 2>&1; then echo "NOT CAUGHT: $1"; else echo "caught: $1"; fi; }

mut "denylist disabled at parse"  's|if M.isDenied(entry.match) then|if false then|'
mut "denylist disabled at action" 's|if M.isDenied(target.match) then|if false then|'
mut "freeze targets probed before thaw" 's|and M.actionOf(target) == "freeze" then|and false then|'
mut "timer suffix rule dropped" 's|entry.match:lower():sub(-6) ~= ".timer"|false|'
mut "process defaults could stop" 's|out\[#out + 1\] = target(name, "process", "freeze", profiles)|out[#out + 1] = target(name, "process", "stop", profiles)|'
mut "staleness ignored" 's|noctalia.log("gamermode: session predates|do M.publishGameMode() return end noctalia.log("gamermode: session predates|'

cp /tmp/svc.bak $S; ./run-tests.sh
```

- [ ] **Step 5: Commit and push**

```bash
git add README.md gamermode/plugin.toml catalog.toml
git commit -m "docs: document actions, timer kinds and the denylist

Covers when to choose stop versus freeze, the full kind x action matrix, why
process + stop is unrecoverable, why a service target without its timer is
insufficient, the denylist and why it is not overridable, and the categories
deliberately left out of the defaults with copy-paste JSON for each.

Bumps to 0.2.0."
git push -u origin main
```

---

## Self-review

**Spec coverage:** §1 denylist → Task 1. §2 action + timer kinds + command matrix +
validation rules → Tasks 2, 3. §2 restore split → Task 4. §3 default list → Task 5.
§4 boot-ID staleness → Task 6. §5 state and UI → Tasks 4 (state) and 7 (UI). §6 testing →
the four new suites in Tasks 1, 3, 5, 6 plus extensions in Tasks 4 and 7, with the
mutation bar in Task 8 Step 4. §7 documentation → Task 8.

**Type consistency:** `M.isDenied`, `M.actionOf`, `M.freezeCmd`, `M.thawCmd`,
`M.thawPlan`, `M.currentBootId`, `M.reconcileSession` are each defined once and referenced
consistently. `validEntry` changes from `-> ok` to `-> ok, reason` in Task 1, and every
later reference uses the two-value form. `stopAll` is renamed to `suspendAll` in Task 4
with its only call site updated in the same step. `VALID_ACTIONS` is declared in Task 3
Step 4's relocation note, above its first use in `validEntry`.

**Ordering:** Task 5 depends on the denylist (Task 1), timer kinds (Task 2) and the
`action` field (Task 3), because `tests/defaults.lua` asserts against all three. Task 7
depends on Task 4 publishing `action`. Task 6 is independent of 2–5 but is placed after
them so `tests/staleness.lua` can use freeze targets.
