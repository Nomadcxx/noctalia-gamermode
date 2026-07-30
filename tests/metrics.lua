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

print("metrics: passed")
