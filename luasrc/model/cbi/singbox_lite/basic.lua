-- luci/model/cbi/singbox_lite/basic.lua - 基本设置
local uci = luci.model.uci.cursor()

m = Map("singbox_lite", translate("SingBox Lite - 基本设置"),
    translate("轻量 sing-box 客户端：订阅/多协议导入、规则分流、TUN 透明代理。"))

s = m:section(NamedSection, "main", "singbox_lite", translate("服务"))
s.addremove = false

en = s:option(Flag, "enabled", translate("启用"))
en.default = "0"
en.rmempty = false

mode = s:option(ListValue, "mode", translate("运行模式"))
mode:value("rule", translate("规则分流（推荐）"))
mode:value("global", translate("全局代理"))
mode:value("direct", translate("全局直连"))
mode.default = "rule"
mode.description = translate("规则分流使用「分流规则」页的规则；全局模式忽略规则。")

tun = s:option(Flag, "tun", translate("TUN 透明代理"))
tun.default = "1"
tun.description = translate("开启后局域网设备流量自动走代理，无需逐台设置。需要 sing-box 官方二进制（install_bin.sh 下载的版本已包含）。")

mp = s:option(Value, "mixed_port", translate("混合代理端口"))
mp.datatype = "port"
mp.default = "1080"

cp = s:option(Value, "clash_port", translate("控制 API 端口"))
cp.datatype = "port"
cp.default = "9090"
cp.description = translate("仅监听 127.0.0.1，供本页面显示网速/切换节点。")

iv = s:option(ListValue, "update_interval", translate("订阅自动更新"))
iv:value("0", translate("关闭"))
iv:value("6", translate("每 6 小时"))
iv:value("12", translate("每 12 小时"))
iv:value("24", translate("每天"))
iv.default = "24"

ll = s:option(ListValue, "loglevel", translate("日志级别"))
ll:value("debug", "debug"); ll:value("info", "info")
ll:value("warn", translate("warn")); ll:value("error", translate("error"))
ll.default = "info"

-- binary status + install/update
bv = s:option(DummyValue, "_binver", translate("sing-box 版本"))
bv.rawhtml = true
function bv.cfgvalue(self, section)
    local v = luci.sys.exec("/usr/sbin/singbox version 2>/dev/null | head -1"):gsub("\n", "")
    if v == "" then
        return "<span style='color:red'>" .. translate("未安装") .. "</span>"
    end
    return luci.util.pcdata(v)
end

ib = s:option(Button, "_install", translate("安装/更新内核"))
ib.inputstyle = "apply"
ib.description = translate("自动识别 CPU 架构，从 GitHub 下载官方 sing-box。如无法直连 GitHub，可先在路由器上设置 MIRROR 环境变量再点此按钮。")
function ib.write(self, section)
    luci.sys.call("/usr/lib/singbox_lite/install_bin.sh >/tmp/sblite_install.log 2>&1 &")
end

return m
