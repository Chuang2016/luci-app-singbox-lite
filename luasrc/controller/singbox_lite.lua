-- luci/controller/singbox_lite.lua - LuCI pages + JSON API for sing-box-lite
module("luci.controller.singbox_lite", package.seeall)

local LIB = "/usr/lib/singbox_lite"
package.path = LIB .. "/?.lua;" .. package.path

function index()
    if not nixio.fs.access("/etc/config/singbox_lite") then
        return
    end
    entry({"admin", "services", "singbox_lite"},
          firstchild(), _("SingBox Lite"), 60).dependent = false
    entry({"admin", "services", "singbox_lite", "status"},
          template("singbox_lite/status"), _("运行状态"), 1)
    entry({"admin", "services", "singbox_lite", "basic"},
          cbi("singbox_lite/basic"), _("基本设置"), 2)
    entry({"admin", "services", "singbox_lite", "nodes"},
          cbi("singbox_lite/nodes"), _("节点管理"), 3)
    entry({"admin", "services", "singbox_lite", "routing"},
          cbi("singbox_lite/routing"), _("分流规则"), 4)
    -- JSON API (used by the status dashboard)
    entry({"admin", "services", "singbox_lite", "api", "traffic"},
          call("api_traffic")).leaf = true
    entry({"admin", "services", "singbox_lite", "api", "proxies"},
          call("api_proxies")).leaf = true
    entry({"admin", "services", "singbox_lite", "api", "switch"},
          call("api_switch")).leaf = true
    entry({"admin", "services", "singbox_lite", "api", "delay"},
          call("api_delay")).leaf = true
    entry({"admin", "services", "singbox_lite", "api", "service"},
          call("api_service")).leaf = true
    entry({"admin", "services", "singbox_lite", "api", "ruleadd"},
          call("api_ruleadd")).leaf = true
    entry({"admin", "services", "singbox_lite", "api", "mode"},
          call("api_mode")).leaf = true
    entry({"admin", "services", "singbox_lite", "api", "nodestate"},
          call("api_nodestate")).leaf = true
end

local function clash_client()
    local uci = luci.model.uci.cursor()
    local port = tonumber(uci:get("singbox_lite", "main", "clash_port")) or 9090
    local secret = uci:get("singbox_lite", "main", "clash_secret") or ""
    return require("clash").new("127.0.0.1", port, secret)
end

local function json_out(t)
    luci.http.prepare_content("application/json")
    luci.http.write(require("json").encode(t))
end

local function running()
    return luci.sys.call("pgrep -x singbox >/dev/null 2>&1") == 0
end

-- GET .../api/traffic -> {"up":bytes/s,"down":bytes/s,"running":bool}
function api_traffic()
    if not running() then
        json_out({ running = false, up = 0, down = 0 })
        return
    end
    local ok, c = pcall(clash_client)
    if not ok then json_out({ running = true, error = "clash init failed" }) return end
    local r, err = c:traffic_sample()
    if r then
        json_out({ running = true, up = r.up, down = r.down })
    else
        json_out({ running = true, error = err or "traffic failed" })
    end
end

