--!nonstrict
--
-- Gamer Mode service: publishes system metrics and owns the snapshot-based game-mode
-- engine. The panel and widget are thin readers of `noctalia.state`; every mutation
-- arrives here as a `command` state write.
--
-- Luau's sandbox gives plugins no `io`, no `os.execute`/`os.remove` and no `load`, so
-- all filesystem access goes through noctalia.readFile/writeFile/removeFile/mkdirAll
-- and the snapshot is stored as JSON via noctalia.json.

local M = {}

local BYTES_PER_MIB = 1048576

local function clampFraction(percent)
    local value = tonumber(percent)
    if not value then
        return 0
    end
    return math.max(0, math.min(1, value / 100))
end

-- normalize converts a noctalia.systemStats() sample into the published `metrics`
-- shape: percentages as 0-1 fractions, memory in MiB.
--
-- Optional readings stay nil rather than becoming zero, so the UI can say "unsupported"
-- instead of drawing an empty bar that looks like a real 0% reading.
function M.normalize(raw)
    if type(raw) ~= "table" then
        return nil
    end

    local cpu = type(raw.cpu) == "table" and raw.cpu or {}
    local ram = type(raw.ram) == "table" and raw.ram or {}
    local gpu = type(raw.gpu) == "table" and raw.gpu or {}

    local metrics = {
        cpuPerc = clampFraction(cpu.usagePercent),
        cpuTemp = tonumber(cpu.tempC),
        memPerc = clampFraction(ram.usagePercent),
        memUsedMb = tonumber(ram.usedMb) or 0,
        memTotalMb = tonumber(ram.totalMb) or 0,
        gpuAvailable = false,
    }

    local gpuPercent = tonumber(gpu.usagePercent)
    if gpuPercent then
        metrics.gpuPerc = clampFraction(gpuPercent)
        metrics.gpuAvailable = true
    end
    local gpuTemp = tonumber(gpu.tempC)
    if gpuTemp then
        metrics.gpuTemp = gpuTemp
        metrics.gpuAvailable = true
    end

    -- VRAM needs both halves: a used figure without a total cannot be drawn as a ratio.
    local vramUsed = tonumber(gpu.vramUsedBytes)
    local vramTotal = tonumber(gpu.vramTotalBytes)
    if vramUsed and vramTotal and vramTotal > 0 then
        metrics.vramUsedMb = vramUsed / BYTES_PER_MIB
        metrics.vramTotalMb = vramTotal / BYTES_PER_MIB
        metrics.vramPerc = math.max(0, math.min(1, vramUsed / vramTotal))
        metrics.gpuAvailable = true
    end

    return metrics
end

-- ── suspend targets ──

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

local VALID_ACTIONS = { stop = true, freeze = true }

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

