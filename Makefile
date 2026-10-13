# luci-app-singbox-lite - lightweight sing-box client for iStoreOS / OpenWrt
include $(TOPDIR)/rules.mk

PKG_NAME:=luci-app-singbox-lite
PKG_VERSION:=1.0.0
PKG_RELEASE:=1

PKG_LICENSE:=MIT
PKG_MAINTAINER:=Rocky <rocky@example.com>

LUCI_TITLE:=SingBox Lite - 轻量 sing-box 客户端
LUCI_DESCRIPTION:=Fast, dependency-free sing-box client: multi-protocol share-link import, subscriptions, editable routing rules, TUN transparent proxy and a live speed dashboard.
LUCI_DEPENDS:=+lua +luci-base +curl +ca-bundle
LUCI_PKGARCH:=all

include $(TOPDIR)/feeds/luci/luci.mk

# call BuildPackage - OpenWrt buildroot signature
