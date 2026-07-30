-- Shared test harness: a `noctalia` mock that mirrors the Noctalia 5 luau plugin API
-- (plugin_api 19) closely enough to exercise the plugin under plain `lua`.
--
-- The plugin runs inside Luau's sandbox, which has no `io`, no `os.execute`/`os.remove`
-- and no `load`. Every filesystem and shell touch therefore goes through the noctalia
-- bindings, and this harness backs those bindings with the real filesystem so tests
-- exercise the same code paths the shell will.

local helpers = {}

-- ── JSON ──
-- Stands in for noctalia.json, which is nlohmann-backed in the shell.

local json = {}

local ESCAPES = {
    ['"'] = '\\"',
    ["\\"] = "\\\\",
    ["\b"] = "\\b",
    ["\f"] = "\\f",
    ["\n"] = "\\n",
    ["\r"] = "\\r",
    ["\t"] = "\\t",
}

local function encodeString(value)
    return '"' .. value:gsub('[%c"\\]', function(char)
        return ESCAPES[char] or string.format("\\u%04x", char:byte())
    end) .. '"'
end

local function encodeValue(value)
    local kind = type(value)
    if value == nil then
        return "null"
    elseif kind == "boolean" then
        return tostring(value)
    elseif kind == "number" then
        if value % 1 == 0 then
            return string.format("%d", value)
        end
        return string.format("%.14g", value)
    elseif kind == "string" then
        return encodeString(value)
    elseif kind ~= "table" then
        error("cannot encode " .. kind)
    end

    if #value > 0 then
        local parts = {}
        for _, item in ipairs(value) do
            parts[#parts + 1] = encodeValue(item)
        end
        return "[" .. table.concat(parts, ",") .. "]"
    end

    local keys = {}
    for key in pairs(value) do
        keys[#keys + 1] = tostring(key)
    end
    table.sort(keys)
    local parts = {}
    for _, key in ipairs(keys) do
        parts[#parts + 1] = encodeString(key) .. ":" .. encodeValue(value[key])
    end
    return "{" .. table.concat(parts, ",") .. "}"
end

function json.encode(value)
    local ok, encoded = pcall(encodeValue, value)
    if not ok then
        return nil, tostring(encoded)
    end
    return encoded
end

local parseValue

local function skipSpace(text, position)
    local _, stop = text:find("^[ \t\r\n]*", position)
    return stop + 1
end

local UNESCAPES = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function parseString(text, position)
    if text:sub(position, position) ~= '"' then
        error("expected string at " .. position)
    end
    position = position + 1
    local parts = {}
    while true do
        local char = text:sub(position, position)
        if char == "" then
            error("unterminated string")
        elseif char == '"' then
            return table.concat(parts), position + 1
        elseif char == "\\" then
            local escape = text:sub(position + 1, position + 1)
            if escape == "u" then
                local hex = text:sub(position + 2, position + 5)
                if not hex:match("^%x%x%x%x$") then
                    error("bad unicode escape")
                end
                parts[#parts + 1] = utf8.char(tonumber(hex, 16))
                position = position + 6
            else
                local literal = UNESCAPES[escape]
                if not literal then
                    error("bad escape \\" .. escape)
                end
                parts[#parts + 1] = literal
                position = position + 2
            end
        else
            parts[#parts + 1] = char
            position = position + 1
        end
    end
end

local function parseArray(text, position)
    position = skipSpace(text, position + 1)
    local out = {}
    if text:sub(position, position) == "]" then
        return out, position + 1
    end
    while true do
        local value
        value, position = parseValue(text, position)
        out[#out + 1] = value
        position = skipSpace(text, position)
        local char = text:sub(position, position)
        if char == "]" then
            return out, position + 1
        elseif char ~= "," then
            error("expected , or ] at " .. position)
        end
        position = skipSpace(text, position + 1)
    end
end

local function parseObject(text, position)
    position = skipSpace(text, position + 1)
    local out = {}
    if text:sub(position, position) == "}" then
        return out, position + 1
    end
    while true do
        local key
        key, position = parseString(text, position)
        position = skipSpace(text, position)
        if text:sub(position, position) ~= ":" then
            error("expected : at " .. position)
        end
        local value
        value, position = parseValue(text, skipSpace(text, position + 1))
        out[key] = value
        position = skipSpace(text, position)
        local char = text:sub(position, position)
        if char == "}" then
            return out, position + 1
        elseif char ~= "," then
            error("expected , or } at " .. position)
        end
        position = skipSpace(text, position + 1)
    end
end

parseValue = function(text, position)
    local char = text:sub(position, position)
    if char == "{" then
        return parseObject(text, position)
    elseif char == "[" then
        return parseArray(text, position)
    elseif char == '"' then
        return parseString(text, position)
    elseif text:sub(position, position + 3) == "true" then
        return true, position + 4
    elseif text:sub(position, position + 4) == "false" then
        return false, position + 5
    elseif text:sub(position, position + 3) == "null" then
        return nil, position + 4
    end
    local number = text:match("^%-?%d+%.?%d*[eE]?[-+]?%d*", position)
    if number and tonumber(number) then
        return tonumber(number), position + #number
    end
    error("unexpected character at " .. position)
end

function json.decode(text)
    local ok, value, position = pcall(function()
        local result, stop = parseValue(text, skipSpace(text, 1))
        return result, stop
    end)
    if not ok then
        return nil, tostring(value)
    end
    if skipSpace(text, position) <= #text then
        return nil, "trailing content"
    end
    return value
end

helpers.json = json

-- ── noctalia mock ──

local DEFAULT_STATS = {
    cpu = { usagePercent = 25, tempC = 58.5 },
    ram = { usagePercent = 50, usedMb = 16384, totalMb = 32768 },
    swap = { usedMb = 0, totalMb = 8192 },
    gpu = { usagePercent = 18, tempC = 61, vramUsedBytes = 2726297600, vramTotalBytes = 8585740288 },
    loadAvg = { 1.2, 1.1, 0.9 },
}

function helpers.copy(value)
    if type(value) ~= "table" then
        return value
    end
    local out = {}
    for key, item in pairs(value) do
        out[key] = helpers.copy(item)
    end
    return out
end

-- newNoctalia installs the mock as the `noctalia` global and returns it so tests can
-- inspect `.published`, `.commands`, `.logs` and `.notifications` after acting.
--
-- opts.config    table of setting key -> value for getConfig
-- opts.stats     systemStats() return value (false means "monitor unavailable" -> nil)
-- opts.dataDir   pluginDataDir() return value
-- opts.respond   function(command) -> result table, to script runAsync outcomes
-- opts.startFail function(command) -> boolean, to simulate runAsync capacity refusal
function helpers.newNoctalia(opts)
    opts = opts or {}
    local dataDir = opts.dataDir or "/tmp/gamermode-test"

    local mock = {
        published = {},
        commands = {},
        logs = {},
        notifications = {},
        watchers = {},
        config = opts.config or {},
        stats = opts.stats == nil and helpers.copy(DEFAULT_STATS) or opts.stats,
        respond = opts.respond,
        startFail = opts.startFail,
        clock = 1000,
        -- Served from /proc/sys/kernel/random/boot_id so tests can simulate a reboot.
        -- Explicit `false` simulates an unreadable boot id, so this cannot use `or`.
        bootId = opts.bootId == nil and "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" or opts.bootId,
    }

    local function ok(result)
        return setmetatable(result or {}, {
            __index = { exitCode = 0, stdout = "", stderr = "", timedOut = false },
        })
    end

    mock.json = json

    mock.state = {
        get = function(key)
            return mock.published[key]
        end,
        set = function(key, value)
            mock.published[key] = value
            for _, watcher in ipairs(mock.watchers[key] or {}) do
                watcher(value)
            end
        end,
        watch = function(key, callback)
            mock.watchers[key] = mock.watchers[key] or {}
            table.insert(mock.watchers[key], callback)
        end,
    }

    mock.getConfig = function(key)
        return mock.config[key]
    end

    mock.systemStats = function()
        return mock.stats or nil
    end

    mock.runAsync = function(command, callback, _timeoutMs)
        table.insert(mock.commands, command)
        if mock.startFail and mock.startFail(command) then
            return false
        end
        if callback then
            callback(ok(mock.respond and mock.respond(command) or nil))
        end
        return true
    end

    mock.readFile = function(path)
        -- The kernel boot id is served from the mock so tests can simulate a reboot.
        if path == "/proc/sys/kernel/random/boot_id" then
            if mock.bootId == false then
                return nil, "unreadable"
            end
            return mock.bootId .. "\n"
        end
        local file = io.open(path, "r")
        if not file then
            return nil, "not found"
        end
        local contents = file:read("*a")
        file:close()
        return contents
    end

    mock.writeFile = function(path, contents)
        local file = io.open(path, "w")
        if not file then
            return nil, "not writable"
        end
        file:write(contents)
        file:close()
        return true
    end

    mock.removeFile = function(path)
        return os.remove(path) and true or false
    end

    mock.renameFile = function(from, to)
        return os.rename(from, to) and true or false
    end

    mock.fileExists = function(path)
        local file = io.open(path, "r")
        if not file then
            return false
        end
        file:close()
        return true
    end

    mock.mkdirAll = function(path)
        os.execute("mkdir -p '" .. path:gsub("'", "'\\''") .. "'")
        return true
    end

    mock.pluginDataDir = function()
        return dataDir
    end

    mock.commandExists = function(name)
        return opts.missingCommands == nil or not opts.missingCommands[name]
    end

    mock.nowMs = function()
        mock.clock = mock.clock + 1
        return mock.clock
    end

    mock.log = function(message)
        table.insert(mock.logs, tostring(message))
    end

    mock.notify = function(title, body)
        table.insert(mock.notifications, { title = title, body = body, kind = "info" })
    end

    mock.notifyError = function(title, body)
        table.insert(mock.notifications, { title = title, body = body, kind = "error" })
    end

    mock.setUpdateInterval = function(intervalMs)
        mock.updateIntervalMs = intervalMs
    end

    mock.tr = function(key)
        return key
    end

    mock.trp = function(key, count)
        return key .. ":" .. tostring(count)
    end

    mock.trim = function(value)
        return (tostring(value):gsub("^%s+", ""):gsub("%s+$", ""))
    end

    mock.togglePanel = function(id)
        mock.toggledPanel = id
    end

    mock.openSettings = function()
        mock.settingsOpened = true
    end

    mock.outputs = function()
        return {}
    end

    _G.noctalia = mock
    return mock
end

-- ranCommand reports whether any runAsync command contained `needle`.
function helpers.ranCommand(mock, needle)
    for _, command in ipairs(mock.commands) do
        if command:find(needle, 1, true) then
            return true
        end
    end
    return false
end

function helpers.resetDir(path)
    os.execute("rm -rf '" .. path .. "' && mkdir -p '" .. path .. "'")
end

return helpers
