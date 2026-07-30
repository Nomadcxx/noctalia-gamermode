-- Metrics normalization: noctalia.systemStats() -> the published `metrics` shape.
package.path = "./tests/?.lua;" .. package.path
local helpers = require("helpers")

helpers.newNoctalia()
local svc = dofile("gamer-mode/service.luau")

-- Full sample: percentages arrive 0-100 from the shell and are published as 0-1
-- fractions; RAM is MiB and VRAM is bytes.
local metrics = svc.normalize({
    cpu = { usagePercent = 25, tempC = 58.5 },
    ram = { usagePercent = 50, usedMb = 16384, totalMb = 32768 },
    gpu = { usagePercent = 18, tempC = 61, vramUsedBytes = 2726297600, vramTotalBytes = 8585740288 },
})
assert(math.abs(metrics.cpuPerc - 0.25) < 0.0001, "cpu fraction, got " .. tostring(metrics.cpuPerc))
assert(math.abs(metrics.cpuTemp - 58.5) < 0.01, "cpu temp passthrough")
assert(math.abs(metrics.memPerc - 0.5) < 0.0001, "ram fraction")
assert(metrics.memUsedMb == 16384 and metrics.memTotalMb == 32768, "ram MiB passthrough")
assert(math.abs(metrics.gpuPerc - 0.18) < 0.0001, "gpu fraction")
assert(metrics.gpuTemp == 61, "gpu temp")
assert(math.abs(metrics.vramUsedMb - 2600) < 1, "vram MiB, got " .. tostring(metrics.vramUsedMb))
assert(math.abs(metrics.vramTotalMb - 8188) < 1, "vram total MiB, got " .. tostring(metrics.vramTotalMb))
assert(metrics.gpuAvailable == true, "gpu reported available")

-- Missing monitor: normalize(nil) must not crash and must report nothing.
assert(svc.normalize(nil) == nil, "nil stats normalize to nil")
assert(svc.normalize("garbage") == nil, "non-table stats normalize to nil")

-- GPU absent (no discrete GPU, or NVML unavailable): every gpu field is optional and
-- the whole gpu group is marked unavailable rather than published as zero.
local noGpu = svc.normalize({
    cpu = { usagePercent = 7 },
    ram = { usagePercent = 12, usedMb = 4096, totalMb = 32768 },
    gpu = {},
})
assert(noGpu.gpuAvailable == false, "empty gpu table marks gpu unavailable")
assert(noGpu.gpuPerc == nil and noGpu.gpuTemp == nil, "no fabricated gpu numbers")
assert(noGpu.vramUsedMb == nil and noGpu.vramTotalMb == nil, "no fabricated vram numbers")
assert(noGpu.cpuTemp == nil, "absent cpu temp stays absent")

-- Partial GPU: usage without VRAM still counts as available.
local partial = svc.normalize({ cpu = {}, ram = {}, gpu = { usagePercent = 40 } })
assert(partial.gpuAvailable == true and math.abs(partial.gpuPerc - 0.4) < 0.0001, "usage-only gpu")
assert(partial.vramUsedMb == nil, "vram absent when only one of used/total is known")

-- VRAM needs both halves to be meaningful.
local halfVram = svc.normalize({ cpu = {}, ram = {}, gpu = { vramUsedBytes = 1048576 } })
assert(halfVram.vramUsedMb == nil and halfVram.vramTotalMb == nil, "vramUsed without total is dropped")

-- Missing groups entirely (defensive: the binding always sends them, plugins should not
-- assume it) and out-of-range percentages are clamped to 0-1.
local sparse = svc.normalize({})
assert(sparse.cpuPerc == 0 and sparse.memPerc == 0 and sparse.gpuAvailable == false, "sparse stats")
local clamped = svc.normalize({ cpu = { usagePercent = 140 }, ram = { usagePercent = -5 }, gpu = {} })
assert(clamped.cpuPerc == 1 and clamped.memPerc == 0, "percentages clamped to 0-1")

