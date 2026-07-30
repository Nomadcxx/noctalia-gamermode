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

    -- Service targets are named with their unit suffix for clarity.
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
    "spotify", "spotifyd", "spotifyd.service", "mpd", "mpv", "vlc",
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

-- v1 defaults specific to one developer's machine are gone or corrected.
assert(not byMatch["kokoro-tts"], "machine-specific default removed")
assert(byMatch["gslapper"] and svc.actionOf(byMatch["gslapper"]) == "freeze", "gslapper now freezes")
assert(byMatch["adb"] and svc.actionOf(byMatch["adb"]) == "freeze", "adb now freezes")

-- Every category the spec promises is represented.
for _, expected in ipairs({
    "hyprpaper", "qbittorrent", "sabnzbd", "syncthing", "restic", "baloo_file",
    "plocate-updatedb.timer", "smartd.timer", "packagekit.service", "clamd.service",
    "brave", "code", "rust-analyzer", "cargo", "sonarr.service", "jellyfin.service",
    "elasticsearch.service",
}) do
    assert(byMatch[expected], "expected default missing: " .. expected)
end

print("defaults: passed")
