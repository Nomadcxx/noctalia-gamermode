-- Kill-list parsing: the `targets` advanced setting, with compiled-in defaults as the
-- fallback for unset and malformed values.
package.path = "./tests/?.lua;" .. package.path
local helpers = require("helpers")

local mock = helpers.newNoctalia()
local svc = dofile("gamer-mode/service.luau")

-- Unset falls back to defaults.
local defaults = svc.parseTargets(nil)
assert(type(defaults) == "table" and #defaults > 0, "defaults on nil")
assert(defaults[1].kind and defaults[1].match and defaults[1].profiles, "default entry shape")
assert(#svc.parseTargets("") > 0, "defaults on empty string")

-- Malformed JSON falls back to defaults and says so in the log.
local malformed = svc.parseTargets("not json")
assert(#malformed == #defaults, "defaults on malformed JSON")
assert(#mock.logs > 0, "malformed targets are logged")

-- Defaults are copied, so a caller mutating the returned list cannot corrupt them
-- for the next read.
defaults[1].match = "mutated"
table.remove(defaults[1].profiles)
local fresh = svc.parseTargets(nil)
assert(fresh[1].match ~= "mutated", "defaults must be copied, not shared")
assert(#fresh[1].profiles > 0, "nested profile lists must be copied too")

-- A valid custom list replaces the defaults entirely.
local custom = svc.parseTargets('[{"match":"foo","kind":"process","profiles":["light"]}]')
assert(#custom == 1 and custom[1].match == "foo", "custom list parsed")
assert(custom[1].kind == "process" and custom[1].profiles[1] == "light", "custom entry fields")

-- Invalid entries are dropped individually; the valid remainder is still honoured.
local mixed = svc.parseTargets(
    '[{"match":"a","kind":"bogus","profiles":["light"]},{"match":"b","kind":"process","profiles":["light"]}]'
)
assert(#mixed == 1 and mixed[1].match == "b", "invalid kind dropped")

for _, bad in ipairs({
    '[{"kind":"process","profiles":["light"]}]',
    '[{"match":"","kind":"process","profiles":["light"]}]',
    '[{"match":"a","kind":"process"}]',
    '[{"match":"a","kind":"process","profiles":[]}]',
    '[{"match":"a","kind":"process","profiles":"light"}]',
    '[{"match":"a\nb","kind":"process","profiles":["light"]}]',
    '{"match":"a","kind":"process","profiles":["light"]}',
}) do
    assert(#svc.parseTargets(bad) == #svc.DEFAULT_TARGETS, "rejected, falls back to defaults: " .. bad)
end

-- Profile filtering: heavy is a superset of light, and every filtered entry is tagged.
local all = svc.parseTargets(nil)
local light = svc.targetsForProfile(all, "light")
local heavy = svc.targetsForProfile(all, "heavy")
assert(#light > 0 and #heavy >= #light, "heavy is a superset of light")
for _, target in ipairs(light) do
    local tagged = false
    for _, profile in ipairs(target.profiles) do
        if profile == "light" then
            tagged = true
        end
    end
    assert(tagged, "light selection only returns light-tagged targets")
end
assert(#svc.targetsForProfile(all, "nonexistent") == 0, "unknown profile selects nothing")

-- All four kinds are accepted.
local kinds = svc.parseTargets(
    '[{"match":"a","kind":"process","profiles":["light"]},'
        .. '{"match":"b","kind":"user-service","profiles":["light"]},'
        .. '{"match":"c","kind":"system-service","profiles":["light"]},'
        .. '{"match":"d","kind":"container","profiles":["light"]}]'
)
assert(#kinds == 4, "all four kinds accepted, got " .. #kinds)

print("targets: passed")
