#!/bin/bash
# scripts/build_ipk.sh - assemble the .ipk in OpenWrt 24.10 format.
#
# NOTE: OpenWrt 24.10 (and iStoreOS 24.10) changed the .ipk container:
#   old (<=23.05): ar archive  of debian-binary + control.tar.gz + data.tar.gz
#   new (24.10+) : gzip'd tar of ./debian-binary + ./control.tar.gz + ./data.tar.gz
# opkg on 24.10 rejects the old ar format ("Malformed package file").
#
# Works SDK-free because luci-app-singbox-lite is pure Lua + shell.
#
# Usage: scripts/build_ipk.sh [output_dir]
# Env:
#   PKG_VERSION  (default 1.0.0)
#   PKG_RELEASE  (default 1)
#   BUNDLE_BIN=1  bundle a sing-box binary at /usr/sbin/singbox (one-step install)
#   BIN_PATH      path to the sing-box binary (required with BUNDLE_BIN=1)
#   BIN_ARCH     architecture label, e.g. x86_64 (default: all; set with BUNDLE_BIN=1)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-$REPO_DIR/dist}"
PKG_NAME="luci-app-singbox-lite"
PKG_VERSION="${PKG_VERSION:-1.0.0}"
PKG_RELEASE="${PKG_RELEASE:-1}"
BUNDLE_BIN="${BUNDLE_BIN:-0}"
ARCH="${BIN_ARCH:-all}"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
DATA="$WORK/data"
CTRL="$WORK/control"
mkdir -p "$DATA" "$CTRL" "$OUT_DIR"

# --- data.tar.gz ---
mkdir -p "$DATA/usr/lib/lua/luci"   # luasrc/* -> /usr/lib/lua/luci/* (luci.mk layout)
cp -r "$REPO_DIR/luasrc/." "$DATA/usr/lib/lua/luci/"
cp -r "$REPO_DIR/root/." "$DATA/"   # root/* -> /
chmod 0755 "$DATA/etc/init.d/singbox_lite"
chmod 0755 "$DATA/usr/lib/singbox_lite/"*.sh
find "$DATA" -name "*.lua" -exec chmod 0644 {} +
if [ "$BUNDLE_BIN" = "1" ]; then
    [ -n "${BIN_PATH:-}" ] || { echo "BIN_PATH required with BUNDLE_BIN=1" >&2; exit 1; }
    [ -x "$BIN_PATH" ] || { echo "BIN_PATH not executable: $BIN_PATH" >&2; exit 1; }
    mkdir -p "$DATA/usr/sbin"
    cp "$BIN_PATH" "$DATA/usr/sbin/singbox"
    chmod 0755 "$DATA/usr/sbin/singbox"
fi

# --- control.tar.gz ---
{
    echo "Package: $PKG_NAME"
    echo "Version: $PKG_VERSION-$PKG_RELEASE"
    echo "Architecture: $ARCH"
    echo "Maintainer: Rocky <rocky@example.com>"
    echo "Section: luci"
    echo "Priority: optional"
    echo "Depends: lua, luci-base, curl, ca-bundle"
    echo "Description: SingBox Lite - lightweight sing-box client for iStoreOS/OpenWrt"
    echo " Multi-protocol share-link import (vless/vmess/trojan/ss/hysteria2/tuic/wireguard),"
    echo " subscriptions, user-editable routing rules, TUN transparent proxy and a live"
    echo " speed dashboard."
    echo "Source: https://github.com/Chuang2016/luci-app-singbox-lite"
} > "$CTRL/control"
echo "/etc/config/singbox_lite" > "$CTRL/conffiles"   # keep user config on upgrade
cat > "$CTRL/postinst" <<'EOF'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
/etc/init.d/singbox_lite enable >/dev/null 2>&1
exit 0
EOF
chmod 0755 "$CTRL/postinst"
cat > "$CTRL/prerm" <<'EOF'
#!/bin/sh
[ "${IPKG_NO_SCRIPT}" = "1" ] && exit 0
/etc/init.d/singbox_lite stop >/dev/null 2>&1
/etc/init.d/singbox_lite disable >/dev/null 2>&1
exit 0
EOF
chmod 0755 "$CTRL/prerm"

# NOTE: keep the ./ prefix on members, like the official 24.10 packages
(cd "$CTRL" && tar -czf "$WORK/control.tar.gz" ./control ./conffiles ./postinst ./prerm)
echo "2.0" > "$WORK/debian-binary"
(cd "$DATA" && tar -czf "$WORK/data.tar.gz" .)

# --- outer .ipk: 24.10 format = gzipped tar (NOT ar) ---
IPK="${PKG_NAME}_${PKG_VERSION}-${PKG_RELEASE}_${ARCH}.ipk"
tar -czf "$OUT_DIR/$IPK" -C "$WORK" ./debian-binary ./control.tar.gz ./data.tar.gz
echo "built: $OUT_DIR/$IPK"
ls -la "$OUT_DIR/$IPK"
