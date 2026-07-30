-- Maintenance actions: the three one-shot cleanups the panel offers. Two of them elevate
-- and one deletes files, so the commands they build are worth pinning exactly.
package.path = "./tests/?.lua;" .. package.path
local helpers = require("helpers")

local DATA_DIR = "/tmp/gamermode-test-cleanup"
local HOME = "/tmp/gamermode-test-cleanup/home"

local mock = helpers.newNoctalia({ dataDir = DATA_DIR, home = HOME })
local svc = dofile("gamer-mode/service.luau")

helpers.resetDir(DATA_DIR)

-- ── shader caches ──

-- Nothing on disk yet, so nothing is offered up for deletion.
assert(#svc.shaderCachePaths() == 0, "no caches means no paths")
assert(svc.shaderClearCmd({}) == nil, "an empty path list builds no rm")
assert(svc.shaderSizeCmd({}) == nil, "an empty path list builds no du")

os.execute("mkdir -p '" .. HOME .. "/.cache/mesa_shader_cache' '" .. HOME .. "/.cache/nvidia/GLCache'")
local found = svc.shaderCachePaths()
assert(#found == 2, "both existing caches found, got " .. #found)
for _, path in ipairs(found) do
    assert(path:sub(1, #HOME) == HOME, "path stays under home: " .. path)
end

-- Caches that are not present are skipped, so rm is never handed a path that does not
-- exist and du never reports on one.
for _, path in ipairs(found) do
    assert(not path:find("radv", 1, true), "absent caches stay out: " .. path)
end

local clear = svc.shaderClearCmd(found)
assert(clear:find("^rm %-rf %-%- "), "clears with an option terminator, got " .. clear)
assert(clear:find("'" .. HOME .. "/.cache/mesa_shader_cache'", 1, true), "names the mesa cache")
assert(not clear:find("*", 1, true), "no glob reaches the shell")

local size = svc.shaderSizeCmd(found)
assert(size:find("du %-sbc "), "measures in bytes with a total, got " .. size)
assert(size:find("tail %-1"), "reads the grand total line")

-- The home guard is what keeps a future settable path list from turning rm -rf loose.
-- With no resolvable home there is nothing to delete.
mock.home = "/"
assert(#svc.shaderCachePaths() == 0, "a home of / yields no paths")
mock.home = ""
assert(#svc.shaderCachePaths() == 0, "an empty home yields no paths")
mock.home = HOME

-- And every path is checked individually after expansion, not just the home itself. This
-- is the check that matters if the cache list ever becomes a setting: an entry that
-- resolves outside the home directory is dropped rather than handed to rm.
local realExpand = mock.expandPath
local escaped = "/tmp/gamermode-test-cleanup-escaped"
os.execute("mkdir -p '" .. escaped .. "'")
mock.expandPath = function(path)
    if path == "~/.cache/mesa_shader_cache" then
        return escaped
    end
    return realExpand(path)
end
local guarded = svc.shaderCachePaths()
for _, path in ipairs(guarded) do
    assert(path ~= escaped, "a path outside home must not reach rm: " .. path)
    assert(path:sub(1, #HOME) == HOME, "every surviving path is under home: " .. path)
end
assert(#guarded == 1, "the escaping entry is dropped and the rest kept, got " .. #guarded)
mock.expandPath = realExpand
os.execute("rmdir '" .. escaped .. "' 2>/dev/null")

-- ── page cache ──

local drop = svc.dropCachesCmd()
assert(drop == "pkexec /usr/bin/sysctl -w vm.drop_caches=3", "drops through sysctl, got " .. drop)
assert(not drop:find("sh %-c"), "no root shell is needed to write one sysctl")

-- ── swap ──

local swap = svc.reclaimSwapCmd()
assert(swap:find("^pkexec "), "elevates once, got " .. swap)
assert(swap:find("swapoff %-a && swapon %-a"), "both halves in one invocation, got " .. swap)

-- Reclaiming reads every swapped page back into RAM, so it only runs when that fits.
local function stats(swapUsedMb, ramUsedMb, ramTotalMb)
    return { swap = { usedMb = swapUsedMb }, ram = { usedMb = ramUsedMb, totalMb = ramTotalMb } }
end

local ok, reason = svc.canReclaimSwap(stats(0, 16384, 32768))
assert(not ok and reason == "swap_empty", "nothing swapped out means nothing to do, got " .. tostring(reason))

ok, reason = svc.canReclaimSwap(stats(2048, 16384, 32768))
assert(ok, "2 GiB of swap fits in 16 GiB free, got " .. tostring(reason))

-- 14 GiB free but a tenth of 32 GiB is held back, so 13 GiB is too much to pull in.
ok, reason = svc.canReclaimSwap(stats(13312, 18432, 32768))
assert(not ok and reason == "swap_no_room", "refuses without headroom, got " .. tostring(reason))

ok, reason = svc.canReclaimSwap(nil)
assert(not ok and reason == "swap_unknown", "no stats means no guess")
ok, reason = svc.canReclaimSwap({ swap = { usedMb = 1024 } })
assert(not ok and reason == "swap_unknown", "swap without ram figures means no guess")

-- ── sizes ──

assert(svc.humanBytes(0) == "0 KiB", "zero, got " .. svc.humanBytes(0))
assert(svc.humanBytes(1024 * 1024 * 1536) == "1.5 GiB", "gibibytes, got " .. svc.humanBytes(1024 * 1024 * 1536))
assert(svc.humanBytes(1024 * 1024 * 79) == "79 MiB", "mebibytes, got " .. svc.humanBytes(1024 * 1024 * 79))

-- ── dispatch ──

-- Cleanups arrive as commands, and an unknown job is ignored rather than guessed at.
local before = #mock.commands
noctalia.state.set("command", { nonce = 1, action = "cleanup", job = "nonsense" })
assert(#mock.commands == before, "an unknown job runs nothing")
assert(#mock.logs > 0, "and says so")

noctalia.state.set("command", { nonce = 2, action = "cleanup", job = "pagecache" })
assert(helpers.ranCommand(mock, "sync"), "syncs before dropping, or dirty pages are lost")
assert(helpers.ranCommand(mock, "sysctl -w vm.drop_caches=3"), "drops the cache")
assert(type(mock.published.cleanup) == "table", "the result is published for the panel")
assert(mock.published.cleanup.running == nil, "and the job is finished")

-- shaders-measure reports a size without removing anything.
mock.commands = {}
noctalia.state.set("command", { nonce = 3, action = "cleanup", job = "shaders-measure" })
assert(not helpers.ranCommand(mock, "rm -rf"), "measuring deletes nothing")
assert(helpers.ranCommand(mock, "du -sbc"), "measuring measures")
assert(type(mock.published.cleanup.shaderSize) == "string", "the size reaches the panel")

-- Only then does the delete run.
mock.commands = {}
noctalia.state.set("command", { nonce = 4, action = "cleanup", job = "shaders" })
assert(helpers.ranCommand(mock, "rm -rf -- "), "the second job deletes")

print("cleanup: passed")
