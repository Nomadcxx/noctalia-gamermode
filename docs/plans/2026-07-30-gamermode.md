# GamerMode Plugin Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a Noctalia V5 luau plugin showing live CPU/RAM/GPU metrics with a one-click gamer mode that suspends and carefully restores resource-heavy targets.

**Architecture:** Single `service.luau` owns a metrics poller (/proc + nvidia-smi, vendor auto-detect) and the snapshot-based game-mode engine. Panel/widget are thin: they read `noctalia.state` and send commands via `state.set("command", ...)`. Design details: `docs/plans/2026-07-30-gamermode-design.md`.

**Tech Stack:** Noctalia V5 luau plugin API (`plugin_api = 19`), plain `lua` for tests (pattern: mock `noctalia` global + `dofile`, like `/home/nomadx/noctalia-gslapper/tests/panel-selftest.lua`).

**Repo layout** (matches gslapper): plugin code in `gamermode/`, tests in `tests/`.

**Test runner:** all tests via `lua tests/<name>.lua` and `sh tests/<name>.sh`. `/usr/bin/lua` exists.

---

### Task 1: Scaffold — plugin.toml, translations, validation test

**Files:**
- Create: `gamermode/plugin.toml`
- Create: `gamermode/translations/en.json`
- Create: `tests/scaffold.sh`
- Existing: `gamermode/icon.svg` (done)

**Step 1: Write `gamermode/plugin.toml`**

```toml
id = "nomadcxx/gamermode"
name = "Gamer Mode"
version = "0.1.0"
plugin_api = 19
author = "Nomadcxx"
license = "MIT"
dependencies = ["powerprofilesctl"]
tags = ["bar", "panel", "service", "gaming", "performance", "metrics"]
icon = "gamermode/icon.svg"
description = "Live CPU/RAM/GPU metrics and a one-click gamer mode that suspends and restores background resource hogs."

[[setting]]
key = "glyph"
type = "glyph"
label_key = "settings.glyph.label"
description_key = "settings.glyph.description"
default = "gamepad"

[[setting]]
key = "click_action"
type = "select"
label_key = "settings.click_action.label"
description_key = "settings.click_action.description"
default = "toggle"
options = [
  { value = "toggle", label_key = "settings.click_action.options.toggle" },
  { value = "open_panel", label_key = "settings.click_action.options.open_panel" },
]

[[setting]]
key = "poll_interval"
type = "select"
label_key = "settings.poll_interval.label"
description_key = "settings.poll_interval.description"
default = "3"
options = [
  { value = "2", label_key = "settings.poll_interval.options.2" },
  { value = "3", label_key = "settings.poll_interval.options.3" },
  { value = "5", label_key = "settings.poll_interval.options.5" },
]

[[setting]]
key = "profile"
type = "select"
label_key = "settings.profile.label"
description_key = "settings.profile.description"
default = "light"
options = [
  { value = "light", label_key = "settings.profile.options.light" },
  { value = "heavy", label_key = "settings.profile.options.heavy" },
]

[[setting]]
key = "auto_performance"
type = "bool"
label_key = "settings.auto_performance.label"
description_key = "settings.auto_performance.description"
default = true

[[setting]]
key = "show_temps"
type = "bool"
label_key = "settings.show_temps.label"
description_key = "settings.show_temps.description"
default = true

[[setting]]
key = "targets"
type = "string"
label_key = "settings.targets.label"
description_key = "settings.targets.description"
default = ""
advanced = true

[[service]]
id = "service"
entry = "service.luau"

[[panel]]
id = "main"
entry = "panel.luau"
width = 420
height = 560
placement = "attached"
position = "auto"
keyboard_focus = "none"

[[widget]]
id = "bar"
entry = "widget.luau"
```

**Step 2: Write `gamermode/translations/en.json`**

```json
{
  "widget": {
    "tooltip_loading": "Gamer Mode: loading metrics..."
  },
  "settings": {
    "glyph": { "label": "Bar icon", "description": "Glyph shown on the bar." },
    "click_action": { "label": "Left-click action", "description": "What left-clicking the bar icon does.", "options": { "toggle": "Toggle gamer mode", "open_panel": "Open panel" } },
    "poll_interval": { "label": "Poll interval", "description": "Seconds between metric updates.", "options": { "2": "2s", "3": "3s", "5": "5s" } },
    "profile": { "label": "Gamer mode profile", "description": "How aggressive the suspend list is.", "options": { "light": "Light", "heavy": "Heavy" } },
    "auto_performance": { "label": "Auto performance profile", "description": "Switch power profile to performance while gamer mode is on." },
    "show_temps": { "label": "Show temperatures", "description": "Include CPU/GPU temperatures in tooltip and panel." },
    "targets": { "label": "Suspend targets (JSON)", "description": "Advanced: JSON array of {match, kind, profiles}. Kind: process, user-service, system-service, container." }
  },
  "panel": {
    "title": "Gamer Mode",
    "enable": "Enable",
    "disable": "Disable",
    "performance": "Performance",
    "power_profile": "Power profile",
    "mode_profile": "Suspend profile",
    "suspended": "Suspended",
    "nothing_suspended": "Nothing suspended",
    "gpu_unsupported": "GPU metrics unsupported",
    "settings": "Settings"
  },
  "notify": {
    "enabled_title": "Gamer mode enabled",
    "disabled_title": "Gamer mode disabled"
  }
}
```

**Step 3: Write `tests/scaffold.sh`**

