-- luci/model/cbi/singbox_lite/routing.lua - 分流规则（用户可直接编辑 JSON）
m = Map("singbox_lite", translate("SingBox Lite - 分流规则"),
    translate("规则按顺序匹配，首条命中的规则决定流量去向。可直接编辑 JSON，或用下方快捷添加。"))

r = m:section(SimpleSection)

tv = r:option(TextValue, "_rules", translate("规则 JSON"))
tv.rows = 18
tv.wrap = "off"
tv.rmempty = false
function tv.cfgvalue(self, section)
    local f = io.open("/etc/singbox_lite/rules.json", "r")
    if not f then
        f = io.open("/usr/lib/singbox_lite/rules.default.json", "r")
    end
    if not f then return "" end
    local t = f:read("*a")
    f:close()
    return t or ""
end
function tv.write(self, section, value)
    local f = io.open("/etc/singbox_lite/rules.json", "w")
    if f then f:write(value or ""); f:close() end
    luci.sys.call("/etc/init.d/singbox_lite reload >/dev/null 2>&1")
end
function tv.validate(self, value)
    -- basic JSON sanity check
    local ok = pcall(function()
        local s = value:gsub("%s+", "")
        assert(s:sub(1, 1) == "{", "not an object")
    end)
    if not ok then return nil, translate("不是合法的 JSON 对象") end
    return value
end

rst = r:option(Button, "_restore", translate("恢复默认规则"))
rst.inputstyle = "reset"
function rst.write(self, section)
    luci.sys.call("cp /usr/lib/singbox_lite/rules.default.json /etc/singbox_lite/rules.json && /etc/init.d/singbox_lite reload >/dev/null 2>&1")
end

geo = r:option(Button, "_geoupdate", translate("更新 GEO 数据库"))
geo.inputstyle = "apply"
geo.description = translate("强制重新下载 geosite/geoip 规则集（cn 直连 / 国外代理 / 广告拦截所依赖）。")
function geo.write(self, section)
    luci.sys.call("rm -f /tmp/singbox_lite_cache.db && /etc/init.d/singbox_lite restart >/dev/null 2>&1")
end

-- quick add (handled by template + api/ruleadd) ------------------------------------
q = m:section(SimpleSection)
q.template = "singbox_lite/ruleadd"

return m
