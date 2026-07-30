-- The never-touch denylist: entries that would kill the session, the audio stack, the
-- network or the game itself must be impossible to act on.
package.path = "./tests/?.lua;" .. package.path
local helpers = require("helpers")

local mock = helpers.newNoctalia()
local svc = dofile("gamer-mode/service.luau")

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
    if line:find("niri", 1, true) or line:find("protected", 1, true) then
        logged = true
    end
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

-- No default target may itself be protected.
for _, entry in ipairs(svc.DEFAULT_TARGETS) do
    assert(not svc.isDenied(entry.match), "default target must not be protected: " .. entry.match)
end

print("denylist: passed")