```sh
#!/bin/sh
set -eu
expect() { grep -q "$1" "$2" || { echo "missing: $1 in $2" >&2; exit 1; }; }
expect '^id = "nomadcxx/gamermode"$' gamermode/plugin.toml
expect 'plugin_api = 19' gamermode/plugin.toml
expect 'entry = "service.luau"' gamermode/plugin.toml
expect 'entry = "panel.luau"' gamermode/plugin.toml
expect 'entry = "widget.luau"' gamermode/plugin.toml
lua -e 'local f=assert(io.open("gamermode/translations/en.json")):read("*a"); assert(f:find("auto_performance",1,true), "translations parse shape")'
echo "scaffold: passed"
```

**Step 4: Run test**

Run: `sh tests/scaffold.sh`
Expected: `scaffold: passed`

**Step 5: Commit**

```bash
git add gamermode/plugin.toml gamermode/translations/en.json tests/scaffold.sh
git commit -m "feat: scaffold gamermode plugin manifest and translations"
```

---

### Task 2: Metrics parsers (pure functions) + tests

**Files:**
- Create: `gamermode/service.luau` (parsers only at this stage)
- Test: `tests/metrics.lua`

**Step 1: Write the failing test `tests/metrics.lua`**

```lua
package.path = "./?.lua;" .. package.path
noctalia = {
    setUpdateInterval = function() end,
    getConfig = function() return nil end,
    state = { get = function() return nil end, set = function() end, watch = function() end },
    runAsync = function() end,
    pluginDataDir = function() return "/tmp/gamermode-test" end,
}

local svc = dofile("gamermode/service.luau")

-- /proc/stat: first sample baselines, second computes
local stat1 = "cpu  100 0 100 800 0 0 100 0 0 0\n"
local stat2 = "cpu  150 0 150 900 0 0 150 0 0 0\n"
local s1 = svc.parseProcStat(stat1)
assert(s1.total == 1100 and s1.idle == 800, "stat1 totals")
local s2 = svc.parseProcStat(stat2)
local perc = svc.cpuPercent(s1, s2)
assert(math.abs(perc - 0.5) < 0.001, "50% busy, got " .. perc)

-- /proc/meminfo
local mem = svc.parseMemInfo("MemTotal:       32768 kB\nMemAvailable:   16384 kB\n")
assert(mem.total == 32768 and mem.used == 16384, "meminfo used")

-- nvidia-smi csv
local gpu = svc.parseNvidiaSmi("31, 64, 3607, 8188\n")
assert(gpu.util == 31 and gpu.temp == 64 and gpu.vramUsed == 3607 and gpu.vramTotal == 8188, "nvidia-smi parse")

-- sensors: AMD Tctl and fallback
local t = svc.parseSensorsTemp("Tctl:\n         +58.5 C  (high = +90.0 C)\n")
assert(math.abs(t - 58.5) < 0.01, "Tctl parse")
assert(svc.parseSensorsTemp("garbage") == nil, "no match returns nil")

print("metrics: passed")
```

**Step 2: Run test to verify it fails**

Run: `lua tests/metrics.lua`
Expected: FAIL — `attempt to index a nil value` or missing functions

**Step 3: Write `gamermode/service.luau` (parsers + module return)**

```lua
--!nonstrict

local M = {}

function M.parseProcStat(text)
    local a, b, c, d, e, f, g = text:match("^cpu%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)%s+(%d+)")
    if not a then return nil end
    local nums = { tonumber(a), tonumber(b), tonumber(c), tonumber(d), tonumber(e), tonumber(f), tonumber(g) }
    local total = 0
    for _, n in ipairs(nums) do total = total + n end
    return { total = total, idle = nums[4] + nums[5] }
end

function M.cpuPercent(prev, cur)
    if not prev or not cur then return 0 end
    local totalDiff = cur.total - prev.total
    local idleDiff = cur.idle - prev.idle
    if totalDiff <= 0 then return 0 end
    return math.max(0, math.min(1, 1 - idleDiff / totalDiff))
end

function M.parseMemInfo(text)
    local total = tonumber(text:match("MemTotal:%s*(%d+)"))
    local avail = tonumber(text:match("MemAvailable:%s*(%d+)"))
    if not total or not avail then return nil end
    return { total = total, used = total - avail }
end

function M.parseNvidiaSmi(text)
    local util, temp, used, total = text:match("(%d+),%s*(%d+),%s*(%d+),%s*(%d+)")
    if not util then return nil end
    return { util = tonumber(util), temp = tonumber(temp), vramUsed = tonumber(used), vramTotal = tonumber(total) }
end

function M.parseSensorsTemp(text)
    local t = text:match("Package id %d+:%s*%+([%d.]+)") or text:match("Tdie:%s*%+([%d.]+)") or text:match("Tctl:%s*%+([%d.]+)")
    return t and tonumber(t) or nil
end

-- runtime wiring added in Task 6
return M
```

**Step 4: Run test to verify it passes**

Run: `lua tests/metrics.lua`
Expected: `metrics: passed`

**Step 5: Commit**

```bash
git add gamermode/service.luau tests/metrics.lua
git commit -m "feat: metric parsers for proc/stat, meminfo, nvidia-smi, sensors"
```

---

### Task 3: Kill-list parsing + defaults fallback

**Files:**
- Modify: `gamermode/service.luau`
- Test: `tests/targets.lua`

**Step 1: Write the failing test `tests/targets.lua`**

