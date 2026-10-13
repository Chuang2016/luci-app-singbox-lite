-- clash.lua - minimal sing-box clash API client over nixio sockets.
-- Provides plain HTTP REST plus a WebSocket reader for GET /traffic.
-- Used by the LuCI controller; LuCI runs as Lua 5.1 with nixio on OpenWrt.
local nixio = require "nixio"

local M = {}
M.__index = M

function M.new(host, port, secret)
    return setmetatable({ host = host or "127.0.0.1", port = port or 9090,
                          secret = secret or "" }, M)
end

-- base64 encode (for the WS handshake key) ---------------------------------
local b64c = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local function b64encode(data)
    local out = {}
    for i = 1, #data, 3 do
        local a, b, c = data:byte(i, i + 2)
        b = b or 0; c = c or 0
        local n = a * 65536 + b * 256 + c
        out[#out + 1] = b64c:sub(math.floor(n / 262144) + 1, math.floor(n / 262144) + 1)
        out[#out + 1] = b64c:sub(math.floor(n / 4096) % 64 + 1, math.floor(n / 4096) % 64 + 1)
        out[#out + 1] = (i + 1 <= #data) and b64c:sub(math.floor(n / 64) % 64 + 1, math.floor(n / 64) % 64 + 1) or '='
        out[#out + 1] = (i + 2 <= #data) and b64c:sub(n % 64 + 1, n % 64 + 1) or '='
    end
    return table.concat(out)
end

local function connect(self, timeout)
    local sock = nixio.socket("inet", "stream")
    if not sock then return nil, "socket failed" end
    sock:settimeout(timeout or 5)
    local ok, err = sock:connect(self.host, self.port)
    if not ok then sock:close(); return nil, err or "connect failed" end
    return sock
end

local function auth_header(self)
    if self.secret and self.secret ~= "" then
        return "Authorization: Bearer " .. self.secret .. "\r\n"
    end
    return ""
end

-- read until delimiter -------------------------------------------------------
local function read_until(sock, delim, maxlen)
    maxlen = maxlen or 65536
    local buf = {}
    local total = 0
    while total < maxlen do
        local chunk = sock:recv(4096)
        if not chunk or #chunk == 0 then break end
        buf[#buf + 1] = chunk
        total = total + #chunk
        local s = table.concat(buf)
        local a, b = s:find(delim, 1, true)
        if a then return s:sub(1, b), s:sub(b + 1) end
    end
    return nil, "timeout or closed"
end

local function read_exact(sock, n)
    local buf = {}
    local got = 0
    while got < n do
        local chunk = sock:recv(n - got)
        if not chunk or #chunk == 0 then return nil end
        buf[#buf + 1] = chunk
        got = got + #chunk
    end
    return table.concat(buf)
end

-- plain HTTP request ----------------------------------------------------------
function M:request(method, path, body)
    local sock, err = connect(self)
    if not sock then return nil, err end
    local req = method .. " " .. path .. " HTTP/1.1\r\n" ..
                "Host: " .. self.host .. "\r\n" .. auth_header(self) ..
                "Connection: close\r\n"
    if body then
        req = req .. "Content-Type: application/json\r\n" ..
                    "Content-Length: " .. #body .. "\r\n"
    end
    req = req .. "\r\n" .. (body or "")
    sock:sendall(req)
    local head, rest = read_until(sock, "\r\n\r\n")
    if not head then sock:close(); return nil, rest end
    local status = tonumber(head:match("^HTTP/%d%.%d%s+(%d+)"))
    local chunks = { rest or "" }
    while true do
        local c = sock:recv(8192)
        if not c or #c == 0 then break end
        chunks[#chunks + 1] = c
    end
    sock:close()
    return status, table.concat(chunks)
end

-- WebSocket /traffic sampler ---------------------------------------------------
-- Returns {up=bytes_per_sec, down=bytes_per_sec} averaged over ~2.5s.
function M:traffic_sample()
    local sock, err = connect(self, 6)
    if not sock then return nil, err end
    -- random 16-byte key (validity of the key itself is not verified by us)
    local rnd = {}
    local ur = io.open("/dev/urandom", "rb")
    if ur then rnd = { ur:read(16) }; ur:close() end
    local key = b64encode(rnd[1] or "0123456789abcdef")
    local req = "GET /traffic HTTP/1.1\r\n" ..
                "Host: " .. self.host .. "\r\n" .. auth_header(self) ..
                "Upgrade: websocket\r\nConnection: Upgrade\r\n" ..
                "Sec-WebSocket-Key: " .. key .. "\r\n" ..
                "Sec-WebSocket-Version: 13\r\n\r\n"
    sock:sendall(req)
    local head = read_until(sock, "\r\n\r\n", 8192)
    if not head or not head:find(" 101 ") then
        sock:close()
        return nil, "websocket handshake failed"
    end
    local samples = {}
    local deadline = nixio.time() + 3
    sock:settimeout(4)
    while nixio.time() < deadline and #samples < 4 do
        local hdr = read_exact(sock, 2)
        if not hdr then break end
        local b1, b2 = hdr:byte(1, 2)
        local opcode = b1 % 16
        local len = b2 % 128
        if b2 >= 128 then break end -- server frames must not be masked
        if len == 126 then
            local ext = read_exact(sock, 2)
            if not ext then break end
            len = ext:byte(1) * 256 + ext:byte(2)
        elseif len == 127 then
            local ext = read_exact(sock, 8)
            if not ext then break end
            len = 0
            for i = 5, 8 do len = len * 256 + ext:byte(i) end
        end
        if opcode == 8 then break end -- close frame
        local payload = len > 0 and read_exact(sock, len) or ""
        if not payload then break end
        if opcode == 1 then
            local up = payload:match('"up"%s*:%s*(%d+)')
            local down = payload:match('"down"%s*:%s*(%d+)')
            if up and down then
                samples[#samples + 1] = { up = tonumber(up), down = tonumber(down) }
            end
        end
    end
    sock:close()
    if #samples == 0 then return nil, "no traffic data" end
    -- sing-box sends per-second counters; average the last samples
    local up, down, n = 0, 0, 0
    for i = math.max(1, #samples - 2), #samples do
        up = up + samples[i].up; down = down + samples[i].down; n = n + 1
    end
    return { up = math.floor(up / n), down = math.floor(down / n) }
end

return M
