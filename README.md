# luci-app-singbox-lite

轻量、快速的 iStoreOS / OpenWrt sing-box 客户端插件。零 Python/Node 依赖：纯 Lua + Shell，单进程运行，配置秒级生成。

[English](#english) | 中文

## 功能

- **多协议导入**：粘贴分享链接或订阅，一键解析
  - `vless://`（含 REALITY / Vision / WS / gRPC / HTTPUpgrade）
  - `vmess://`、`trojan://`、`ss://`（三种常见写法）
  - `hysteria2://`、`tuic://`、`wireguard://`（自动映射为 sing-box 1.10+ endpoints）
- **订阅功能**：多个订阅地址，自动识别 base64 / 明文，定时自动更新（6h / 12h / 24h）
- **分流规则**：默认国内直连 / 国外代理 / 广告拦截，规则 JSON 可直接编辑，支持快捷添加（域名后缀/关键字/IP 段 → 代理/直连/拦截），一键恢复默认
- **运行模式**：规则分流 / 全局代理 / 全局直连，仪表盘一键切换
- **TUN 透明代理**：局域网设备免配置自动走代理
- **可视化界面**：实时上下行网速 + 流量曲线、节点列表、延迟测试、一键切换节点、启用/禁用节点、服务启停
- **自动测速选优**：`auto` 分组每 10 分钟优选最低延迟节点

## 安装

### 方法一：ipk 安装（推荐）

```bash
# 在 OpenWrt buildroot / SDK 中
cp -r luci-app-singbox-lite package/
make package/luci-app-singbox-lite/compile
# 将 bin/packages/.../luci-app-singbox-lite_1.0.0-1_all.ipk 传到路由器
opkg install luci-app-singbox-lite_1.0.0-1_all.ipk
```

### 方法二：手动安装

```bash
scp -r luasrc/* root@router:/usr/lib/lua/luci/
scp -r root/* root@router:/
/etc/init.d/singbox_lite enable
```

### 安装 sing-box 内核

插件不打包二进制（体积原因），首次使用在「基本设置」页点「安装/更新内核」，
或 SSH 执行：

```bash
/usr/lib/singbox_lite/install_bin.sh        # 安装 v1.14.3（默认）
/usr/lib/singbox_lite/install_bin.sh latest # 跟踪最新版
MIRROR=https://gh-proxy.example.com/ /usr/lib/singbox_lite/install_bin.sh  # 经代理下载
```

脚本自动识别 CPU 架构（x86_64 / aarch64 / armv7 / mips…）。

## 目录结构

```
luci-app-singbox-lite/
├── Makefile
├── luasrc/
│   ├── controller/singbox_lite.lua      # 页面路由 + JSON API（网速/节点/规则）
│   ├── model/cbi/singbox_lite/
│   │   ├── basic.lua                    # 基本设置
│   │   ├── nodes.lua                    # 订阅 + 手动导入
│   │   └── routing.lua                  # 分流规则编辑
│   └── view/singbox_lite/
│       ├── status.htm                   # 可视化仪表盘（网速曲线/节点管理）
│       └── ruleadd.htm                  # 快捷添加规则
└── root/
    ├── etc/config/singbox_lite          # UCI 配置
    ├── etc/init.d/singbox_lite          # procd 服务
    └── usr/lib/singbox_lite/
        ├── parser.lua                   # 分享链接解析器（纯 Lua，7 种协议）
        ├── genconfig.lua                # 配置生成器（UCI + 节点 + 规则 → config.json）
        ├── clash.lua                    # clash API 客户端（HTTP + WebSocket）
        ├── json.lua                     # 极简 JSON 库（纯 Lua）
        ├── subupdate.sh                 # 订阅更新
        ├── install_bin.sh               # 内核下载安装
        └── rules.default.json           # 默认分流规则
```

## 工作原理

```
订阅 URL / 手动链接
      │ subupdate.sh (curl 取回 → base64 解码)
      ▼
parser.lua ──→ nodes.json {outbounds, endpoints}
      │ genconfig.lua + UCI 设置 + rules.json（用户可改）
      ▼
/etc/singbox_lite/config.json ──→ sing-box run
      │ experimental.clash_api (127.0.0.1:9090)
      ▼
LuCI 仪表盘：WebSocket /traffic 实时网速，REST 切换节点/测速
```

## 测试

```bash
cd luci-app-singbox-lite
LUA_PATH="$PWD/root/usr/lib/singbox_lite/?.lua;;" lua5.1 tests/test_parser.lua
# 23 项断言，覆盖 7 种协议；生成的 config.json 已用 sing-box 1.14.3 真机 check 通过
```

## 注意事项

- sing-box ≥ 1.10 的 WireGuard 为顶层 `endpoints`，本插件已适配
- reality `public_key` 会自动归一化为 sing-box 要求的 base64url 无填充格式
- clash API 仅监听 127.0.0.1，仪表盘经 LuCI 会话代理访问，不暴露到局域网

## English

A fast, lightweight sing-box client plugin for iStoreOS / OpenWrt. Zero Python/Node
dependencies — pure Lua + shell, single process, instant config generation.

Features: multi-protocol share-link import (vless/vmess/trojan/ss/hysteria2/tuic/wireguard),
subscriptions with auto-update, user-editable routing rules (CN direct / foreign proxy /
adblock defaults), TUN transparent proxy, and a live dashboard (real-time speed graph,
node list, latency test, one-click switching).

See [中文](#luci-app-singbox-lite) above for install instructions.

## License

MIT