```lua
noctalia = {
    setUpdateInterval = function() end,
    getConfig = function() return nil end,
    state = { get = function() return nil end, set = function() end, watch = function() end },
    runAsync = function() end,
    pluginDataDir = function() return "/tmp/gamermode-test" end,
    json = {
        decode = function(s)
            local ok, res = pcall(function()
                return load("return " .. s:gsub('"%s*:', '" ='):gsub("%[", "{"):gsub("%]", "}"), "json", "t", {})()
            end)
            return ok and res or nil
        end,
    },
}

local svc = dofile("gamermode/service.luau")

-- defaults when unset / malformed
local defs = svc.parseTargets(nil)
assert(type(defs) == "table" and #defs > 0, "defaults on nil")
assert(defs[1].kind and defs[1].match and defs[1].profiles, "default entry shape")
assert(#svc.parseTargets("not json") > 0, "defaults on malformed")

-- valid custom list
local custom = svc.parseTargets('[{"match":"foo","kind":"process","profiles":["light"]}]')
assert(#custom == 1 and custom[1].match == "foo", "custom parsed")

-- profile filtering
local light = svc.targetsForProfile(defs, "light")
local heavy = svc.targetsForProfile(defs, "heavy")
assert(#heavy >= #light, "heavy is superset")
for _, t in ipairs(light) do
    local found = false
    for _, p in ipairs(t.profiles) do if p == "light" then found = true end end
    assert(found, "light targets tagged light")
end

-- kind validation: bad kinds dropped
local mixed = svc.parseTargets('[{"match":"a","kind":"bogus","profiles":["light"]},{"match":"b","kind":"process","profiles":["light"]}]')
assert(#mixed == 1 and mixed[1].match == "b", "invalid kind dropped")

print("targets: passed")
```

**Step 2: Run test to verify it fails**

Run: `lua tests/targets.lua`
Expected: FAIL — `parseTargets` nil

**Step 3: Add to `gamermode/service.luau` (before `return M`)**

```lua
local VALID_KINDS = { process = true, ["user-service"] = true, ["system-service"] = true, container = true }

M.DEFAULT_TARGETS = {
    { match = "gslapper", kind = "process", profiles = { "light", "heavy" } },
    { match = "spotifyd.service", kind = "user-service", profiles = { "light", "heavy" } },
    { match = "adb", kind = "process", profiles = { "light", "heavy" } },
    { match = "kokoro-tts", kind = "container", profiles = { "light", "heavy" } },
}

local function validEntry(e)
    return type(e) == "table"
        and type(e.match) == "string" and e.match ~= ""
        and VALID_KINDS[e.kind]
        and type(e.profiles) == "table" and #e.profiles > 0
end

local function copyTargets(list)
    local out = {}
    for _, e in ipairs(list) do
        out[#out + 1] = { match = e.match, kind = e.kind, profiles = { table.unpack(e.profiles) } }
    end
    return out
end

function M.parseTargets(raw)
    if type(raw) == "string" and raw ~= "" and noctalia.json and noctalia.json.decode then
        local decoded = noctalia.json.decode(raw)
        if type(decoded) == "table" then
            local out = {}
            for _, e in ipairs(decoded) do
                if validEntry(e) then out[#out + 1] = e end
            end
            if #out > 0 then return out end
        end
    end
    return copyTargets(M.DEFAULT_TARGETS)
end

function M.targetsForProfile(targets, profile)
    local out = {}
    for _, t in ipairs(targets) do
        for _, p in ipairs(t.profiles) do
            if p == profile then out[#out + 1] = t break end
        end
    end
    return out
end
```

**Step 4: Run test to verify it passes**

Run: `lua tests/targets.lua`
Expected: `targets: passed`

**Step 5: Commit**

```bash
git add gamermode/service.luau tests/targets.lua
git commit -m "feat: kill-list parsing with defaults and profile filtering"
```

---

### Task 4: Snapshot engine — build, persist, restore-plan

**Files:**
- Modify: `gamermode/service.luau`
- Test: `tests/snapshot.lua`

**Step 1: Write the failing test `tests/snapshot.lua`**

```lua
noctalia = {
    setUpdateInterval = function() end,
    getConfig = function() return nil end,
    state = { get = function() return nil end, set = function() end, watch = function() end },
    runAsync = function() end,
    pluginDataDir = function() return "/tmp/gamermode-test" end,
    json = { encode = function(v) return tostring(v) end },
}

local svc = dofile("gamermode/service.luau")

-- snapshot shape from probe results
local targets = {
    { match = "gslapper", kind = "process", was = "running", pids = { 11, 12 } },
    { match = "spotifyd.service", kind = "user-service", was = "active" },
    { match = "gone.service", kind = "user-service", was = "inactive" },
}
local snap = svc.buildSnapshot("light", "balanced", targets)
assert(snap.version == 1 and snap.profile == "light" and snap.power_profile_before == "balanced", "snapshot header")
assert(#snap.targets == 3, "snapshot targets")

-- restore plan: only was-running AND still-down
local current = { ["gslapper"] = "down", ["spotifyd.service"] = "active", ["gone.service"] = "down" }
local plan = svc.restorePlan(snap, function(match) return current[match] end)
assert(#plan == 1 and plan[1].match == "gslapper", "only was-running + still-down, got " .. #plan)

-- persist round-trip via real fs
os.execute("rm -rf /tmp/gamermode-test && mkdir -p /tmp/gamermode-test")
assert(svc.writeSnapshot(snap), "writeSnapshot")
local loaded = svc.readSnapshot()
assert(loaded and loaded.profile == "light" and #loaded.targets == 3, "readSnapshot round-trip")
svc.deleteSnapshot()
assert(svc.readSnapshot() == nil, "deleted")

-- corrupt file falls back to nil, no crash
local f = assert(io.open("/tmp/gamermode-test/session.json", "w")) f:write("{{{") f:close()
assert(svc.readSnapshot() == nil, "corrupt tolerated")

print("snapshot: passed")
```

