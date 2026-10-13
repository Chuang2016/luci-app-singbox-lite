-- json.lua - minimal JSON encoder/decoder, pure Lua 5.1, no dependencies.
-- Written for luci-app-singbox-lite. Public domain dedication.

local json = {}

local function esc(s)
    return s:gsub('[%z\1-\31\\"]', function(c)
        local m = { ['\\']='\\\\', ['"']='\\"', ['\n']='\\n', ['\r']='\\r', ['\t']='\\t',
                    ['\b']='\\b', ['\f']='\\f' }
        if m[c] then return m[c] end
        return string.format('\\u%04x', c:byte())
    end)
end

local function is_array(t)
    if type(t) ~= 'table' then return false end
    local n = 0
    for k, _ in pairs(t) do
        if type(k) ~= 'number' or k < 1 or k % 1 ~= 0 then return false end
        if k > n then n = k end
    end
    for i = 1, n do if t[i] == nil then return false end end
    return true, n
end

local function encode_val(v, buf)
    local t = type(v)
    if t == 'nil' then
        buf[#buf+1] = 'null'
    elseif t == 'boolean' then
        buf[#buf+1] = v and 'true' or 'false'
    elseif t == 'number' then
        if v ~= v or v == math.huge or v == -math.huge then
            buf[#buf+1] = 'null'
        else
            buf[#buf+1] = tostring(v)
        end
    elseif t == 'string' then
        buf[#buf+1] = '"' .. esc(v) .. '"'
    elseif t == 'table' then
        local arr, n = is_array(v)
        if arr then
            buf[#buf+1] = '['
            for i = 1, n do
                if i > 1 then buf[#buf+1] = ',' end
                encode_val(v[i], buf)
            end
            buf[#buf+1] = ']'
        else
            buf[#buf+1] = '{'
            local first = true
            -- sorted keys for deterministic output
            local keys = {}
            for k, _ in pairs(v) do keys[#keys+1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            for _, k in ipairs(keys) do
                if type(k) == 'string' then
                    if not first then buf[#buf+1] = ',' end
                    first = false
                    buf[#buf+1] = '"' .. esc(k) .. '":'
                    encode_val(v[k], buf)
                end
            end
            buf[#buf+1] = '}'
        end
    else
        buf[#buf+1] = 'null'
    end
end

function json.encode(v)
    local buf = {}
    encode_val(v, buf)
    return table.concat(buf)
end

-- decoder ---------------------------------------------------------------
local function decode_error(str, pos, msg)
    error(string.format('json decode error at %d: %s (near %q)', pos, msg, str:sub(pos, pos + 20)))
end

local space = { [' '] = true, ['\t'] = true, ['\n'] = true, ['\r'] = true }

local function skip_ws(str, pos)
    while space[str:sub(pos, pos)] do pos = pos + 1 end
    return pos
end

local parse_value -- forward

local function parse_string(str, pos)
    pos = pos + 1 -- skip opening quote
    local buf = {}
    while true do
        local c = str:sub(pos, pos)
        if c == '' then decode_error(str, pos, 'unterminated string') end
        if c == '"' then return table.concat(buf), pos + 1 end
        if c == '\\' then
            local e = str:sub(pos + 1, pos + 1)
            local map = { n = '\n', r = '\r', t = '\t', b = '\b', f = '\f', ['\\'] = '\\', ['/'] = '/', ['"'] = '"' }
            if map[e] then
                buf[#buf+1] = map[e]; pos = pos + 2
            elseif e == 'u' then
                local hex = str:sub(pos + 2, pos + 5)
                local code = tonumber(hex, 16)
                if not code then decode_error(str, pos, 'bad \\u escape') end
                -- encode as UTF-8 (BMP only)
                if code < 0x80 then
                    buf[#buf+1] = string.char(code)
                elseif code < 0x800 then
                    buf[#buf+1] = string.char(0xC0 + math.floor(code / 0x40), 0x80 + (code % 0x40))
                else
                    buf[#buf+1] = string.char(0xE0 + math.floor(code / 0x1000),
                                             0x80 + (math.floor(code / 0x40) % 0x40),
                                             0x80 + (code % 0x40))
                end
                pos = pos + 6
            else
                decode_error(str, pos, 'bad escape')
            end
        else
            buf[#buf+1] = c
            pos = pos + 1
        end
    end
end

local function parse_number(str, pos)
    local s, e = str:find('^-?%d+%.?%d*[eE]?[+-]?%d*', pos)
    local num = tonumber(str:sub(s, e))
    if not num then decode_error(str, pos, 'bad number') end
    return num, e + 1
end

local function parse_array(str, pos)
    pos = pos + 1
    local arr = {}
    pos = skip_ws(str, pos)
    if str:sub(pos, pos) == ']' then return arr, pos + 1 end
    while true do
        local v
        v, pos = parse_value(str, pos)
        arr[#arr+1] = v
        pos = skip_ws(str, pos)
        local c = str:sub(pos, pos)
        if c == ']' then return arr, pos + 1 end
        if c ~= ',' then decode_error(str, pos, "expected ',' or ']'") end
        pos = pos + 1
    end
end

local function parse_object(str, pos)
    pos = pos + 1
    local obj = {}
    pos = skip_ws(str, pos)
    if str:sub(pos, pos) == '}' then return obj, pos + 1 end
    while true do
        pos = skip_ws(str, pos)
        if str:sub(pos, pos) ~= '"' then decode_error(str, pos, 'expected string key') end
        local k
        k, pos = parse_string(str, pos)
        pos = skip_ws(str, pos)
        if str:sub(pos, pos) ~= ':' then decode_error(str, pos, "expected ':'") end
        local v
        v, pos = parse_value(str, pos + 1)
        obj[k] = v
        pos = skip_ws(str, pos)
        local c = str:sub(pos, pos)
        if c == '}' then return obj, pos + 1 end
        if c ~= ',' then decode_error(str, pos, "expected ',' or '}'") end
        pos = pos + 1
    end
end

parse_value = function(str, pos)
    pos = skip_ws(str, pos)
    local c = str:sub(pos, pos)
    if c == '{' then return parse_object(str, pos)
    elseif c == '[' then return parse_array(str, pos)
    elseif c == '"' then return parse_string(str, pos)
    elseif c == 't' and str:sub(pos, pos + 3) == 'true' then return true, pos + 4
    elseif c == 'f' and str:sub(pos, pos + 4) == 'false' then return false, pos + 5
    elseif c == 'n' and str:sub(pos, pos + 3) == 'null' then return nil, pos + 4
    elseif c == '-' or c:match('%d') then return parse_number(str, pos)
    else decode_error(str, pos, 'unexpected character') end
end

function json.decode(str)
    local v, pos = parse_value(str, 1)
    pos = skip_ws(str, pos)
    if pos <= #str then decode_error(str, pos, 'trailing data') end
    return v
end

return json
