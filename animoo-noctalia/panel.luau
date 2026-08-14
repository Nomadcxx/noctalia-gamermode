--!nonstrict
--
-- Animoo panel: a larger animated wordmark over a low-frame-rate "living poster".
--
-- The portrait is eleven PNGs on one fixed canvas. All eleven become ui.image nodes on the
-- first render and stay in the tree forever; only `visible` moves. Swapping one node's
-- `path` per frame would make the shell decode and upload the file again every time,
-- which is the whole reason this looks like a lot of nodes for one picture.

local FRAME_COUNT = 11
local FPS = 24
local FRAME_MS = 1000 / FPS

-- Bar ink stays nearly invisible between crests. The panel heading is the title of
-- the poster, so the same crest recipe sits on a readable cyan body.
local BASE = "#55edf5c0"
local CREST = "#f4ffff"

local M = {}

-- ── the frame schedule ──
--
-- Two motions at different speeds: a slow continuous breath, and one fast blink per
-- cycle. Frames 2, 4, 6, 7 and 11 are interpolated in-betweens, which is what lets the
-- breath run at 24fps without reading as a five-position slideshow.
--
-- Expressed as {frame, hold-in-ticks} at 24fps. One full cycle is ~4.2s, which is
-- roughly a resting breath and a natural blink interval.
M.SCHEDULE = {
    -- breath in, hold, out — long holds at the extremes, quick through the middle
    { frame = 1, ticks = 12 }, -- neutral, eyes open
    { frame = 2, ticks = 8 },  -- easing into the breath
    { frame = 3, ticks = 14 }, -- inhale, hair drift
    { frame = 4, ticks = 8 },  -- passing through
    { frame = 5, ticks = 14 }, -- exhale
    { frame = 6, ticks = 8 },  -- easing back out

    -- one blink, ~0.4s end to end
    { frame = 7, ticks = 2 },  -- lid starting down
    { frame = 8, ticks = 2 },  -- half
    { frame = 9, ticks = 2 },  -- closed
    { frame = 10, ticks = 2 }, -- half open
    { frame = 11, ticks = 2 }, -- lid finishing up

    { frame = 1, ticks = 22 }, -- settle
}

function M.cycleTicks()
    local total = 0
    for _, step in ipairs(M.SCHEDULE) do
        total = total + step.ticks
    end
    return total
end

-- Deterministic: the same elapsed time always yields the same frame, so the loop
-- cannot drift and the test can assert on it without a clock.
function M.frameAt(elapsedMs)
    local tick = math.floor((tonumber(elapsedMs) or 0) / FRAME_MS)
    local cycle = M.cycleTicks()
    tick = tick % cycle
    for _, step in ipairs(M.SCHEDULE) do
        if tick < step.ticks then
            return step.frame
        end
        tick = tick - step.ticks
    end
    return 1
end

function M.framePath(index)
    local dir = noctalia.pluginDir()
    if not dir then
        return nil
    end
    -- The shell's texture cache is keyed by {path, size} with no mtime, so editing a
    -- frame in place serves the stale raster until restart. Renaming the set is the
    -- reliable way to ship new art; bump the prefix rather than overwriting.
    return string.format("%s/assets/cel-%02d.png", dir, index)
end

-- ── state ──

local visibleFrame = 1
local elapsedMs = 0
local paused = false

-- ── tree ──

function M.wordmark()
    return ui.label({
        key = "animoo-heading",
        text = "アニムー",
        fontFamily = "Noto Sans Mono CJK JP",
        fontSize = 42,
        fontWeight = "bold",
        color = BASE,
        colors = { BASE, CREST, BASE },
        stops = { 0.40, 0.50, 0.60 },
        direction = "horizontal",
        motion = "loop",
        duration = 1800,
        offsetFrom = -0.60,
        offsetTo = 0.60,
        glowRadius = 4,
    })
end

-- Every frame node exists on every render with a stable key and path; only `visible`
-- differs. That is what keeps the eleven textures resident.
function M.portrait()
    local dir = noctalia.pluginDir()
    if not dir then
        return M.missingFrames("no plugin directory")
    end

    local children = {}
    local present = 0
    for index = 1, FRAME_COUNT do
        local path = M.framePath(index)
        if path and noctalia.fileExists(path) then
            present = present + 1
            children[#children + 1] = ui.image({
                key = string.format("portrait-%02d", index),
                path = path,
                width = 420,
                height = 560,
                fit = "contain",
                visible = index == visibleFrame,
            })
        end
    end

    if present < FRAME_COUNT then
        -- A labelled diagnostic rather than a blank panel: a silently empty poster reads as
        -- a broken gradient, which is the one thing this demo must not imply.
        return M.missingFrames(string.format("%d of %d portrait frames found", present, FRAME_COUNT))
    end
    return ui.row({ key = "portrait", width = 420, height = 560 }, children)
end

function M.missingFrames(reason)
    return ui.column({ key = "portrait-missing", width = 420, height = 560, radius = 6, borderWidth = 1,
        align = "center", justify = "center", gap = 6 }, {
        ui.label({ text = "PORTRAIT UNAVAILABLE", fontSize = 12, color = "#ff6b6b" }),
        ui.label({ text = reason, fontSize = 11, color = "#f0b429" }),
    })
end

function M.buildTree()
    return ui.column({ padding = 20, gap = 14, flexGrow = 1, align = "center" }, {
        M.wordmark(),
        -- One quiet line naming the two live features. No stacked all-caps eyebrows.
        ui.label({
            text = string.format("gradient text  ·  %d fps poster", FPS),
            fontSize = 11,
            color = "#55edf5a0",
        }),
        M.portrait(),
        ui.row({ align = "center", gap = 8 }, {
            ui.button({
                key = "pause",
                text = paused and "Resume" or "Pause",
                variant = "ghost",
                tooltip = "Stop the portrait loop and return to the neutral frame",
                onClick = "onTogglePause",
            }),
            ui.button({
                key = "close",
                glyph = "close",
                variant = "ghost",
                tooltip = "Close",
                onClick = "onCloseClicked",
            }),
        }),
    })
end

local function render()
    panel.render(M.buildTree())
end

local function syncFrameTick()
    if panel.setNeedsFrameTick then
        panel.setNeedsFrameTick(not paused)
    end
end

-- ── lifecycle ──

function onOpen()
    elapsedMs = 0
    visibleFrame = 1
    paused = false
    render()
    syncFrameTick()
end

function onClose()
    -- Frame ticks are the panel's only ongoing cost; opening it again resets the loop.
    if panel.setNeedsFrameTick then
        panel.setNeedsFrameTick(false)
    end
end

-- Re-rendering only on a frame change is what keeps a 12fps poster from asking the
-- shell to diff a whole Lua tree at vsync.
function onFrameTick(deltaMs)
    if paused then
        return
    end
    elapsedMs = elapsedMs + math.max(0, tonumber(deltaMs) or 0)
    local nextFrame = M.frameAt(elapsedMs)
    if nextFrame ~= visibleFrame then
        visibleFrame = nextFrame
        render()
    end
end

function onTogglePause()
    paused = not paused
    if paused then
        -- Parking on the neutral frame, not wherever the blink happened to be.
        visibleFrame = 1
        elapsedMs = 0
    end
    render()
    syncFrameTick()
end

function onCloseClicked()
    panel.close()
end

render()

return M