**Step 2: Run test to verify it fails**

Run: `lua tests/snapshot.lua`
Expected: FAIL — functions nil

**Step 3: Add to `gamermode/service.luau` (before `return M`)**

```lua
local function snapshotPath()
    local dir = noctalia.pluginDataDir()
    return dir and (dir .. "/session.json") or nil
end

function M.buildSnapshot(profile, powerProfile, probedTargets)
    return { version = 1, profile = profile, power_profile_before = powerProfile, targets = probedTargets }
end

function M.restorePlan(snap, stateOf)
    local plan = {}
    for _, t in ipairs(snap.targets or {}) do
        local wasUp = t.was == "running" or t.was == "active"
        if wasUp and stateOf(t.match) == "down" then
            plan[#plan + 1] = t
        end
    end
    return plan
end

local function serializeValue(v)
    if type(v) == "table" then
        local isArray = #v > 0
        local parts = {}
        if isArray then
            for _, item in ipairs(v) do parts[#parts + 1] = serializeValue(item) end
            return "[" .. table.concat(parts, ",") .. "]"
        end
        for key, item in pairs(v) do
            parts[#parts + 1] = string.format("%q:%s", key, serializeValue(item))
        end
        return "{" .. table.concat(parts, ",") .. "}"
    elseif type(v) == "string" then
        return string.format("%q", v)
    end
    return tostring(v)
end

function M.writeSnapshot(snap)
    local path = snapshotPath()
    if not path then return false end
    local f = io.open(path, "w")
    if not f then return false end
    f:write(serializeValue(snap))
    f:close()
    return true
end

function M.readSnapshot()
    local path = snapshotPath()
    if not path then return nil end
    local f = io.open(path, "r")
    if not f then return nil end
    local body = f:read("*a")
    f:close()
    -- %q writes lua-quoted strings; {[...]} is valid lua table syntax: load it in an empty env
    local ok, snap = pcall(load("return " .. body, "snapshot", "t", {}) or function() end)
    if not ok or type(snap) ~= "table" or snap.version ~= 1 then return nil end
    return snap
end

function M.deleteSnapshot()
    local path = snapshotPath()
    if path then os.remove(path) end
end
```

Note: snapshot is serialized as a Lua table literal (load with empty env — no code execution surface beyond data). If `noctalia.json` decode is available at runtime, swap later; test path must not depend on it.

**Step 4: Run test to verify it passes**

Run: `lua tests/snapshot.lua`
Expected: `snapshot: passed`

**Step 5: Commit**

```bash
git add gamermode/service.luau tests/snapshot.lua
git commit -m "feat: snapshot build, persistence, restore planning"
```

---

### Task 5: Probe/stop/start command construction + state mapping

**Files:**
- Modify: `gamermode/service.luau`
- Test: `tests/commands.lua`

**Step 1: Write the failing test `tests/commands.lua`**

```lua
noctalia = {
    setUpdateInterval = function() end,
    getConfig = function() return nil end,
    state = { get = function() return nil end, set = function() end, watch = function() end },
    runAsync = function() end,
    pluginDataDir = function() return "/tmp/gamermode-test" end,
}

local svc = dofile("gamermode/service.luau")

-- probe commands per kind
assert(svc.probeCmd({ kind = "process", match = "gslapper" }) == "pgrep -x 'gslapper'", "probe process")
assert(svc.probeCmd({ kind = "user-service", match = "a.service" }) == "systemctl --user is-active 'a.service'", "probe user svc")
assert(svc.probeCmd({ kind = "system-service", match = "a.service" }) == "systemctl is-active 'a.service'", "probe system svc")
assert(svc.probeCmd({ kind = "container", match = "x" }) == "docker inspect -f '{{.State.Running}}' 'x'", "probe container")

-- probe output -> was-state
assert(svc.wasState("process", "123\n124") == "running", "pids = running")
assert(svc.wasState("process", "") == "down", "no pids = down")
assert(svc.wasState("user-service", "active") == "active", "active")
assert(svc.wasState("user-service", "inactive") == "down", "inactive maps down")
assert(svc.wasState("container", "true") == "running", "docker true")
assert(svc.wasState("container", "false") == "down", "docker false")

-- stop / start commands
assert(svc.stopCmd({ kind = "process", match = "gslapper" }) == "pkill -x 'gslapper'", "stop process")
assert(svc.stopCmd({ kind = "container", match = "x" }) == "docker stop 'x'", "stop container")
assert(svc.stopCmd({ kind = "user-service", match = "a.service" }) == "systemctl --user stop 'a.service'", "stop user svc")
assert(svc.stopCmd({ kind = "system-service", match = "a.service" }) == "sudo -n systemctl stop 'a.service'", "stop system svc")
assert(svc.startCmd({ kind = "container", match = "x" }) == "docker start 'x'", "start container")
assert(svc.startCmd({ kind = "system-service", match = "a.service" }) == "sudo -n systemctl start 'a.service'", "start system svc")
assert(svc.startCmd({ kind = "process", match = "gslapper" }) == nil, "processes have no generic start")

-- shell quoting safety
assert(svc.probeCmd({ kind = "process", match = "a'b" }):find("'\\''", 1, true), "quotes escaped")

print("commands: passed")
```

