-- genconfig.lua - build /etc/singbox_lite/config.json from UCI + nodes + rules.
-- Pure Lua 5.1. Usage: lua genconfig.lua [workdir]
-- workdir defaults to /etc/singbox_lite.

local json = require('json')

local DIR = arg and arg[1] or os.getenv('SINGBOX_LITE_DIR') or '/etc/singbox_lite'
local UCI = '/etc/config/singbox_lite'

-- minimal UCI parser (handles our own config file only) ---------------------
local function parse_uci(path)
    local cfg = {}
    local f = io.open(path, 'r')
    if not f then return cfg end
    local cur = nil
    for line in f:lines() do
        line = line:gsub('^%s+', ''):gsub('%s+$', '')
        if line ~= '' and line:sub(1, 1) ~= '#' then
            local t, name = line:match("^config%s+(%S+)%s+'([^']+)'")
            if not t then t, name = line:match('^config%s+(%S+)%s+"([^"]+)"') end
            if not t then t = line:match('^config%s+(%S+)') end
            if t then
                cur = { _type = t, _name = name or ('anon' .. #cfg) }
                cfg[#cfg + 1] = cur
            else
                local k, v = line:match("^option%s+(%S+)%s+'([^']*)'")
                if not k then k, v = line:match('^option%s+(%S+)%s+"([^"]*)"') end
                if not k then k, v = line:match('^option%s+(%S+)%s+(%S+)') end
                if k and cur then cur[k] = v end
                local lk, lv = line:match("^list%s+(%S+)%s+'([^']*)'")
                if lk and cur then
                    cur[lk] = cur[lk] or {}
                    cur[lk][#cur[lk] + 1] = lv
                end
            end
        end
    end
    f:close()
    return cfg
end

local function uci_main(cfg)
    for _, s in ipairs(cfg) do
        if s._type == 'main' then return s end
    end
    return {}
end

local function read_json(path, default)
    local f = io.open(path, 'r')
    if not f then return default end
    local ok, v = pcall(json.decode, f:read('*a'))
    f:close()
    if not ok then return default end
    return v
end

-- strip helper keys (comment / _*) that sing-box would reject ---------------
local function clean_rule(rule)
    local c = {}
    for k, v in pairs(rule) do
        if k ~= 'comment' and k:sub(1, 1) ~= '_' then c[k] = v end
    end
    return c
end

-- main -----------------------------------------------------------------------
local cfg = parse_uci(UCI)
local main = uci_main(cfg)

local mode = main.mode or 'rule'          -- rule | global | direct
local tun_enabled = (main.tun or '1') == '1'
local mixed_port = tonumber(main.mixed_port) or 1080
local clash_port = tonumber(main.clash_port) or 9090
local clash_secret = main.clash_secret or ''
local loglevel = main.loglevel or 'info'

local nodes = read_json(DIR .. '/nodes.json', { outbounds = {}, endpoints = {} })
local state = read_json(DIR .. '/nodes.state', {})

local active_out, active_ep, tags = {}, {}, {}
for _, o in ipairs(nodes.outbounds or {}) do
    local st = state[o.tag]
    if st == nil or st.enabled ~= false then
        active_out[#active_out + 1] = o
        tags[#tags + 1] = o.tag
    end
end
for _, e in ipairs(nodes.endpoints or {}) do
    local st = state[e.tag]
    if st == nil or st.enabled ~= false then
        active_ep[#active_ep + 1] = e
        tags[#tags + 1] = e.tag
    end
end

local outbounds = {
    { type = 'selector', tag = 'proxy', outbounds = {}, default = 'auto' },
    { type = 'urltest', tag = 'auto', outbounds = {}, url = 'https://www.gstatic.com/generate_204', interval = '10m', tolerance = 50 },
    { type = 'direct', tag = 'direct' },
    { type = 'block', tag = 'block' },
}
-- selector/urltest member lists
for _, t in ipairs(tags) do
    outbounds[1].outbounds[#outbounds[1].outbounds + 1] = t
    outbounds[2].outbounds[#outbounds[2].outbounds + 1] = t
end
outbounds[1].outbounds[#outbounds[1].outbounds + 1] = 'direct'
if #tags == 0 then
    -- no nodes: keep selector valid, traffic falls to direct
    outbounds[1].default = 'direct'
    outbounds[2].outbounds = { 'direct' }
end
for _, o in ipairs(active_out) do outbounds[#outbounds + 1] = o end

-- route rules ---------------------------------------------------------------
local route_rules = {}
if mode == 'rule' then
    local rules = read_json(DIR .. '/rules.json', nil)
    if rules and rules.rules then
        for _, r in ipairs(rules.rules) do
            route_rules[#route_rules + 1] = clean_rule(r)
        end
    end
end

local final_outbound = 'proxy'
if mode == 'direct' then final_outbound = 'direct' end

local config = {
    log = { level = loglevel, timestamp = true },
    dns = {
        servers = {
            { tag = 'proxy-dns', type = 'tls', server = '8.8.8.8', detour = 'proxy' },
            { tag = 'direct-dns', type = 'https', server = '223.5.5.5', detour = 'direct' },
        },
        rules = {
            { rule_set = { 'geosite-cn' }, server = 'direct-dns' },
            { clash_mode = 'Global', server = 'proxy-dns' },
            { clash_mode = 'Direct', server = 'direct-dns' },
        },
        final = 'proxy-dns',
        strategy = 'ipv4_only',
    },
    inbounds = {
        { type = 'mixed', tag = 'mixed-in', listen = '127.0.0.1', listen_port = mixed_port },
    },
    outbounds = outbounds,
    route = {
        rules = route_rules,
        rule_set = {
            { tag = 'geosite-cn', type = 'remote', format = 'binary',
              url = 'https://github.com/SagerNet/sing-geosite/releases/latest/download/geosite-cn.srs',
              download_detour = 'direct' },
            { tag = 'geosite-proxy', type = 'remote', format = 'binary',
              url = 'https://github.com/SagerNet/sing-geosite/releases/latest/download/geosite-geolocation-%21cn.srs',
              download_detour = 'direct' },
            { tag = 'geosite-ads', type = 'remote', format = 'binary',
              url = 'https://github.com/SagerNet/sing-geosite/releases/latest/download/geosite-category-ads-all.srs',
              download_detour = 'direct' },
            { tag = 'geoip-cn', type = 'remote', format = 'binary',
              url = 'https://github.com/SagerNet/sing-geoip/releases/latest/download/geoip-cn.srs',
              download_detour = 'direct' },
        },
        final = final_outbound,
        auto_detect_interface = true,
        default_domain_resolver = { server = 'direct-dns', strategy = 'ipv4_only' },
    },
    experimental = {
        cache_file = { enabled = true, path = '/tmp/singbox_lite_cache.db' },
        clash_api = {
            external_controller = '127.0.0.1:' .. clash_port,
            external_ui = '/usr/lib/singbox_lite/ui',
            secret = clash_secret ~= '' and clash_secret or nil,
        },
    },
}

if #active_ep > 0 then config.endpoints = active_ep end

if tun_enabled then
    config.inbounds[#config.inbounds + 1] = {
        type = 'tun', tag = 'tun-in', interface_name = 'tun0',
        address = { '172.19.0.1/30' },
        mtu = 9000, auto_route = true, strict_route = false,
        stack = 'system',
    }
end

local out = io.open(DIR .. '/config.json', 'w')
if not out then
    io.stderr:write('cannot write ' .. DIR .. '/config.json\n')
    os.exit(1)
end
out:write(json.encode(config))
out:close()
print(string.format('wrote %s/config.json (%d outbounds, %d endpoints, mode=%s)',
    DIR, #active_out, #active_ep, mode))
