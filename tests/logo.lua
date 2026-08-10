-- The panel logo exists twice over: as gamer-mode/logo-dark.svg and logo-light.svg, and
-- embedded in panel.luau because no API reports where the plugin directory is. Copies
-- drift, so this pins each of them.
--
-- The two variants are separate files rather than one rewritten path because the shell
-- caches textures by {path, targetSize}: overwriting a single logo.svg on a theme flip
-- would keep serving the previous theme's raster.
package.path = "./tests/?.lua;" .. package.path
local helpers = require("helpers")

local DATA_DIR = "/tmp/gamermode-test-logo"

local function read(path)
    local file = assert(io.open(path, "r"), "missing: " .. path)
    local contents = file:read("*a")
    file:close()
    return contents
end

local dark = read("gamer-mode/logo-dark.svg")
local light = read("gamer-mode/logo-light.svg")
local panelSource = read("gamer-mode/panel.luau")

-- ── the copies agree ──

local variants = {
    { name = "dark", svg = dark, constant = "LOGO_SVG_DARK", file = "gamer-mode/logo-dark.svg" },
    { name = "light", svg = light, constant = "LOGO_SVG_LIGHT", file = "gamer-mode/logo-light.svg" },
}

for _, variant in ipairs(variants) do
    local embedded = panelSource:match("local " .. variant.constant .. " = %[==%[\n(.-)%]==%]")
    assert(embedded, "panel.luau must embed the " .. variant.name .. " logo in a "
        .. variant.constant .. " long-bracket string")
    assert(embedded == variant.svg,
        variant.file .. " and the " .. variant.constant .. " copy in panel.luau have drifted "
            .. "apart; edit the .svg and re-embed it")

    -- A long-bracket string ends at the first matching close, so the payload must not
    -- contain one. If the artwork ever does, the level has to go up and this catches it.
    assert(not variant.svg:find("]==]", 1, true),
        "the " .. variant.name .. " logo would terminate its own long-bracket string")

    -- ── it is usable artwork ──
    assert(variant.svg:find("<svg", 1, true) == 1, variant.name .. " starts with the svg element")
    assert(variant.svg:find("</svg>", 1, true), variant.name .. " closes it")
    assert(variant.svg:find('viewBox="0 0 64 64"', 1, true),
        variant.name .. " carries a viewBox, or it cannot scale in the panel")

    -- Rendered small in a header, so nothing may depend on an external file or a script.
    assert(not variant.svg:find("<script", 1, true), "no script in artwork the shell will render")
    assert(not variant.svg:find("xlink:href", 1, true), "no external references in " .. variant.name)
    assert(not variant.svg:find("<image", 1, true),
        "no embedded raster in " .. variant.name .. " that would blur when scaled")
end

-- The variants must actually differ, or shipping two files buys nothing.
assert(dark ~= light, "the dark and light marks are different artwork")

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

local written = DATA_DIR .. "/logo-dark.svg"
assert(mock.fileExists(written), "the logo is written to the plugin data directory")
assert(read(written) == dark, "and it is the same artwork")

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