**Step 2: Run test to verify it fails**

Run: `lua tests/commands.lua`
Expected: FAIL

**Step 3: Add to `gamermode/service.luau` (before `return M`)**

```lua
local function shellQuote(value)
    return "'" .. tostring(value):gsub("'", "'\\''") .. "'"
end

function M.probeCmd(t)
    if t.kind == "process" then return "pgrep -x " .. shellQuote(t.match) end
    if t.kind == "user-service" then return "systemctl --user is-active " .. shellQuote(t.match) end
    if t.kind == "system-service" then return "systemctl is-active " .. shellQuote(t.match) end
    if t.kind == "container" then return "docker inspect -f '{{.State.Running}}' " .. shellQuote(t.match) end
end

function M.wasState(kind, output)
    output = (output or ""):gsub("%s+$", "")
    if kind == "process" then return output ~= "" and "running" or "down" end
    if kind == "container" then return output == "true" and "running" or "down" end
    return output == "active" and "active" or "down"
end

function M.stopCmd(t)
    if t.kind == "process" then return "pkill -x " .. shellQuote(t.match) end
    if t.kind == "user-service" then return "systemctl --user stop " .. shellQuote(t.match) end
    if t.kind == "system-service" then return "sudo -n systemctl stop " .. shellQuote(t.match) end
    if t.kind == "container" then return "docker stop " .. shellQuote(t.match) end
end

function M.startCmd(t)
    if t.kind == "user-service" then return "systemctl --user start " .. shellQuote(t.match) end
    if t.kind == "system-service" then return "sudo -n systemctl start " .. shellQuote(t.match) end
    if t.kind == "container" then return "docker start " .. shellQuote(t.match) end
    -- ponytail: no generic process restart; document per-user relaunch in README
end
```

**Step 4: Run test to verify it passes**

Run: `lua tests/commands.lua`
Expected: `commands: passed`

**Step 5: Commit**

```bash
git add gamermode/service.luau tests/commands.lua
git commit -m "feat: probe/stop/start command construction with shell quoting"
```

---

### Task 6: Service runtime — poll loop, state keys, command handler

**Files:**
- Modify: `gamermode/service.luau`
- Test: `tests/runtime.lua`

**Step 1: Write the failing test `tests/runtime.lua`**

Verifies published state shapes using a scripted `runAsync` mock:

```lua
local published = {}
local commands = {}
noctalia = {
    setUpdateInterval = function() end,
    getConfig = function(key)
        return ({ profile = "light", auto_performance = true, poll_interval = "3" })[key]
    end,
    state = {
        get = function() return nil end,
        set = function(k, v) published[k] = v end,
        watch = function(k, fn) end,
    },
    runAsync = function(cmd, cb)
        commands[#commands + 1] = cmd
        if cb then cb(0, "") end
    end,
    pluginDataDir = function() return "/tmp/gamermode-test" end,
    nowMs = function() return 0 end,
    tr = function(k) return k end,
}

local svc = dofile("gamermode/service.luau")
svc.init()

-- game_mode state published disabled without session file
os.remove("/tmp/gamermode-test/session.json")
svc.publishGameMode()
assert(published.game_mode and published.game_mode.enabled == false, "disabled without snapshot")

-- toggle on: builds snapshot, runs probes+stops, publishes enabled
svc.toggle()
assert(published.game_mode.enabled == true, "enabled after toggle")
local foundProbe = false
for _, c in ipairs(commands) do if c:find("pgrep", 1, true) then foundProbe = true end end
assert(foundProbe, "probe commands ran")

-- toggle off: restores, deletes snapshot, publishes disabled
svc.toggle()
assert(published.game_mode.enabled == false, "disabled after second toggle")
assert(io.open("/tmp/gamermode-test/session.json", "r") == nil, "snapshot deleted")

print("runtime: passed")
```

**Step 2: Run test to verify it fails**

Run: `lua tests/runtime.lua`
Expected: FAIL — `init` nil

**Step 3: Add runtime wiring to `gamermode/service.luau` (before `return M`)**