local function processes(names, profiles, out)
    for _, name in ipairs(names) do
        -- Always freeze: a bare process has no argv to relaunch from, so stopping one is
        -- unrecoverable.
        out[#out + 1] = { match = name, kind = "process", action = "freeze", profiles = profiles }
    end
    return out
end

local function units(names, kind, profiles, out)
    for _, name in ipairs(names) do
        out[#out + 1] = { match = name, kind = kind, action = "stop", profiles = profiles }
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

-- Every match string is interpolated into a shell command, so control characters are
-- refused outright rather than escaped.
local function validateShellValue(value)
    if type(value) ~= "string" or value == "" or value:find("[\n\r%z]") then
        return nil
    end
    return value
end

M.validateShellValue = validateShellValue

-- validEntry returns ok plus a human reason, so parseTargets can tell the user which of
-- their entries was dropped and why rather than only how many.
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
    -- `systemctl is-active fstrim` resolves to fstrim.service, so a timer target that does
    -- not name its unit would silently act on the wrong one.
    if TIMER_KINDS[entry.kind] and entry.match:lower():sub(-6) ~= ".timer" then
        return false, "timer target '" .. entry.match .. "' must name a .timer unit"
    end
    if entry.action ~= nil and not VALID_ACTIONS[entry.action] then
        return false, "unknown action " .. tostring(entry.action)
    end
    if entry.action == "freeze" and TIMER_KINDS[entry.kind] then
        return false, "a timer cannot be frozen, only stopped"
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

local function copyTargets(list)
    local out = {}
    for index, entry in ipairs(list) do
        local profiles = {}
        for profileIndex, profile in ipairs(entry.profiles) do
            profiles[profileIndex] = profile
        end
        out[index] = {
            match = entry.match,
            kind = entry.kind,
            action = entry.action,
            profiles = profiles,
        }
    end
    return out
end

-- parseTargets decodes the `targets` setting, dropping individual invalid entries.
-- An unset, unparseable or wholly invalid setting falls back to DEFAULT_TARGETS so a
-- typo can never leave gamer mode with an empty kill list and no explanation.
function M.parseTargets(raw)
    if type(raw) == "string" and raw ~= "" then
        local decoded, decodeError = noctalia.json.decode(raw)
        if type(decoded) ~= "table" then
            noctalia.log("gamermode: ignoring invalid targets setting: " .. tostring(decodeError or "not a JSON array"))
        else
            local out = {}
            for _, entry in ipairs(decoded) do
                local ok, reason = validEntry(entry)
                if ok then
                    out[#out + 1] = {
                        match = entry.match,
                        kind = entry.kind,
                        action = entry.action,
                        profiles = entry.profiles,
                    }
                else
                    noctalia.log("gamermode: dropped target: " .. tostring(reason))
                end
            end
            if #out > 0 then
                -- Allowed, but the user should know it is a one-way trip.
                for _, entry in ipairs(out) do
                    if entry.kind == "process" and M.actionOf(entry) == "stop" then
                        noctalia.log(
                            "gamermode: '" .. entry.match .. "' is a process with action=stop, which is "
                                .. "unrecoverable -- a bare process has no argv to relaunch from. "
                                .. "Use action=freeze, or target the unit that supervises it."
                        )
                    end
                end
                return copyTargets(out)
            end
            noctalia.log("gamermode: targets setting had no usable entries, using defaults")
        end
    end
    return copyTargets(M.DEFAULT_TARGETS)
end

function M.targetsForProfile(targets, profile)
    local out = {}
    for _, target in ipairs(targets) do
        for _, tagged in ipairs(target.profiles) do
            if tagged == profile then
                out[#out + 1] = target
                break
            end
        end
    end
    return out
end

-- ── shell commands per target kind ──

-- shellQuote returns nil for anything that cannot be represented safely, and every
-- command builder propagates that nil rather than emitting a half-quoted command.
local function shellQuote(value)
    if not validateShellValue(value) then
        return nil
    end
    return "'" .. value:gsub("'", "'\\''") .. "'"
end

M.shellQuote = shellQuote

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

-- Probes read state only, so none of them needs elevation -- `systemctl is-active`
-- works unprivileged even for system units.
function M.probeCmd(target)
    local match = safeMatch(target)
    if not match then
        return nil
    end
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
end

function M.stopCmd(target)
    local match = safeMatch(target)
    if not match then
        return nil
    end
    if target.kind == "process" then
        return "pkill -x " .. match
    elseif target.kind == "user-service" or target.kind == "user-timer" then
        return "systemctl --user stop " .. match
    elseif target.kind == "system-service" or target.kind == "system-timer" then
        -- `-n` fails immediately instead of prompting: a bar click must never block on a
        -- password. Without a NOPASSWD rule the target is skipped and logged.
        return "sudo -n systemctl stop " .. match
    elseif target.kind == "container" then
        return "docker stop " .. match
    end
    return nil
end

-- Processes have no generic start: a bare process name carries no argv, environment or
-- working directory, so gamer mode cannot honestly relaunch one. Users who need a
-- process brought back should target the unit that supervises it instead.
function M.startCmd(target)
    local match = safeMatch(target)
    if not match then
        return nil
    end
    if target.kind == "user-service" or target.kind == "user-timer" then
        return "systemctl --user start " .. match
    elseif target.kind == "system-service" or target.kind == "system-timer" then
        return "sudo -n systemctl start " .. match
    elseif target.kind == "container" then
        return "docker start " .. match
    end
    return nil
end

-- actionOf normalises the optional `action` field. Absent means "stop", which keeps every
-- pre-existing config and session file meaning exactly what it did before.
function M.actionOf(target)
    return target.action == "freeze" and "freeze" or "stop"
end

-- freeze suspends a target in place: SIGSTOP for processes and units, docker pause for
-- containers. Unlike stop it is perfectly reversible and loses no state, which makes it
-- the right action for anything the user might return to -- a browser, an editor, an
-- animated wallpaper daemon.
--
-- renice was measured and rejected as the reversible option: with RLIMIT_NICE=0 an
-- unprivileged process can lower priority but never raise it back, so it would
-- permanently degrade anything it touched.
function M.freezeCmd(target)
    local match = safeMatch(target)
    if not match then
        return nil
    end
    if target.kind == "process" then
        return "pkill -STOP -x " .. match
    elseif target.kind == "user-service" then
        -- --kill-whom=all is explicit because `systemctl kill --help` does not state its
        -- default, and freezing a unit must reach every process in its cgroup.
        return "systemctl --user kill --kill-whom=all -s SIGSTOP " .. match
    elseif target.kind == "system-service" then
        return "sudo -n systemctl kill --kill-whom=all -s SIGSTOP " .. match
    elseif target.kind == "container" then
        -- docker pause is the cgroup freezer: an exact match for freeze semantics.
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

-- wasState maps probe stdout to the state recorded in the snapshot. Only "running" and
-- "active" count as up; everything else -- including transitional states and any output
-- that could not be read -- is "down", so nothing gets restarted on a guess.
function M.wasState(kind, output)
    local text = (tostring(output or "")):gsub("%s+", "")
    if kind == "process" then
        return text ~= "" and "running" or "down"
    elseif kind == "container" then
        return text == "true" and "running" or "down"
    end
    return text == "active" and "active" or "down"
end

-- ── session snapshot ──

local SNAPSHOT_VERSION = 1
local UP_STATES = { running = true, active = true }

local function snapshotPath()
    local directory = noctalia.pluginDataDir()
    if not directory then
        return nil
    end
    return directory .. "/session.json"
end

-- The kernel boot id changes on every boot, which makes it an exact staleness marker for a
-- session file. More reliable than inferring staleness from live state: a frozen process
-- still appears in pgrep, so "is everything running again?" false-positives on every freeze
-- target.
function M.currentBootId()
    local contents = noctalia.readFile("/proc/sys/kernel/random/boot_id")
    if not contents then
        return nil
    end
    local id = contents:gsub("%s+", "")
    return id ~= "" and id or nil
end

function M.buildSnapshot(profile, powerProfileBefore, probedTargets)
    return {
        version = SNAPSHOT_VERSION,
        profile = profile,
        power_profile_before = powerProfileBefore,
        boot_id = M.currentBootId(),
        targets = probedTargets,
    }
end

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

local function validSnapshotTarget(entry)
    return type(entry) == "table"
        and validateShellValue(entry.match) ~= nil
        and VALID_KINDS[entry.kind] ~= nil
        and type(entry.was) == "string"
        and (entry.action == nil or VALID_ACTIONS[entry.action] == true)
end

function M.writeSnapshot(snap)
    local path = snapshotPath()
    if not path then
        noctalia.log("gamermode: no plugin data dir, cannot persist the session")
        return false
    end

    local encoded, encodeError = noctalia.json.encode(snap)
    if not encoded then
        noctalia.log("gamermode: could not encode the session: " .. tostring(encodeError))
        return false
    end

    noctalia.mkdirAll(noctalia.pluginDataDir())
    -- Write-then-rename: a shell crash mid-write must not leave a half-written session
    -- that would be read back as "no session" while targets are still suspended.
    local temporary = path .. ".tmp"
    if not noctalia.writeFile(temporary, encoded) then
        noctalia.log("gamermode: could not write the session file")
        return false
    end
    if not noctalia.renameFile(temporary, path) then
        noctalia.removeFile(temporary)
        noctalia.log("gamermode: could not replace the session file")
        return false
    end
    return true
end

-- readSnapshot returns nil for anything it cannot trust. Callers treat nil as "gamer
-- mode is off", which is the safe reading: it never invents targets to restart.
function M.readSnapshot()
    local path = snapshotPath()
    if not path then
        return nil
    end
    local contents = noctalia.readFile(path)
    if not contents then
        return nil
    end

    local decoded, decodeError = noctalia.json.decode(contents)
    if type(decoded) ~= "table" then
        noctalia.log("gamermode: ignoring unreadable session file: " .. tostring(decodeError or "not an object"))
        return nil
    end
    if decoded.version ~= SNAPSHOT_VERSION then
        noctalia.log("gamermode: ignoring session file with version " .. tostring(decoded.version))
        return nil
    end
    if type(decoded.targets) ~= "table" then
        noctalia.log("gamermode: ignoring session file without a target list")
        return nil
    end

    -- Keep the entries that are still usable rather than discarding the whole session:
    -- dropping it would report gamer mode as off while targets stay suspended.
    local targets = {}
    local dropped = 0
    for _, entry in ipairs(decoded.targets) do
        if validSnapshotTarget(entry) then
            targets[#targets + 1] = {
                match = entry.match,
                kind = entry.kind,
                action = entry.action,
                was = entry.was,
            }
        else
            dropped = dropped + 1
        end
    end
    if dropped > 0 then
        noctalia.log("gamermode: dropped " .. dropped .. " unusable entries from the session file")
    end

    return {
        version = decoded.version,
        profile = type(decoded.profile) == "string" and decoded.profile or "light",
        power_profile_before = type(decoded.power_profile_before) == "string" and decoded.power_profile_before or nil,
        boot_id = type(decoded.boot_id) == "string" and decoded.boot_id or nil,
        targets = targets,
    }
end

function M.deleteSnapshot()
    local path = snapshotPath()
    if path then
        noctalia.removeFile(path)
    end
end

-- ── runtime ──

local COMMAND_TIMEOUT_MS = 10000
local DEFAULT_POLL_SECONDS = 3

local busy = false
local lastHandledNonce = 0
local powerState = { available = false, profiles = {} }

local function trim(value)
    return (tostring(value or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

-- run always invokes `callback` exactly once. A command that could not be built or
-- could not be started yields nil, which every caller reads as "state unknown" -- so a
-- busy shell degrades into doing nothing rather than into a wrong decision.
local function run(command, callback)
    if not command then
        callback(nil)
        return
    end
    local started = noctalia.runAsync(command, callback, COMMAND_TIMEOUT_MS)
    if not started then
        noctalia.log("gamermode: could not start command: " .. command)
        callback(nil)
    end
end

local function succeeded(result)
    return result ~= nil and result.exitCode == 0
end

local function describeFailure(result)
    if result == nil then
        return "command did not start"
    end
    local stderr = trim(result.stderr)
    if stderr ~= "" then
        return stderr
    end
    if result.timedOut then
        return "timed out"
    end
    return "exit code " .. tostring(result.exitCode)
end

local VALID_PROFILES = { light = true, heavy = true }

local function configuredProfile()
    local profile = noctalia.getConfig("profile")
    return profile == "heavy" and "heavy" or "light"
end

-- resolveProfile lets a command name the profile to apply for one session. The panel needs
-- this because a plugin reads its own settings and cannot write them, so choosing a profile
-- in the panel has to travel with the enable rather than change the setting.
local function resolveProfile(override)
    if override == nil then
        return configuredProfile()
    end
    if VALID_PROFILES[override] then
        return override
    end
    noctalia.log("gamermode: ignoring unknown profile " .. tostring(override))
    return configuredProfile()
end

local function autoPerformance()
    return noctalia.getConfig("auto_performance") ~= false
end

-- ── power profiles ──

-- parsePowerProfiles reads `powerprofilesctl list`, whose entries are lines like
-- "* balanced:" (the leading star marks the active one) followed by indented details.
function M.parsePowerProfiles(text)
    local profiles = {}
    local active = nil
    for line in tostring(text or ""):gmatch("[^\n]+") do
        local star, name = line:match("^%s*(%*?)%s*([%w][%w%-_]*):%s*$")
        if name then
            profiles[#profiles + 1] = name
            if star == "*" then
                active = name
            end
        end
    end
    return profiles, active
end

local function publishPower()
    noctalia.state.set("power", powerState)
end

local function powerSupports(profile)
    for _, candidate in ipairs(powerState.profiles) do
        if candidate == profile then
            return true
        end
    end
    return false
end

-- refreshPower republishes the power group and hands the active profile to `done`.
-- Without powerprofilesctl the group is marked unavailable and `done` receives nil, so
-- gamer mode still runs -- it just does not switch profiles.
function M.refreshPower(done)
    done = done or function() end
    if not noctalia.commandExists("powerprofilesctl") then
        powerState = { available = false, profiles = {} }
        publishPower()
        done(nil)
        return
    end
    run("powerprofilesctl list", function(result)
        local profiles, active = M.parsePowerProfiles(succeeded(result) and result.stdout or "")
        powerState = { available = true, profiles = profiles, active = active }
        publishPower()
        done(active)
    end)
end

function M.setPowerProfile(profile)
    if not powerState.available then
        noctalia.log("gamermode: powerprofilesctl is unavailable")
        return
    end
    if type(profile) ~= "string" or not powerSupports(profile) then
        noctalia.log("gamermode: refusing unsupported power profile " .. tostring(profile))
        return
    end
    run("powerprofilesctl set " .. shellQuote(profile), function(result)
        if not succeeded(result) then
            noctalia.log("gamermode: could not set the power profile: " .. describeFailure(result))
        end
        M.refreshPower()
    end)
end

-- ── published state ──

function M.publishMetrics()
    local metrics = M.normalize(noctalia.systemStats())
    if metrics then
        metrics.available = true
    else
        -- No system monitor: say so rather than publishing zeroes that read as real
        -- idle readings.
        metrics = { available = false, gpuAvailable = false }
    end
    noctalia.state.set("metrics", metrics)
end

M.pollMetrics = M.publishMetrics

-- publishGameMode derives the whole UI-visible state from the session file, so a shell
-- restart mid-session still shows gamer mode as on with the right suspend list.
function M.publishGameMode()
    local snap = M.readSnapshot()
    local suspended = {}
    if snap then
        for _, target in ipairs(snap.targets) do
            if UP_STATES[target.was] then
                suspended[#suspended + 1] = {
                    match = target.match,
                    kind = target.kind,
                    action = M.actionOf(target),
                }
            end
        end
    end
    noctalia.state.set("game_mode", {
        enabled = snap ~= nil,
        busy = busy,
        profile = snap and snap.profile or configuredProfile(),
        suspended = suspended,
        power_profile_before = snap and snap.power_profile_before or nil,
    })
end

-- ── enable ──

-- probeAll fans out one probe per target and reports once every answer is in. Results
-- keep the configured target order so snapshots are stable across runs.
local function probeAll(targets, done)
    local slots = {}
    local pending = #targets
    if pending == 0 then
        done({})
        return
    end

    local function settle()
        if pending > 0 then
            return
        end
        local probed = {}
        for index = 1, #targets do
            if slots[index] then
                probed[#probed + 1] = slots[index]
            end
        end
        done(probed)
    end

    for index, target in ipairs(targets) do
        local command = M.probeCmd(target)
        if not command then
            noctalia.log("gamermode: skipping unusable target " .. tostring(target.match))
            pending = pending - 1
            settle()
        else
            run(command, function(result)
                slots[index] = {
                    match = target.match,
                    kind = target.kind,
                    action = M.actionOf(target),
                    was = M.wasState(target.kind, result and result.stdout),
                }
                pending = pending - 1
                settle()
            end)
        end
    end
end

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

function M.enable(profileOverride)
    if busy then
        return
    end
    -- Idempotent: an existing session means gamer mode is already on, and probing again
    -- would overwrite the recorded "was" states with the suspended ones.
    if M.readSnapshot() then
        M.publishGameMode()
        return
    end

    busy = true
    M.publishGameMode()

    local profile = resolveProfile(profileOverride)
    local targets = M.targetsForProfile(M.parseTargets(noctalia.getConfig("targets")), profile)

    local function withPowerBefore(powerBefore)
        probeAll(targets, function(probed)
            suspendAll(probed, function(stopped)
                M.writeSnapshot(M.buildSnapshot(profile, powerBefore, probed))
                busy = false
                M.publishGameMode()
                if autoPerformance() and powerState.available and powerSupports("performance") then
                    M.setPowerProfile("performance")
                end
                if stopped > 0 then
                    noctalia.notify(noctalia.tr("notify.enabled_title"), noctalia.trp("notify.suspended_count", stopped))
                else
                    noctalia.notify(noctalia.tr("notify.enabled_title"), noctalia.tr("notify.nothing_suspended"))
                end
            end)
        end)
    end

    -- Capture the profile to hand back before switching away from it.
    if autoPerformance() then
        M.refreshPower(withPowerBefore)
    else
        withPowerBefore(nil)
    end
end

-- ── disable ──

function M.disable()
    if busy then
        return
    end
    local snap = M.readSnapshot()
    if not snap then
        M.publishGameMode()
        return
    end

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

    -- Freeze targets: thaw unconditionally, no probe. A frozen process still appears in
    -- pgrep so no probe could tell "still frozen" from "running", and SIGCONT to a running
    -- process is a verified no-op.
    for _, target in ipairs(thawTargets) do
        local thawCommand = M.thawCmd(target)
        if not thawCommand then
            noctalia.log("gamermode: no thaw command for " .. tostring(target.match))
            step()
        else
            run(thawCommand, function(result)
                if succeeded(result) then
                    restored = restored + 1
                else
                    noctalia.log("gamermode: could not thaw " .. target.match .. ": " .. describeFailure(result))
                end
                step()
            end)
        end
    end

    -- Stop targets: probe, then start only if still down.
    for _, target in ipairs(candidates) do
        local startCommand = M.startCmd(target)
        if not startCommand then
            -- Processes cannot be relaunched generically; say so once, per target.
            noctalia.log("gamermode: cannot restart " .. tostring(target.match) .. " (" .. tostring(target.kind) .. ")")
            step()
        else
            run(M.probeCmd(target), function(probeResult)
                if M.wasState(target.kind, probeResult and probeResult.stdout) ~= "down" then
                    -- Back up already, by hand or by its own supervisor. Leave it alone.
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
end

-- toggle passes the override through to enable. Turning gamer mode off needs no profile:
-- the session records which one was applied.
function M.toggle(profileOverride)
    if M.readSnapshot() then
        M.disable()
    else
        M.enable(profileOverride)
    end
end

-- ── commands ──

-- Commands arrive as `command` state writes from the panel and widget. The nonce makes
-- a replayed or duplicated write a no-op instead of a second toggle.
function M.handleCommand(command)
    if type(command) ~= "table" then
        noctalia.log("gamermode: ignoring a malformed command")
        return
    end
    local nonce = tonumber(command.nonce)
    if nonce then
        if nonce <= lastHandledNonce then
            return
        end
        lastHandledNonce = nonce
    end

    local action = command.action
    if action == "toggle" then
        M.toggle(command.profile)
    elseif action == "enable" then
        M.enable(command.profile)
    elseif action == "disable" then
        M.disable()
    elseif action == "set-power-profile" then
        M.setPowerProfile(command.profile)
    else
        noctalia.log("gamermode: unknown command action " .. tostring(action))
    end
end

-- reconcileSession decides what a session file found at startup means. A session from a
-- previous boot is stale: nothing it froze still exists, and units it stopped may have come
-- back on their own. It still gets a full restore pass before being cleared, because a
-- stopped unit that is not `enabled` really is still down, and putting it back is what the
-- user was told would happen.
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
    -- rather than abandoning targets that may still be suspended. Likewise when the boot
    -- id cannot be read at all.
    if not snap.boot_id or not current or snap.boot_id == current then
        M.publishGameMode()
        return
    end

    noctalia.log("gamermode: session predates the current boot, restoring and clearing it")
    M.disable()
end

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

-- ── shell entry points (must be globals) ──

function update()
    M.publishMetrics()
end

function onConfigChanged()
    local seconds = tonumber(noctalia.getConfig("poll_interval")) or DEFAULT_POLL_SECONDS
    noctalia.setUpdateInterval(math.max(1, seconds) * 1000)
    -- The configured profile shows in the panel even while gamer mode is off.
    M.publishGameMode()
end

function onIpc(event)
    if event == "toggle" then
        M.toggle()
    elseif event == "enable" then
        M.enable()
    elseif event == "disable" then
        M.disable()
    end
end

noctalia.state.watch("command", M.handleCommand)
M.init()

return M