-- GET .../api/proxies -> node list with current selection
function api_proxies()
    local out = { running = running(), groups = {}, nodes = {} }
    if not out.running then json_out(out) return end
    local ok, c = pcall(clash_client)
    if not ok then out.error = "clash init failed"; json_out(out) return end
    local st, body = c:request("GET", "/proxies")
    if st == 200 and body then
        local ok2, data = pcall(require("json").decode, body)
        if ok2 and data and data.proxies then
            for tag, p in pairs(data.proxies) do
                if p.type == "Selector" or p.type == "URLTest" or p.type == "Fallback" then
                    out.groups[#out.groups + 1] = {
                        tag = tag, type = p.type, now = p.now, all = p.all or {} }
                else
                    out.nodes[#out.nodes + 1] = {
                        tag = tag, type = p.type,
                        delay = (p.history and p.history[#p.history] or {}).delay }
                end
            end
        end
    else
        out.error = "proxies failed: " .. tostring(st)
    end
    json_out(out)
end

-- POST .../api/switch?group=proxy&name=<tag> -> switch selector node
function api_switch()
    local group = luci.http.formvalue("group") or "proxy"
    local name = luci.http.formvalue("name")
    if not name or name == "" then
        json_out({ ok = false, error = "missing name" })
        return
    end
    local ok, c = pcall(clash_client)
    if not ok then json_out({ ok = false, error = "clash init failed" }) return end
    local st = c:request("PUT", "/proxies/" .. luci.util.urlencode(group),
                         require("json").encode({ name = name }))
    json_out({ ok = (st == 204 or st == 200) })
end

-- GET .../api/delay?tag=<tag> -> {"delay": ms}
function api_delay()
    local tag = luci.http.formvalue("tag")
    if not tag or tag == "" then
        json_out({ ok = false, error = "missing tag" })
        return
    end
    local ok, c = pcall(clash_client)
    if not ok then json_out({ ok = false, error = "clash init failed" }) return end
    local url = "https://www.gstatic.com/generate_204"
    local st, body = c:request("GET", "/proxies/" .. luci.util.urlencode(tag) ..
        "/delay?url=" .. luci.util.urlencode(url) .. "&timeout=5000")
    if st == 200 and body then
        local ok2, data = pcall(require("json").decode, body)
        if ok2 and data and data.delay then
            json_out({ ok = true, delay = data.delay })
            return
        end
    end
    json_out({ ok = false, error = body or ("http " .. tostring(st)) })
end

-- GET .../api/service?action=start|stop|restart|subupdate -> service control
function api_service()
    local action = luci.http.formvalue("action") or ""
    local r = { ok = false }
    if action == "subupdate" then
        r.ok = luci.sys.call(LIB .. "/subupdate.sh >/tmp/sblite_sub.log 2>&1") == 0
        if r.ok then
            luci.sys.call("/etc/init.d/singbox_lite reload >/dev/null 2>&1")
        end
    elseif action == "start" or action == "stop" or action == "restart" or action == "reload" then
        r.ok = luci.sys.call("/etc/init.d/singbox_lite " .. action .. " >/dev/null 2>&1") == 0
    elseif action == "geoupdate" then
        -- force re-download of remote rule-sets on next start
        luci.sys.call("rm -f /tmp/singbox_lite_cache.db")
        r.ok = luci.sys.call("/etc/init.d/singbox_lite restart >/dev/null 2>&1") == 0
    else
        r.error = "unknown action"
    end
    r.running = running()
    json_out(r)
end

-- POST .../api/ruleadd?type=domain_suffix&value=example.com&outbound=proxy
function api_ruleadd()
    local ftype = luci.http.formvalue("type")
    local fval = luci.http.formvalue("value")
    local fout = luci.http.formvalue("outbound")
    local valid_t = { domain_suffix = 1, domain_keyword = 1, ip_cidr = 1 }
    local valid_o = { proxy = 1, direct = 1, block = 1 }
    if not (valid_t[ftype] and fval and fval ~= "" and valid_o[fout]) then
        json_out({ ok = false, error = "bad params" })
        return
    end
    -- keep the value to a sane charset (domain / cidr)
    if not fval:match("^[%w%._%-%/:]+$") then
        json_out({ ok = false, error = "bad value" })
        return
    end
    local json = require("json")
    local p = "/etc/singbox_lite/rules.json"
    local f = io.open(p, "r")
    local data = { rules = {} }
    if f then
        local ok, d = pcall(json.decode, f:read("*a"))
        f:close()
        if ok and d and d.rules then data = d end
    end
    local rule = { outbound = fout }
    rule[ftype] = { fval }
    data.rules[#data.rules + 1] = rule
    f = io.open(p, "w")
    if not f then json_out({ ok = false, error = "write failed" }) return end
    f:write(json.encode(data))
    f:close()
    luci.sys.call("/etc/init.d/singbox_lite reload >/dev/null 2>&1")
    json_out({ ok = true })
end

-- POST .../api/mode?mode=rule|global|direct
function api_mode()
    local mode = luci.http.formvalue("mode")
    if mode ~= "rule" and mode ~= "global" and mode ~= "direct" then
        json_out({ ok = false, error = "bad mode" })
        return
    end
    luci.sys.call(string.format(
        "uci set singbox_lite.main.mode='%s' && uci commit singbox_lite && /etc/init.d/singbox_lite reload >/dev/null 2>&1",
        mode))
    json_out({ ok = true, mode = mode })
end

-- POST .../api/nodestate?tag=<tag>&enabled=0|1
function api_nodestate()
    local tag = luci.http.formvalue("tag")
    local enabled = luci.http.formvalue("enabled") == "1"
    if not tag or tag == "" then
        json_out({ ok = false, error = "missing tag" })
        return
    end
    local json = require("json")
    local p = "/etc/singbox_lite/nodes.state"
    local f = io.open(p, "r")
    local data = {}
    if f then
        local ok, d = pcall(json.decode, f:read("*a"))
        f:close()
        if ok and type(d) == "table" then data = d end
    end
    data[tag] = { enabled = enabled }
    f = io.open(p, "w")
    if not f then json_out({ ok = false, error = "write failed" }) return end
    f:write(json.encode(data))
    f:close()
    luci.sys.call("/etc/init.d/singbox_lite reload >/dev/null 2>&1")
    json_out({ ok = true })
end
