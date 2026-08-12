-- Animoo: the gradient wordmark. The demo's whole claim is that the bar shows
-- moving light inside glyphs and nothing else, so this pins both the paint values
-- and the absence of any backing shape.
package.path = "./tests/?.lua;" .. package.path
local helpers = require("helpers")

-- The living-poster loop is not complete unless its real assets ship. The runtime
-- tests below use fake paths to isolate the frame scheduler, so pin the binary bundle
-- here as a separate, cheap check.
local portraitWidth = nil
local portraitHeight = nil
for index = 1, 6 do
    local path = string.format("animoo-noctalia/assets/portrait-%02d.png", index)
    local file = assert(io.open(path, "rb"), "missing portrait frame: " .. path)
    local header = assert(file:read(24), "short portrait frame: " .. path)
    file:close()
    assert(header:sub(1, 8) == "\137PNG\r\n\26\n", "portrait frame is not PNG: " .. path)
    local width, height = string.unpack(">I4I4", header, 17)
    portraitWidth = portraitWidth or width
    portraitHeight = portraitHeight or height
    assert(width == portraitWidth and height == portraitHeight,
        string.format("portrait frame canvas drift: %s is %dx%d, expected %dx%d",
            path, width, height, portraitWidth, portraitHeight))
end
assert(portraitWidth >= 420 and portraitHeight >= 560,
    string.format("portrait source is too small for the panel: %dx%d", portraitWidth, portraitHeight))

_G.ui = setmetatable({}, {
    __index = function(_, name)
        return function(spec, children)
            return { kind = name, spec = spec or {}, children = children }
        end
    end,
})

local rendered = nil
local tooltip = nil
_G.barWidget = {
    render = function(tree)
        rendered = tree
    end,
    setTooltip = function(value)
        tooltip = value
    end,
    isVertical = function()
        return false
    end,
}

local toggled = nil
local mock = helpers.newNoctalia({})
_G.noctalia.togglePanel = function(id)
    toggled = id
end

local wordmark = dofile("animoo-noctalia/wordmark.luau")

-- ── the wordmark itself ──

assert(rendered ~= nil, "the widget renders a tree")
assert(rendered.kind == "label", "the wordmark is a label, not a box or gradient; got " .. tostring(rendered.kind))

local spec = rendered.spec
assert(spec.text == "アニムー", "the wordmark reads アニムー, got " .. tostring(spec.text))
assert(spec.fontWeight == "bold", "the wordmark is bold")

-- ── paint ──

