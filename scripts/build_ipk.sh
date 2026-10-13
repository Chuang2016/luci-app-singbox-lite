#!/bin/bash
# scripts/build_ipk.sh - assemble the .ipk without the OpenWrt buildroot.
# Works because luci-app-singbox-lite is PKGARCH=all (pure Lua + shell).
# Usage: scripts/build_ipk.sh [output_dir]
# Env: PKG_VERSION (default 1.0.0), PKG_RELEASE (default 1)
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
OUT_DIR="${1:-$REPO_DIR/dist}"
PKG_NAME="luci-app-singbox-lite"
PKG_VERSION="${PKG_VERSION:-1.0.0}"
PKG_RELEASE="${PKG_RELEASE:-1}"
ARCH="all"

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
DATA="$WORK/data"
CTRL="$WORK/control"
mkdir -p "$DATA" "$CTRL" "$OUT_DIR"

# --- data.tar.gz ---
# luasrc/* -> /usr/lib/lua/luci/*   (luci.mk layout)
mkdir -p "$DATA/usr/lib/lua/luci"
cp -r "$REPO_DIR/luasrc/." "$DATA/usr/lib/lua/luci/"
# root/* -> /
cp -r "$REPO_DIR/root/." "$DATA/"
# keep service + helpers executable
chmod 0755 "$DATA/etc/init.d/singbox_lite"
chmod 0755 "$DATA/usr/lib/singbox_lite/"*.sh
find "$DATA" -name "*.lua" -exec chmod 0644 {} +

# --- control.tar.gz ---
cat > "$CTRL/control" <<EOF
Package: $PKG_NAME
Version: $PKG_VERSION-$PKG_RELEASE
Architecture: $ARCH
Maintainer: Rocky <rocky@example.com>
Section: luci
Priority: optional
Depends: lua, luci-base, curl, ca-bundle
Description: SingBox Lite - lightweight sing-box client for iStoreOS/OpenWrt
 Multi-protocol share-link import (vless/vmess/trojan/ss/hysteria2/tuic/wireguard),
 subscriptions, user-editable routing rules, TUN transparent proxy and a live
 speed dashboard.
Source: https://github.com/Chuang2016/luci-app-singbox-lite
EOF
# keep user config across upgrades
echo "/etc/config/singbox_lite" > "$CTRL/conffiles"
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

(cd "$CTRL" && tar -czf "$WORK/control.tar.gz" ./control ./conffiles ./postinst ./prerm)
echo "2.0" > "$WORK/debian-binary"
(cd "$DATA" && tar -czf "$WORK/data.tar.gz" .)

IPK="${PKG_NAME}_${PKG_VERSION}-${PKG_RELEASE}_${ARCH}.ipk"
(cd "$WORK" && ar r "$IPK" debian-binary control.tar.gz data.tar.gz)
cp "$WORK/$IPK" "$OUT_DIR/"
echo "built: $OUT_DIR/$IPK"
ls -la "$OUT_DIR/$IPK"
