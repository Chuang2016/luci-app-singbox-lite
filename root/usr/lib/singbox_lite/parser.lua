-- parser.lua - share-link subscription parser for luci-app-singbox-lite.
-- Pure Lua 5.1, zero dependencies. Reads share links (one per line) from a
-- file (argv[1]) or stdin, writes sing-box JSON {"outbounds":[...],"endpoints":[...]}.
--
-- Supported schemes: vless, vmess, trojan, ss, hysteria2/hy2, tuic, wireguard.
-- WireGuard emits sing-box >=1.10 style top-level "endpoints".

local json = require('json')

local M = {}

-- percent-decode ----------------------------------------------------------
function M.urldecode(s)
    if not s then return '' end
    s = s:gsub('+', ' ')
    s = s:gsub('%%(%x%x)', function(h) return string.char(tonumber(h, 16)) end)
    return s
end

-- base64 decode (pure lua, tolerant: ignores whitespace, fixes padding) ----
local b64chars = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/'
local b64map = {}
for i = 1, #b64chars do b64map[b64chars:sub(i, i)] = i - 1 end

function M.b64decode(data)
    data = data:gsub('%s+', ''):gsub('[^A-Za-z0-9%+/%=]', '')
    local pad = #data % 4
    if pad > 0 then data = data .. string.rep('=', 4 - pad) end
    local out = {}
    for i = 1, #data, 4 do
        local c1 = b64map[data:sub(i, i)] or 0
        local c2 = b64map[data:sub(i + 1, i + 1)] or 0
        local c3 = b64map[data:sub(i + 2, i + 2)] or 0
        local c4 = b64map[data:sub(i + 3, i + 3)] or 0
        local n = c1 * 262144 + c2 * 4096 + c3 * 64 + c4
        local b1 = math.floor(n / 65536) % 256
        local b2 = math.floor(n / 256) % 256
        local b3 = n % 256
        out[#out + 1] = string.char(b1)
        if data:sub(i + 2, i + 2) ~= '=' then out[#out + 1] = string.char(b2) end
        if data:sub(i + 3, i + 3) ~= '=' then out[#out + 1] = string.char(b3) end
    end
    return table.concat(out)
end

function M.b64decode_urlsafe(data)
    data = data:gsub('-', '+'):gsub('_', '/')
    return M.b64decode(data)
end

-- normalize a base64 key to base64url-unpadded (sing-box reality requirement)
function M.b64_to_urlsafe(s)
    if not s then return s end
    s = s:gsub('%s+', '')
    s = s:gsub('+', '-'):gsub('/', '_'):gsub('=+$', '')
    return s
end

-- query string -> table ----------------------------------------------------
function M.parse_query(qs)
    local q = {}
    if not qs or qs == '' then return q end
    for pair in qs:gmatch('[^&]+') do
        local k, v = pair:match('^([^=]*)=?(.*)$')
        q[M.urldecode(k)] = M.urldecode(v)
    end
    return q
end

-- split "scheme://rest" and fragment --------------------------------------
function M.split_link(link)
    link = link:gsub('^%s+', ''):gsub('%s+$', '')
    local scheme, rest = link:match('^([%w%+%-%.]+)://(.*)$')
    if not scheme then return nil end
    local frag = rest:match('#(.*)$')
    local name = frag and M.urldecode(frag) or ''
    rest = rest:gsub('#.*$', '')
    return scheme:lower(), rest, name
end

-- transport builder shared by vless/vmess/trojan ---------------------------
-- returns transport table or nil for raw tcp
local function build_transport(q)
    local net = (q.type or q.net or 'tcp'):lower()
    local t = nil
    if net == 'ws' or net == 'websocket' then
        t = { type = 'ws', path = q.path or '/', headers = {} }
        if q.host and q.host ~= '' then t.headers.Host = q.host end
        if q.seality then t.max_early_data = tonumber(q.seality) end
        if q.ed and tonumber(q.ed) then t.max_early_data = tonumber(q.ed) end
    elseif net == 'grpc' then
        t = { type = 'grpc', service_name = q.serviceName or q.service_name or '' }
    elseif net == 'httpupgrade' then
        t = { type = 'httpupgrade', path = q.path or '/', host = q.host or '' }
    elseif net == 'xhttp' then
        t = { type = 'xhttp', path = q.path or '/', host = q.host or '' }
    elseif net == 'tcp' and q.headerType == 'http' then
        t = { type = 'http', path = q.path or '/', headers = {} }
        if q.host and q.host ~= '' then t.headers.Host = q.host end
    end
    return t
end

-- tls builder ---------------------------------------------------------------
local function build_tls(q, default_sni)
    local security = (q.security or q.tls or ''):lower()
    if security == '' or security == 'none' then return nil end
    local tls = { enabled = true }
    local sni = q.sni ~= '' and q.sni or q.peer or default_sni
    if sni and sni ~= '' then tls.server_name = sni end
    if q.alpn and q.alpn ~= '' then
        tls.alpn = {}
        for a in q.alpn:gmatch('[^,]+') do tls.alpn[#tls.alpn + 1] = a end
    end
    local fp = q.fp or q.fingerprint
    if fp and fp ~= '' then tls.utls = { enabled = true, fingerprint = fp } end
    if q.allowInsecure == '1' or q.insecure == '1' or q.skip_cert_verify == '1' then
        tls.insecure = true
    end
    if security == 'reality' then
        tls.reality = { enabled = true }
        -- sing-box requires base64url-unpadded public keys; normalize both forms
        if q.pbk and q.pbk ~= '' then tls.reality.public_key = M.b64_to_urlsafe(q.pbk) end
        if q.sid and q.sid ~= '' then tls.reality.short_id = q.sid end
    end
    return tls
end

-- vless://uuid@host:port?params#name ----------------------------------------
local function parse_vless(rest, name)
    local userinfo, hostport, qs = rest:match('^([^@]*)@([^?]*)%??(.*)$')
    if not userinfo then return nil end
    local host, port = hostport:match('^%[?([^%]]*)%]?:(%d+)$')
    if not host then return nil end
    local q = M.parse_query(qs)
    local ob = {
        type = 'vless', tag = name ~= '' and name or ('vless-' .. host),
        server = host, server_port = tonumber(port),
        uuid = M.urldecode(userinfo),
        packet_encoding = q.packetEncoding or nil,
    }
    local flow = q.flow
    if flow and flow ~= '' and flow ~= 'none' then ob.flow = flow end
    local tls = build_tls(q, host)
    if tls then ob.tls = tls end
    local tr = build_transport(q)
    if tr then ob.transport = tr end
    return ob
end

-- vmess://base64(json) -------------------------------------------------------
local function parse_vmess(rest, name)
    local raw = M.b64decode_urlsafe(rest:gsub('#.*$', ''))
    if raw == '' then return nil end
    local ok, v = pcall(json.decode, raw)
    if not ok or type(v) ~= 'table' then return nil end
    local tag = (v.ps and v.ps ~= '') and v.ps or name
    local ob = {
        type = 'vmess', tag = tag ~= '' and tag or 'vmess-node',
        server = v.add or '', server_port = tonumber(v.port) or 0,
        uuid = v.id or '', alter_id = tonumber(v.aid) or 0,
        security = (v.scy and v.scy ~= '') and v.scy or 'auto',
    }
    -- normalize vmess network params into link-style query
    local q = {
        type = v.net, security = (v.tls == 'tls') and 'tls' or 'none',
        path = v.path, host = v.host, sni = v.sni or v.host,
        fp = v.fp, alpn = v.alpn, headerType = v.type,
        serviceName = v.serviceName, allowInsecure = v.allowInsecure,
    }
    local tls = build_tls(q, v.add)
    if tls then ob.tls = tls end
    local tr = build_transport(q)
    if tr then ob.transport = tr end
    return ob
end

-- trojan://password@host:port?params#name ------------------------------------
local function parse_trojan(rest, name)
    local userinfo, hostport, qs = rest:match('^([^@]*)@([^?]*)%??(.*)$')
    if not userinfo then return nil end
    local host, port = hostport:match('^%[?([^%]]*)%]?:(%d+)$')
    if not host then return nil end
    local q = M.parse_query(qs)
    if not q.security or q.security == '' then q.security = 'tls' end
    local ob = {
        type = 'trojan', tag = name ~= '' and name or ('trojan-' .. host),
        server = host, server_port = tonumber(port),
        password = M.urldecode(userinfo),
    }
    local tls = build_tls(q, host)
    if tls then ob.tls = tls end
    local tr = build_transport(q)
    if tr then ob.transport = tr end
    return ob
end

-- ss://... two common forms ---------------------------------------------------
local function parse_ss(rest, name)
    local body = rest
    local method, password, host, port
    -- form 1: ss://base64(method:password)@host:port
    local b64part, hp = body:match('^([^@]*)@([^/]*)$')
    if b64part and hp then
        local decoded = M.b64decode_urlsafe(b64part)
        method, password = decoded:match('^([^:]+):(.*)$')
        host, port = hp:match('^%[?([^%]]*)%]?:(%d+)$')
    end
    -- form 2: ss://base64(method:password@host:port)
    if not method then
        local decoded = M.b64decode_urlsafe(body)
        method, password, host, port =
            decoded:match('^([^:]+):([^@]*)@%[?([^%]]*)%]?:(%d+)')
    end
    -- form 3: ss://method:password@host:port (plain)
    if not method then
        method, password, host, port =
            body:match('^([^:]+):([^@]*)@%[?([^%]]*)%]?:(%d+)')
    end
    if not (method and password and host and port) then return nil end
    return {
        type = 'shadowsocks', tag = name ~= '' and name or ('ss-' .. host),
        server = host, server_port = tonumber(port),
        method = method, password = M.urldecode(password),
    }
end

-- hysteria2://password@host:port?params#name ----------------------------------
local function parse_hysteria2(rest, name)
    local userinfo, hostport, qs = rest:match('^([^@]*)@([^?]*)%??(.*)$')
    if not userinfo then return nil end
    local host, port = hostport:match('^%[?([^%]]*)%]?:(%d+)$')
    if not host then return nil end
    local q = M.parse_query(qs)
    local ob = {
        type = 'hysteria2', tag = name ~= '' and name or ('hy2-' .. host),
        server = host, server_port = tonumber(port),
        password = M.urldecode(userinfo),
    }
    if q['up_mbps'] or q.upmbps then
        ob.up_mbps = tonumber(q['up_mbps'] or q.upmbps)
    end
    if q['down_mbps'] or q.downmbps then
        ob.down_mbps = tonumber(q['down_mbps'] or q.downmbps)
    end
    if q.obfs and q.obfs ~= '' and q.obfs ~= 'none' then
        ob.obfs = { type = q.obfs, password = q['obfs-password'] or '' }
    end
    local tls = { enabled = true }
    local sni = (q.sni and q.sni ~= '') and q.sni or host
    tls.server_name = sni
    if q.insecure == '1' then tls.insecure = true end
    local fp = q['pinSHA256']
    if fp and fp ~= '' then tls.certificate = nil end -- informational only
    ob.tls = tls
    return ob
end

-- tuic://uuid:password@host:port?params#name -----------------------------------
local function parse_tuic(rest, name)
    local userinfo, hostport, qs = rest:match('^([^@]*)@([^?]*)%??(.*)$')
    if not userinfo then return nil end
    local uuid, password = userinfo:match('^([^:]*):?(.*)$')
    local host, port = hostport:match('^%[?([^%]]*)%]?:(%d+)$')
    if not host then return nil end
    local q = M.parse_query(qs)
    local ob = {
        type = 'tuic', tag = name ~= '' and name or ('tuic-' .. host),
        server = host, server_port = tonumber(port),
        uuid = M.urldecode(uuid), password = M.urldecode(password),
    }
    if q.congestion_control and q.congestion_control ~= '' then
        ob.congestion_control = q.congestion_control
    end
    if q.udp_relay_mode and q.udp_relay_mode ~= '' then
        ob.udp_relay_mode = q.udp_relay_mode
    end
    local tls = { enabled = true }
    tls.server_name = (q.sni and q.sni ~= '') and q.sni or host
    if q.alpn and q.alpn ~= '' then
        tls.alpn = {}
        for a in q.alpn:gmatch('[^,]+') do tls.alpn[#tls.alpn + 1] = a end
    end
    if q.allow_insecure == '1' or q.insecure == '1' then tls.insecure = true end
    ob.tls = tls
    return ob
end

-- wireguard://privatekey@host:port?publickey=&...#name --------------------------
-- Emits sing-box >=1.10 top-level endpoint entries.
local function parse_wireguard(rest, name)
    local userinfo, hostport, qs = rest:match('^([^@]*)@([^?]*)%??(.*)$')
    if not userinfo then return nil end
    local host, port = hostport:match('^%[?([^%]]*)%]?:(%d+)$')
    if not host then return nil end
    local q = M.parse_query(qs)
    local pubkey = q.publickey or q.public_key
    if not pubkey or pubkey == '' then return nil end
    local ep = {
        type = 'wireguard', tag = name ~= '' and name or ('wg-' .. host),
        address = {},
        private_key = M.urldecode(userinfo),
        peers = { {
            address = host, port = tonumber(port),
            public_key = pubkey,
            allowed_ips = { '0.0.0.0/0', '::/0' },
        } },
    }
    local addr = q.address or '10.0.0.2/32'
    for a in addr:gmatch('[^,]+') do ep.address[#ep.address + 1] = a end
    if q.presharedkey and q.presharedkey ~= '' then
        ep.peers[1].pre_shared_key = q.presharedkey
    end
    if q.mtu and tonumber(q.mtu) then ep.mtu = tonumber(q.mtu) end
    return ep, true -- second return: is_endpoint
end

local parsers = {
    vless = parse_vless,
    vmess = parse_vmess,
    trojan = parse_trojan,
    ss = parse_ss,
    shadowsocks = parse_ss,
    hysteria2 = parse_hysteria2,
    hy2 = parse_hysteria2,
    tuic = parse_tuic,
    wireguard = parse_wireguard,
}

-- main -----------------------------------------------------------------------
function M.parse_text(text)
    local outbounds, endpoints, seen = {}, {}, {}
    local errors = 0
    for line in (text .. '\n'):gmatch('([^\r\n]*)\n') do
        line = line:gsub('^%s+', ''):gsub('%s+$', '')
        if line ~= '' and not line:match('^%s*[#;]') then
            local scheme, rest, name = M.split_link(line)
            local fn = scheme and parsers[scheme]
            if fn then
                local ok, item, is_ep = pcall(fn, rest, name)
                if ok and item and item.tag and not seen[item.tag] then
                    seen[item.tag] = true
                    if is_ep then endpoints[#endpoints + 1] = item
                    else outbounds[#outbounds + 1] = item end
                else
                    errors = errors + 1
                end
            else
                errors = errors + 1
            end
        end
    end
    return { outbounds = outbounds, endpoints = endpoints }, errors
end

-- CLI: lua parser.lua [input_file] --------------------------------------------
-- Only run when executed directly, not when required() as a module.
local function is_main_script()
    if not (arg and arg[0]) then return false end
    -- match 'parser.lua' as a full path component, not a suffix of e.g. 'test_parser.lua'
    return arg[0] == 'parser.lua' or arg[0]:match('[\\/]parser%.lua$') ~= nil
end

if is_main_script() then
    local text
    if arg[1] then
        local f = io.open(arg[1], 'r')
        if not f then io.stderr:write('cannot open ' .. arg[1] .. '\n'); os.exit(1) end
        text = f:read('*a'); f:close()
    else
        text = io.read('*a')
    end
    local result, errors = M.parse_text(text)
    io.write(json.encode(result))
    if errors > 0 then
        io.stderr:write(string.format('warning: %d line(s) skipped\n', errors))
    end
end

return M
