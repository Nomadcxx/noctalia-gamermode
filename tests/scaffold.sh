#!/bin/sh
# Manifest and translation-bundle validation. Run from the repository root.
set -eu

expect() {
    grep -q "$1" "$2" || {
        echo "missing: $1 in $2" >&2
        exit 1
    }
}

expect '^id = "nomadcxx/gamermode"$' gamermode/plugin.toml
expect '^plugin_api = 19$' gamermode/plugin.toml
expect 'entry = "service.luau"' gamermode/plugin.toml
expect 'entry = "panel.luau"' gamermode/plugin.toml
expect 'entry = "widget.luau"' gamermode/plugin.toml

# `icon` and the `glyph` setting default must name glyphs from the shell's registry;
# a filesystem path renders as a missing glyph.
expect '^icon = "device-gamepad-2"$' gamermode/plugin.toml
expect '^default = "device-gamepad-2"$' gamermode/plugin.toml

# Every label_key/description_key in the manifest must resolve in the bundle.
lua -e '
package.path = "./tests/?.lua;" .. package.path
local helpers = require("helpers")

local manifest = assert(io.open("gamermode/plugin.toml")):read("*a")
local bundle = assert(io.open("gamermode/translations/en.json")):read("*a")
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
'

echo "scaffold: passed"
