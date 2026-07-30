-- The panel logo exists twice: as gamer-mode/logo.svg, and embedded in panel.luau because
-- no API reports where the plugin directory is. Two copies drift, so this pins them.
package.path = "./tests/?.lua;" .. package.path
local helpers = require("helpers")

local DATA_DIR = "/tmp/gamermode-test-logo"

local function read(path)
    local file = assert(io.open(path, "r"), "missing: " .. path)
    local contents = file:read("*a")
    file:close()
    return contents
end

local svg = read("gamer-mode/logo.svg")
local panelSource = read("gamer-mode/panel.luau")

-- ── the two copies agree ──

local embedded = panelSource:match("local LOGO_SVG = %[==%[\n(.-)%]==%]")
assert(embedded, "panel.luau must embed the logo in a LOGO_SVG long-bracket string")
assert(embedded == svg,
    "gamer-mode/logo.svg and the LOGO_SVG copy in panel.luau have drifted apart; "
        .. "edit the .svg and re-embed it")

-- A long-bracket string ends at the first matching close, so the payload must not contain
-- one. If the artwork ever does, the level has to go up and this catches it.
assert(not svg:find("]==]", 1, true), "the logo would terminate its own long-bracket string")

-- ── it is usable artwork ──

assert(svg:find("<svg", 1, true) == 1, "starts with the svg element")
assert(svg:find("</svg>", 1, true), "and closes it")
assert(svg:find('viewBox="0 0 512 512"', 1, true), "carries a viewBox, or it cannot scale in the panel")

-- Rendered small in a header, so nothing may depend on an external file or a script.
assert(not svg:find("<script", 1, true), "no script in artwork the shell will render")
assert(not svg:find("xlink:href", 1, true), "no external references")
assert(not svg:find("<image", 1, true), "no embedded raster that would blur when scaled")

-- ── the panel writes it somewhere it can be read from ──

_G.ui = setmetatable({}, {
    __index = function(_, name)
        return function(spec, children)
            return { kind = name, spec = spec or {}, children = children }
        end
    end,
})

local rendered = nil
_G.panel = {
    render = function(tree)
        rendered = tree
    end,
    close = function() end,
}

local mock = helpers.newNoctalia({ dataDir = DATA_DIR })
helpers.resetDir(DATA_DIR)

local writes = 0
local realWriteFile = mock.writeFile
mock.writeFile = function(path, contents)
    writes = writes + 1
    return realWriteFile(path, contents)
end

dofile("gamer-mode/panel.luau")
onOpen()

local written = DATA_DIR .. "/logo.svg"
assert(mock.fileExists(written), "the logo is written to the plugin data directory")
assert(read(written) == svg, "and it is the same artwork")

-- The header shows the file, not the fallback glyph.
local function findNode(node, predicate)
    if type(node) ~= "table" then
        return nil
    end
    if node.kind and predicate(node) then
        return node
    end
    for _, child in ipairs(node.children or {}) do
        local hit = findNode(child, predicate)
        if hit then
            return hit
        end
    end
    return nil
end

local image = findNode(rendered, function(node)
    return node.kind == "image"
end)
assert(image, "the header renders the logo as an image")
assert(image.spec.path == written, "pointing at the written file, got " .. tostring(image.spec.path))
assert(tonumber(image.spec.height) and image.spec.height > 0, "at a real size")

-- Writing happens once: a later render reuses what is already there.
local writesAfterFirst = writes
onOpen()
assert(writes == writesAfterFirst, "an existing logo is not rewritten on every render")

-- Without a data directory there is nowhere to write it, and the header falls back to a
-- glyph rather than failing to render at all.
mock.pluginDataDir = function()
    return nil
end
rendered = nil
onOpen()
assert(type(rendered) == "table", "the panel still renders with nowhere to write the logo")
assert(not findNode(rendered, function(node)
    return node.kind == "image"
end), "no image node without a path")
assert(findNode(rendered, function(node)
    return node.kind == "glyph" and node.spec.name == "device-gamepad-2"
end), "the glyph stands in for the logo")

print("logo: passed")