```lua
local lastStat = nil
local gpuKind = nil -- nil = unchecked, "nvidia", "generic", "none"

local function publishMetrics(m)
    noctalia.state.set("metrics", m)
end

function M.publishGameMode()
    local snap = M.readSnapshot()
    local suspended = {}
    if snap then
        for _, t in ipairs(snap.targets) do
            if t.was == "running" or t.was == "active" then
                suspended[#suspended + 1] = { match = t.match, kind = t.kind }
            end
        end
    end
    noctalia.state.set("game_mode", {
        enabled = snap ~= nil,
        profile = snap and snap.profile or noctalia.getConfig("profile") or "light",
        suspended = suspended,
    })
end

local function detectGpu(cb)
    noctalia.runAsync("command -v nvidia-smi >/dev/null && nvidia-smi -L >/dev/null 2>&1 && echo nvidia || (ls /sys/class/drm/card*/device/gpu_busy_percent >/dev/null 2>&1 && echo generic || echo none)", function(_, out)
        gpuKind = (out or ""):gsub("%s+", "")
        cb(gpuKind)
    end)
end

function M.pollMetrics()
    -- CPU
    local f = io.open("/proc/stat", "r")
    if f then
        local cur = M.parseProcStat(f:read("*a") or "")
        f:close()
        local cpuPerc = M.cpuPercent(lastStat, cur)
        lastStat = cur
        local m = { cpuPerc = cpuPerc }
        local mf = io.open("/proc/meminfo", "r")
        if mf then
            local mem = M.parseMemInfo(mf:read("*a") or "")
            mf:close()
            if mem then m.memUsed = mem.used m.memTotal = mem.total end
        end
        if gpuKind == "nvidia" then
            noctalia.runAsync("nvidia-smi --query-gpu=utilization.gpu,temperature.gpu,memory.used,memory.total --format=csv,noheader,nounits", function(_, out)
                local gpu = M.parseNvidiaSmi(out or "")
                if gpu then
                    m.gpuUtil = gpu.util m.gpuTemp = gpu.temp
                    m.vramUsed = gpu.vramUsed m.vramTotal = gpu.vramTotal
                end
                publishMetrics(m)
            end)
        else
            publishMetrics(m)
        end
    end
end

function M.toggle()
    local snap = M.readSnapshot()
    if snap then
        M.disable(snap)
    else
        M.enable()
    end
    M.publishGameMode()
end

function M.enable()
    local profile = noctalia.getConfig("profile") or "light"
    local targets = M.targetsForProfile(M.parseTargets(noctalia.getConfig("targets")), profile)
    local probed = {}
    local pending = #targets
    local powerBefore = "balanced"
    local function finish()
        for _, t in ipairs(probed) do
            local cmd = M.stopCmd(t)
            if cmd and (t.was == "running" or t.was == "active") then
                noctalia.runAsync(cmd, function() end)
            end
        end
        if noctalia.getConfig("auto_performance") then
            noctalia.runAsync("powerprofilesctl set performance", function() end)
        end
        M.writeSnapshot(M.buildSnapshot(profile, powerBefore, probed))
        M.publishGameMode()
    end
    if pending == 0 then finish() return end
    for _, t in ipairs(targets) do
        noctalia.runAsync(M.probeCmd(t), function(_, out)
            local entry = { match = t.match, kind = t.kind, was = M.wasState(t.kind, out) }
            probed[#probed + 1] = entry
            pending = pending - 1
            if pending == 0 then finish() end
        end)
    end
end

function M.disable(snap)
    local plan = M.restorePlan(snap, function(match)
        -- still-down check happens live per target below
        return "down"
    end)
    for _, t in ipairs(plan) do
        noctalia.runAsync(M.probeCmd(t), function(_, out)
            if M.wasState(t.kind, out) == "down" then
                local cmd = M.startCmd(t)
                if cmd then noctalia.runAsync(cmd, function() end) end
            end
        end)
    end
    if noctalia.getConfig("auto_performance") and snap.power_profile_before then
        noctalia.runAsync("powerprofilesctl set " .. snap.power_profile_before, function() end)
    end
    M.deleteSnapshot()
end

function M.init()
    os.execute("mkdir -p '" .. (noctalia.pluginDataDir() or "/tmp") .. "'")
    M.publishGameMode()
    detectGpu(function()
        M.pollMetrics()
    end)
    local interval = tonumber(noctalia.getConfig("poll_interval")) or 3
    noctalia.setUpdateInterval(interval * 1000)
end

-- plugin callbacks
function onTick() M.pollMetrics() end
function onIpc(event)
    if event == "toggle" then M.toggle() end
end
noctalia.state.watch("command", function(cmd)
    if type(cmd) == "table" and cmd.action == "toggle" then M.toggle() end
end)
```

**Step 4: Run test to verify it passes**

Run: `lua tests/runtime.lua`
Expected: `runtime: passed` (note: `onIpc`/`setUpdateInterval` names verified against shell docs during implementation; adjust callback name if shell uses a different tick name)

**Step 5: Run all tests**

Run: `lua tests/metrics.lua && lua tests/targets.lua && lua tests/snapshot.lua && lua tests/commands.lua && lua tests/runtime.lua && sh tests/scaffold.sh`
Expected: all pass

**Step 6: Commit**

```bash
git add gamermode/service.luau tests/runtime.lua
git commit -m "feat: service runtime with poll loop and toggle flow"
```

---

### Task 7: widget.luau

**Files:**
- Create: `gamermode/widget.luau`
- Test: `tests/widget.lua`

**Step 1: Write the failing test `tests/widget.lua`**

```lua
local glyphSet, tooltipSet = nil, nil
barWidget = {
    setGlyph = function(g) glyphSet = g end,
    setTooltip = function(t) tooltipSet = t end,
}
local watches = {}
noctalia = {
    getConfig = function(k) return ({ glyph = "gamepad", click_action = "toggle" })[k] end,
    state = {
        get = function(k) return ({ game_mode = { enabled = false } })[k] end,
        set = function() end,
        watch = function(k, fn) watches[k] = fn end,
    },
    togglePanel = function() end,
    tr = function(k) return k end,
}

local w = dofile("gamermode/widget.luau")
assert(glyphSet == "gamepad", "glyph set")
assert(type(w.formatTooltip) == "function", "formatTooltip exposed")

local tip = w.formatTooltip({ cpuPerc = 0.25, memUsed = 11468800, memTotal = 32768000, gpuUtil = 18, gpuTemp = 61, vramUsed = 2600, vramTotal = 8188 }, true, { enabled = false })
assert(tip:find("25%%") and tip:find("61"), "tooltip has cpu% and gpu temp, got: " .. tip)
local tipNoTemps = w.formatTooltip({ cpuPerc = 0.25, memUsed = 1, memTotal = 2 }, false, { enabled = false })
assert(not tipNoTemps:find("C"), "temps hidden when show_temps=false")

-- click behavior
local toggled = false
noctalia.state.set = function(k, v) if k == "command" then toggled = true end end
w.onClick()
assert(toggled, "click sends toggle command when click_action=toggle")

print("widget: passed")
```