assert(type(spec.colors) == "table" and #spec.colors == 3, "three logical colours")
assert(spec.colors[1] == spec.colors[3], "the two shoulders share one dim colour")
assert(spec.colors[1] ~= spec.colors[2], "the crest is brighter than the shoulders")

local baseAlpha = tonumber(spec.colors[1]:sub(8, 9), 16)
assert(baseAlpha ~= nil, "the base colour carries an explicit alpha byte")
assert(baseAlpha <= 0x20, "the base ink stays barely visible, got alpha " .. tostring(baseAlpha))
assert(spec.color == spec.colors[1], "the solid fallback matches the base ink")

assert(#spec.stops == 3, "three stops for three colours")
assert(spec.stops[1] == 0.40 and spec.stops[2] == 0.50 and spec.stops[3] == 0.60,
    "the crest is a narrow band centred on the word")
assert(spec.direction == "horizontal", "the crest travels horizontally")
assert(spec.glowRadius == 3, "the crest carries a small halo, got " .. tostring(spec.glowRadius))

-- ── motion ──

assert(spec.motion == "loop", "the crest loops rather than ping-ponging; a ping-pong would "
    .. "walk the light backwards through the word")
assert(spec.duration == 1800, "one 1800ms trip")
assert(spec.offsetFrom == -0.60, "the trip starts off-glyph")
assert(spec.offsetTo == 0.60, "the trip ends off-glyph")

-- The reset is only invisible if both endpoints put the crest outside the word.
-- Crest centre sits at stops[2]; offset shifts it along the axis.
local crestAtStart = spec.stops[2] + spec.offsetFrom
local crestAtEnd = spec.stops[2] + spec.offsetTo
assert(crestAtStart < 0, "at the start of the trip the crest is left of the word")
assert(crestAtEnd > 1, "at the end of the trip the crest is right of the word")

-- ── nothing else in the bar ──

assert(rendered.children == nil or #rendered.children == 0, "the wordmark has no children")
for _, forbidden in ipairs({ "fill", "radius", "border", "borderWidth" }) do
    assert(spec[forbidden] == nil, "the bar has no backing rail: unexpected " .. forbidden)
end

-- ── tooltip and click ──

assert(type(tooltip) == "string" and tooltip:match("Animoo"),
    "the tooltip names Animoo in English so it survives a Japanese font fallback")
assert(not tooltip:match("アニムー"), "the tooltip does not depend on the CJK face")

assert(type(_G.onClick) == "function", "the widget exposes a global onClick")
_G.onClick()
assert(toggled == "nomadcxx/animoo-noctalia:main", "clicking opens the Animoo panel, got " .. tostring(toggled))

print("animoo: ok")

-- ── panel ──
--
-- Loaded second so the widget assertions above run against a clean global table.

local panelRendered = nil
local frameTick = nil
local closed = false
_G.panel = {
    render = function(tree)
        panelRendered = tree
    end,
    close = function()
        closed = true
    end,
    setNeedsFrameTick = function(value)
        frameTick = value
    end,
}

-- Pretend all six frames are on disk; the loop's shape is what is under test, not the art.
local pluginDir = "/tmp/animoo-test-plugin"
_G.noctalia.pluginDir = function()
    return pluginDir
end
local existing = {}
for i = 1, 6 do
    existing[string.format("%s/assets/portrait-%02d.png", pluginDir, i)] = true
end
_G.noctalia.fileExists = function(path)
    return existing[path] == true
end

local animoo = dofile("animoo-noctalia/panel.luau")

local function findByKey(node, key)
    if type(node) ~= "table" then
        return nil
    end
    if node.spec and node.spec.key == key then
        return node
    end
    for _, child in ipairs(node.children or {}) do
        local found = findByKey(child, key)
        if found then
            return found
        end
    end
    return nil
end

local function collectImages(node, out)
    out = out or {}
    if type(node) ~= "table" then
        return out
    end
    if node.kind == "image" then
        out[#out + 1] = node
    end
    for _, child in ipairs(node.children or {}) do
        collectImages(child, out)
    end
    return out
end

assert(panelRendered ~= nil, "the panel renders on load")

-- ── the heading is native gradient text, not an image ──

local heading = findByKey(panelRendered, "animoo-heading")
assert(heading ~= nil, "the panel has a gradient heading")
assert(heading.kind == "label", "the heading is a native gradient label")
assert(heading.spec.motion == "loop" and heading.spec.glowRadius > 0,
    "the heading uses the same animated gradient the bar does")

-- ── six resident frames, one visible ──

local images = collectImages(panelRendered)
assert(#images == 6, "all six frames exist as nodes, got " .. #images)
local portrait = findByKey(panelRendered, "portrait")
assert(portrait and portrait.kind == "row", "resident portrait frames use a child-capable row")

-- The ui.* stub above is pure data, so it happily records children on a node type the
-- shell would refuse them on. ui.box is one of those: the reconciler's childContainer()
-- returns null for it and logs "'box' cannot have children, N dropped", which is exactly
-- how the six portrait frames first went missing on screen while this test stayed green.
-- Pin the container allowlist so a leaf can never quietly swallow a subtree again.
local CHILD_CAPABLE = { row = true, column = true, scroll = true }

local function assertContainersAcceptChildren(node, path)
    if type(node) ~= "table" then
        return
    end
    path = path or node.kind or "root"
    local children = node.children or {}
    if #children > 0 then
        assert(CHILD_CAPABLE[node.kind],
            "'" .. tostring(node.kind) .. "' at " .. path .. " has " .. #children
                .. " children but is a leaf in the shell; its subtree would be dropped")
    end
    for index, child in ipairs(children) do
        assertContainersAcceptChildren(child, path .. " > " .. tostring(child.kind) .. "[" .. index .. "]")
    end
end

assertContainersAcceptChildren(panelRendered)

local visible = 0
local paths = {}
for _, image in ipairs(images) do
    assert(image.spec.key ~= nil, "each frame carries a stable key")
    assert(paths[image.spec.path] == nil, "each frame has a distinct path")
    paths[image.spec.path] = true
    if image.spec.visible then
        visible = visible + 1
    end
end
assert(visible == 1, "exactly one frame is visible at a time, got " .. visible)

-- ── the schedule reads as breathing, not as six unrelated pictures ──

assert(animoo.frameAt(0) == 1, "the loop starts on the neutral frame")

local seen = {}
local cycleMs = animoo.cycleTicks() * (1000 / 12)
for ms = 0, cycleMs - 1, 1000 / 12 do
    seen[animoo.frameAt(ms)] = (seen[animoo.frameAt(ms)] or 0) + 1
end
for frame = 1, 6 do
    assert(seen[frame] ~= nil, "frame " .. frame .. " appears in the cycle")
end
assert(seen[1] > seen[4], "the neutral frame is held far longer than the closed-eye frame")
assert(seen[4] == 1, "the blink is a single tick, not a stare")
assert(animoo.frameAt(cycleMs) == animoo.frameAt(0), "the cycle closes on itself")

-- ── ticks only render on a frame change ──

local before = panelRendered
_G.onFrameTick(1) -- far less than one 12fps frame
assert(panelRendered == before, "a sub-frame tick does not re-render")

_G.onFrameTick(1000 / 12 * 20) -- well into the blink
assert(panelRendered ~= before, "crossing a frame boundary re-renders")

-- ── lifecycle ──

_G.onOpen()
assert(frameTick == true, "opening the panel enables frame ticks")

_G.onClose()
assert(frameTick == false, "closing the panel disables frame ticks")

-- ── pause returns to the neutral frame and stops ticking ──

_G.onOpen()
_G.onFrameTick(1000 / 12 * 20)
_G.onTogglePause()
assert(frameTick == false, "pausing stops frame ticks")
local pausedImages = collectImages(panelRendered)
for _, image in ipairs(pausedImages) do
    if image.spec.visible then
        assert(image.spec.key == "portrait-01", "pausing returns to the neutral frame, got " .. image.spec.key)
    end
end
_G.onTogglePause()
assert(frameTick == true, "resuming restarts frame ticks")

-- ── no invented telemetry ──

local function collectText(node, out)
    out = out or {}
    if type(node) ~= "table" then
        return out
    end
    if node.kind == "label" and type(node.spec.text) == "string" then
        out[#out + 1] = node.spec.text
    end
    for _, child in ipairs(node.children or {}) do
        collectText(child, out)
    end
    return out
end

for _, text in ipairs(collectText(panelRendered)) do
    assert(not text:match("%d+%s*[MG]B"), "the panel invents no memory figures: " .. text)
    assert(not text:lower():match("cpu") and not text:lower():match("gpu"),
        "the panel invents no system metrics: " .. text)
end

-- ── missing frames degrade to a labelled diagnostic, never a blank panel ──

existing = {}
_G.onOpen()
assert(#collectImages(panelRendered) == 0, "no image nodes when the frames are missing")
local diagnostic = findByKey(panelRendered, "portrait-missing")
assert(diagnostic ~= nil, "missing frames leave a labelled diagnostic")
assert(diagnostic.kind == "column", "the missing-frame diagnostic uses a child-capable column")
local diagnosticText = table.concat(collectText(diagnostic), " ")
assert(diagnosticText:match("UNAVAILABLE"), "the diagnostic box says what went wrong")

-- ── close ──

_G.onCloseClicked()
assert(closed, "the close button closes the panel")

print("animoo panel: ok")
