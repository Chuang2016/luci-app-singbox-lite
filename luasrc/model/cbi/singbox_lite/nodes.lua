-- luci/model/cbi/singbox_lite/nodes.lua - 节点管理（订阅 + 手动导入）
m = Map("singbox_lite", translate("SingBox Lite - 节点管理"),
    translate("订阅链接与手动导入的节点都会解析为 sing-box 出站，节点的启用/禁用与切换在「运行状态」页操作。"))

-- subscriptions -------------------------------------------------------------
sub = m:section(TypedSection, "sub", translate("订阅"))
sub.anonymous = true
sub.addremove = true
sub.template = "cbi/tblsection"

u = sub:option(Value, "url", translate("订阅地址"))
u.rmempty = false
u.size = 60

e = sub:option(Flag, "enabled", translate("启用"))
e.default = "1"
e.rmempty = false

up = m:section(SimpleSection)
btn = up:option(Button, "_subupdate", translate("立即更新订阅"))
btn.inputstyle = "apply"
btn.description = translate("从所有启用的订阅拉取节点并重建配置。")
function btn.write(self, section)
    luci.sys.call("/usr/lib/singbox_lite/subupdate.sh >/tmp/sblite_sub.log 2>&1 && /etc/init.d/singbox_lite reload >/dev/null 2>&1")
end

lu = m:section(SimpleSection)
last = lu:option(DummyValue, "_lastupdate", translate("上次更新"))
function last.cfgvalue(self, section)
    local f = io.open("/etc/singbox_lite/sub_updated_at", "r")
    if not f then return translate("从未") end
    local t = tonumber(f:read("*l")) or 0
    f:close()
    return os.date("%Y-%m-%d %H:%M:%S", t)
end

cnt = lu:option(DummyValue, "_nodecount", translate("节点数量"))
function cnt.cfgvalue(self, section)
    local f = io.open("/etc/singbox_lite/nodes.json", "r")
    if not f then return "0" end
    local ok, txt = pcall(f.read, f, "*a")
    f:close()
    if not ok then return "0" end
    local n = 0
    for _ in txt:gmatch('"tag"%s*:') do n = n + 1 end
    return tostring(n)
end

-- manual import --------------------------------------------------------------
mi = m:section(SimpleSection, translate("手动导入"),
    translate("每行一个分享链接，支持 vless / vmess / trojan / ss / hysteria2 / tuic / wireguard。"))
ta = mi:option(TextValue, "_manual", translate("分享链接"))
ta.rows = 8
ta.wrap = "off"
ta.rmempty = true
function ta.cfgvalue(self, section)
    local f = io.open("/etc/singbox_lite/manual.txt", "r")
    if not f then return "" end
    local t = f:read("*a")
    f:close()
    return t or ""
end
function ta.write(self, section, value)
    local f = io.open("/etc/singbox_lite/manual.txt", "w")
    if f then f:write(value or ""); f:close() end
    luci.sys.call("/usr/lib/singbox_lite/subupdate.sh >/tmp/sblite_sub.log 2>&1 && /etc/init.d/singbox_lite reload >/dev/null 2>&1")
end

return m
