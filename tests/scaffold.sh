#!/bin/sh
# Manifest and translation-bundle validation. Run from the repository root.
set -eu

expect() {
    grep -q "$1" "$2" || {
        echo "missing: $1 in $2" >&2
        exit 1
    }
}

expect '^id = "nomadcxx/gamer-mode"$' gamer-mode/plugin.toml
expect '^plugin_api = 19$' gamer-mode/plugin.toml
expect 'entry = "service.luau"' gamer-mode/plugin.toml
expect 'entry = "panel.luau"' gamer-mode/plugin.toml
expect 'entry = "widget.luau"' gamer-mode/plugin.toml
expect 'entry = "monitor.luau"' gamer-mode/plugin.toml

# `icon` and the `glyph` setting default must name glyphs from the shell's registry;
# a filesystem path renders as a missing glyph.
expect '^icon = "device-gamepad-2"$' gamer-mode/plugin.toml
expect '^default = "device-gamepad-2"$' gamer-mode/plugin.toml

# Every label_key/description_key in the manifest must resolve in the bundle.
lua -e '
package.path = "./tests/?.lua;" .. package.path
local helpers = require("helpers")

local manifest = assert(io.open("gamer-mode/plugin.toml")):read("*a")
local bundle = assert(io.open("gamer-mode/translations/en.json")):read("*a")
local translations, decodeError = helpers.json.decode(bundle)
assert(type(translations) == "table", "en.json must be valid JSON: " .. tostring(decodeError))

local function lookup(key)
    local node = translations
    for part in key:gmatch("[^.]+") do
        if type(node) ~= "table" then return nil end
        node = node[part]
    end
    return type(node) == "string" and node or nil
end

local checked = 0
for key in manifest:gmatch("label_key = \"([^\"]+)\"") do
    assert(lookup(key), "untranslated label_key: " .. key)
    checked = checked + 1
end
for key in manifest:gmatch("description_key = \"([^\"]+)\"") do
    assert(lookup(key), "untranslated description_key: " .. key)
    checked = checked + 1
end
assert(checked >= 18, "expected the manifest to declare translated settings, saw " .. checked)
assert(lookup("panel.title") and lookup("notify.enabled_title"), "panel/notify strings missing")

-- Every tr()/trp() key in the plugin sources, not just the ones the manifest declares.
-- A missing key renders as the raw key in the UI and nothing else catches it: the panel
-- suite drives the render but asserts on structure, and tr() returning its argument means
-- the label is still a non-empty string.
local sources = { "service", "panel", "widget", "monitor" }
local runtime = 0
for _, name in ipairs(sources) do
    local file = assert(io.open("gamer-mode/" .. name .. ".luau"))
    local code = file:read("*a")
    file:close()
    for call, key in code:gmatch("(tr[p]?)%(\"([%a_.]+)\"") do
        -- `tr("panel.profiles." .. name)` leaves a trailing dot: the prefix names a table
        -- of variants, so check that instead of a string at the prefix itself.
        if key:sub(-1) == "." then
            local node = translations
            for part in key:sub(1, -2):gmatch("[^.]+") do
                node = type(node) == "table" and node[part] or nil
            end
            assert(type(node) == "table" and next(node) ~= nil,
                name .. ".luau: " .. call .. "() builds keys under " .. key .. " but it holds no variants")
        elseif call == "trp" then
            -- Plurals resolve to a table of forms rather than a string, and both forms
            -- have to exist or one count renders as the raw key.
            local node = translations
            for part in key:gmatch("[^.]+") do
                node = type(node) == "table" and node[part] or nil
            end
            assert(type(node) == "table" and type(node.one) == "string" and type(node.other) == "string",
                name .. ".luau: trp() needs `one` and `other` forms at " .. key)
        else
            assert(lookup(key), name .. ".luau: " .. call .. "() uses an untranslated key: " .. key)
        end
        runtime = runtime + 1
    end
end
assert(runtime >= 20, "expected the sources to translate their strings, saw " .. runtime)
'

# Panel cross-field rules, copied from the shell's own manifest validator
# (src/scripting/plugin_manifest.cpp). Breaking one of these makes the shell reject the
# whole manifest at load, and the plugin then cannot be enabled at all -- the export
# aborts partway and nothing materialises, so it is worth catching here.
lua -e '
local manifest = assert(io.open("gamer-mode/plugin.toml")):read("*a")

local VALID_FOCUS = { on_demand = true, exclusive = true, none = true }

-- Split the manifest into [[panel]] blocks so each entry is checked on its own.
local panels = {}
for block in (manifest .. "\n[["):gmatch("%[%[panel%]%](.-)\n%[%[") do
    panels[#panels + 1] = block
end
assert(#panels > 0, "no [[panel]] entry found")

local function field(block, key)
    return block:match("\n%s*" .. key .. "%s*=%s*\"([^\"]+)\"")
        or block:match("\n%s*" .. key .. "%s*=%s*(%a+)")
end

for _, block in ipairs(panels) do
    local id = field(block, "id") or "?"
    local focus = field(block, "keyboard_focus")
    -- The shell defaults dismiss_on_outside_click to TRUE, so an absent key means true.
    local dismiss = field(block, "dismiss_on_outside_click")
    local dismisses = dismiss ~= "false"
    local persistent = field(block, "persistent") == "true"

    if focus then
        assert(VALID_FOCUS[focus], "panel " .. id .. ": keyboard_focus must be on_demand, exclusive or none")
        -- Outside-click dismissal needs either a click shield or a focus grab, and a
        -- panel that never takes focus can have neither.
        assert(not (focus == "none" and dismisses),
            "panel " .. id .. ": keyboard_focus = \"none\" requires dismiss_on_outside_click = false")
    end
    if persistent then
        assert(not dismisses, "panel " .. id .. ": persistent = true requires dismiss_on_outside_click = false")
        assert(focus ~= "exclusive", "panel " .. id .. ": persistent = true conflicts with keyboard_focus exclusive")
    end
end
'

# catalog.toml is what the plugin browser reads, so it must not drift from the manifest.
if [ -f catalog.toml ]; then
    for key in id name version author license icon description plugin_api; do
        manifest_value=$(grep -m1 "^${key} = " gamer-mode/plugin.toml | cut -d' ' -f3-)
        catalog_value=$(grep -m1 "^${key} = " catalog.toml | cut -d' ' -f3-)
        if [ -z "$manifest_value" ] || [ "$manifest_value" != "$catalog_value" ]; then
            echo "catalog.toml drifted from plugin.toml at '${key}':" >&2
            echo "  plugin.toml:  ${manifest_value:-<missing>}" >&2
            echo "  catalog.toml: ${catalog_value:-<missing>}" >&2
            exit 1
        fi
    done
fi

echo "scaffold: passed"