**Step 2: Run test to verify it fails**

Run: `lua tests/widget.lua`
Expected: FAIL

**Step 3: Write `gamermode/widget.luau`**

```lua
--!nonstrict

local PANEL_ID = "nomadcxx/gamermode:main"
local gameMode = noctalia.state.get("game_mode") or { enabled = false }
local metrics = noctalia.state.get("metrics") or {}

local M = {}

local function mibToGib(kib)
    return string.format("%.1f", (kib or 0) / 1048576)
end

function M.formatTooltip(m, showTemps, gm)
    local parts = {
        string.format("CPU %d%%", math.floor((m.cpuPerc or 0) * 100 + 0.5)),
        string.format("RAM %sG", mibToGib(m.memUsed)),
    }
    if m.gpuUtil then
        local gpu = string.format("GPU %d%%", m.gpuUtil)
        if showTemps and m.gpuTemp then gpu = gpu .. string.format(" %dC", m.gpuTemp) end
        parts[#parts + 1] = gpu
    end
    if m.vramUsed then
        parts[#parts + 1] = string.format("VRAM %.1fG", m.vramUsed / 1024)
    end
    local label = table.concat(parts, " | ")
    if gm and gm.enabled then label = "[ON] " .. label end
    return label
end

local function render()
    barWidget.setGlyph(noctalia.getConfig("glyph") or "gamepad")
    barWidget.setTooltip(M.formatTooltip(metrics, noctalia.getConfig("show_temps") ~= false, gameMode))
end

function M.onClick()
    if (noctalia.getConfig("click_action") or "toggle") == "toggle" then
        noctalia.state.set("command", { action = "toggle" })
    else
        noctalia.togglePanel(PANEL_ID)
    end
end

function M.onConfigChanged() render() end

noctalia.state.watch("metrics", function(v) metrics = v or {} render() end)
noctalia.state.watch("game_mode", function(v) gameMode = v or { enabled = false } render() end)

-- widget entry points must be globals for the shell
function onClick() M.onClick() end
function onConfigChanged() M.onConfigChanged() end

render()
return M
```

**Step 4: Run test to verify it passes**

Run: `lua tests/widget.lua`
Expected: `widget: passed`

**Step 5: Commit**

```bash
git add gamermode/widget.luau tests/widget.lua
git commit -m "feat: bar widget with live tooltip and click toggle"
```

---

### Task 8: panel.luau

**Files:**
- Create: `gamermode/panel.luau`
- Test: `tests/panel.lua`

**Step 1: Write the failing test `tests/panel.lua`**

Panel logic is mostly declarative `ui.*` calls — test the pure helpers:

```lua
ui = setmetatable({}, { __index = function(_, name) return function(spec) return { _kind = name, spec = spec } end end })
noctalia = {
    getConfig = function(k) return ({ profile = "light", auto_performance = true, show_temps = true })[k] end,
    state = {
        get = function(k)
            return ({
                metrics = { cpuPerc = 0.5, memUsed = 16777216, memTotal = 33554432, gpuUtil = 40, gpuTemp = 60, vramUsed = 4096, vramTotal = 8188 },
                game_mode = { enabled = true, profile = "light", suspended = { { match = "gslapper", kind = "process" } } },
            })[k]
        end,
        set = function() end,
        watch = function() end,
    },
    togglePanel = function() end,
    tr = function(k) return k end,
}

local p = dofile("gamermode/panel.luau")
assert(type(p.buildRows) == "function", "buildRows exposed")
local rows = p.buildRows(noctalia.state.get("metrics"), true)
assert(#rows == 4, "4 metric rows (cpu/ram/gpu/vram), got " .. #rows)
assert(rows[1].label:find("CPU") and math.abs(rows[1].progress - 0.5) < 0.001, "cpu row")

local suspendedLines = p.suspendedLines(noctalia.state.get("game_mode"))
assert(#suspendedLines == 1 and suspendedLines[1]:find("gslapper"), "suspended listed")

local empty = p.suspendedLines({ enabled = false, suspended = {} })
assert(#empty == 0, "empty when disabled")

print("panel: passed")
```

**Step 2: Run test to verify it fails**

Run: `lua tests/panel.lua`
Expected: FAIL

**Step 3: Write `gamermode/panel.luau`**