-- ── vendor shapes ──

-- GPU readings reach the shell through NVML for NVIDIA and sysfs for everything else, and
-- the two do not report the same fields. Each shape has to degrade to "show what is there"
-- rather than to a zero that reads as a real idle measurement.

-- NVIDIA through NVML: usage, temperature and both halves of VRAM.
local nvidia = svc.normalize({
    cpu = { usagePercent = 10 },
    ram = { usagePercent = 20, usedMb = 4096, totalMb = 32768 },
    gpu = { usagePercent = 27, tempC = 60, vramUsedBytes = 1689911296, vramTotalBytes = 8585740288 },
})
assert(nvidia.gpuAvailable and nvidia.gpuPerc and nvidia.gpuTemp and nvidia.vramPerc, "nvidia reports everything")

-- An AMD card whose sysfs exposes usage and temperature but no VRAM figures. The GPU row
-- must still appear; only VRAM drops out.
local amd = svc.normalize({
    cpu = { usagePercent = 10 },
    ram = { usagePercent = 20, usedMb = 4096, totalMb = 32768 },
    gpu = { usagePercent = 44, tempC = 71 },
})
assert(amd.gpuAvailable == true, "an AMD card without vram figures is still a gpu")
assert(math.abs(amd.gpuPerc - 0.44) < 0.0001, "amd usage, got " .. tostring(amd.gpuPerc))
assert(amd.gpuTemp == 71, "amd temperature")
assert(amd.vramUsedMb == nil and amd.vramPerc == nil, "no invented vram")

-- Temperature only, which is all some integrated parts report.
local intel = svc.normalize({ cpu = {}, ram = {}, gpu = { tempC = 49 } })
assert(intel.gpuAvailable == true, "a temperature alone still counts as a gpu")
assert(intel.gpuPerc == nil, "usage is not invented from a temperature")

-- ── swap ──

local swapped = svc.normalize({ cpu = {}, ram = {}, gpu = {}, swap = { usedMb = 2048, totalMb = 16384 } })
assert(math.abs(swapped.swapPerc - 0.125) < 0.0001, "swap fraction, got " .. tostring(swapped.swapPerc))
assert(swapped.swapUsedMb == 2048 and swapped.swapTotalMb == 16384, "swap figures carried through")

-- Swap turned off reports a zero total, which is not a ratio. The row is dropped rather
-- than drawn at nought percent.
local noSwap = svc.normalize({ cpu = {}, ram = {}, gpu = {}, swap = { usedMb = 0, totalMb = 0 } })
assert(noSwap.swapPerc == nil and noSwap.swapTotalMb == nil, "a zero swap total yields no reading")
local absentSwap = svc.normalize({ cpu = {}, ram = {}, gpu = {} })
assert(absentSwap.swapPerc == nil, "no swap table yields no reading")

-- ── load average and network ──

local loaded = svc.normalize({ cpu = {}, ram = {}, gpu = {}, loadAvg = { 2.1, 2.2, 1.64 } })
assert(loaded.load1 == 2.1 and loaded.load5 == 2.2 and loaded.load15 == 1.64, "three load figures")

-- A short or malformed array is dropped whole: a partial load average means nothing.
local shortLoad = svc.normalize({ cpu = {}, ram = {}, gpu = {}, loadAvg = { 2.1 } })
assert(shortLoad.load1 == nil, "a partial load average is dropped")

local netted = svc.normalize({ cpu = {}, ram = {}, gpu = {}, net = { rxBytesPerSec = 3714, txBytesPerSec = 2140 } })
assert(netted.netRxPerSec == 3714 and netted.netTxPerSec == 2140, "network totals carried through")

-- Only one direction is not a reading.
local halfNet = svc.normalize({ cpu = {}, ram = {}, gpu = {}, net = { rxBytesPerSec = 100 } })
assert(halfNet.netRxPerSec == nil, "one direction alone is dropped")

print("metrics: passed")