```lua
--!nonstrict

local metrics = noctalia.state.get("metrics") or {}
local gameMode = noctalia.state.get("game_mode") or { enabled = false, suspended = {} }
local render

local M = {}

local function tr(key) return noctalia.tr(key) end

function M.buildRows(m, showTemps)
    local rows = {}
    rows[#rows + 1] = { label = "CPU", progress = m.cpuPerc or 0,
        detail = string.format("%d%%", math.floor((m.cpuPerc or 0) * 100 + 0.5)) }
    local ramDetail = string.format("%.1f / %.0f GiB", (m.memUsed or 0) / 1048576, (m.memTotal or 0) / 1048576)
    rows[#rows + 1] = { label = "RAM", progress = (m.memTotal or 0) > 0 and (m.memUsed / m.memTotal) or 0, detail = ramDetail }
    if m.gpuUtil then
        local detail = string.format("%d%%", m.gpuUtil)
        if showTemps and m.gpuTemp then detail = detail .. string.format("  %d C", m.gpuTemp) end
        rows[#rows + 1] = { label = "GPU", progress = (m.gpuUtil or 0) / 100, detail = detail }
    end
    if m.vramUsed then
        rows[#rows + 1] = { label = "VRAM", progress = (m.vramTotal or 0) > 0 and (m.vramUsed / m.vramTotal) or 0,
            detail = string.format("%.1f / %.0f GiB", m.vramUsed / 1024, (m.vramTotal or 0) / 1024) }
    end
    return rows
end

function M.suspendedLines(gm)
    local lines = {}
    for _, t in ipairs((gm and gm.suspended) or {}) do
        lines[#lines + 1] = string.format("%s (%s)", t.match, t.kind)
    end
    return lines
end

local function metricRow(row)
    return ui.column({ gap = 4 }, {
        ui.row({ align = "center", gap = 8 }, {
            ui.label({ text = row.label, color = "on_surface_variant", width = 52 }),
            ui.label({ text = row.detail, color = "on_surface_variant", fontSize = 11, flexGrow = 1, align = "end" }),
        }),
        ui.progress({ height = 4, progress = row.progress, fill = "primary", track = "surface_variant", radius = 2 }),
    })
end

local function body()
    local showTemps = noctalia.getConfig("show_temps") ~= false
    local children = {
        ui.row({ align = "center", gap = 8 }, {
            ui.glyph({ name = "gamepad" }),
            ui.label({ text = tr("panel.title"), fontSize = 16, flexGrow = 1 }),
            ui.button({
                text = gameMode.enabled and tr("panel.disable") or tr("panel.enable"),
                color = gameMode.enabled and "primary" or "surface_variant",
                onClick = function()
                    noctalia.state.set("command", { action = "toggle" })
                end,
            }),
        }),
        ui.label({ text = tr("panel.performance"), color = "on_surface_variant", fontSize = 12 }),
    }
    for _, row in ipairs(M.buildRows(metrics, showTemps)) do
        children[#children + 1] = metricRow(row)
    end
    if gameMode.enabled then
        children[#children + 1] = ui.label({ text = tr("panel.suspended"), color = "on_surface_variant", fontSize = 12 })
        local lines = M.suspendedLines(gameMode)
        if #lines == 0 then
            children[#children + 1] = ui.label({ text = tr("panel.nothing_suspended"), fontSize = 11 })
        end
        for _, line in ipairs(lines) do
            children[#children + 1] = ui.label({ text = line, fontSize = 11 })
        end
    end
    return ui.scroll({ flexGrow = 1 }, ui.column({ gap = 10 }, children))
end

local function renderPanel()
    return ui.column({ gap = 10, padding = 16 }, { body() })
end

render = function()
    panel.render(renderPanel())
end

noctalia.state.watch("metrics", function(v) metrics = v or {} render() end)
noctalia.state.watch("game_mode", function(v) gameMode = v or { enabled = false, suspended = {} } render() end)

function onOpen() render() end

return M
```

Note: exact `ui.*` prop names (`width`, `padding`, `onClick` on button, `panel.render`) must be checked against the shell's luau UI bridge during implementation; gslapper `panel.luau` is the reference for correct prop names.

**Step 4: Run test to verify it passes**

Run: `lua tests/panel.lua`
Expected: `panel: passed`

**Step 5: Commit**

```bash
git add gamermode/panel.luau tests/panel.lua
git commit -m "feat: metrics panel with toggle and suspended list"
```

---

### Task 9: README, catalog, full test pass, manual checklist

**Files:**
- Create: `README.md`
- Create: `catalog.toml` (copy shape from `/home/nomadx/noctalia-gslapper/catalog.toml`)

**Step 1: Write `README.md`**

Sections: what it does, screenshot placeholder, install (plugin source URL), settings table,
targets JSON format with examples, **sudoers snippet for system services**:

```
# /etc/sudoers.d/gamermode (visudo)
youruser ALL=(ALL) NOPASSWD: /usr/bin/systemctl stop *, /usr/bin/systemctl start *
```

Restore semantics explanation, limitations (no process auto-restart, no hover panel yet).

**Step 2: Write `catalog.toml`** mirroring gslapper's fields.

**Step 3: Full test pass**

Run: `for t in tests/*.lua; do lua "$t" || exit 1; done; for t in tests/*.sh; do sh "$t" || exit 1; done`
Expected: all pass

**Step 4: Manual verification checklist (run on real shell)**

- Install plugin from local source, enable
- Bar shows glyph; tooltip updates every ~3s with live stats
- Left-click toggles: verify with `systemctl --user is-active spotifyd.service`, `pgrep gslapper`, `docker ps` before/after
- Enable, reload quickshell, verify panel still shows enabled + suspended list
- Disable, verify only previously-running targets restarted
- Enable with a target already stopped, disable, verify it was NOT started
- Malformed `targets` JSON: verify defaults used + no crash
- `sudo -n` absent for a system-service target: verify skip + no password prompt

**Step 5: Commit**

```bash
git add README.md catalog.toml
git commit -m "docs: readme with sudoers setup and restore semantics"
```

---

## Open verification items (check during implementation, not blockers)

1. Does widget API support `onRightClick`? If yes, wire right-click = open panel.
2. Exact tick callback name for `setUpdateInterval` (`onTick` assumed).
3. `noctalia.json.decode` availability — snapshot currently uses Lua-literal serialization.
4. Exact `ui.*` prop names — mirror gslapper `panel.luau`.
5. Notification/toast API for enable/disable feedback (gslapper has NOTIFICATION_TITLE — find its notify call and reuse).
