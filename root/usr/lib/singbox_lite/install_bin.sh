#!/bin/sh
# install_bin.sh - download the sing-box binary matching this device's arch.
# Usage: install_bin.sh [version]   (version like v1.14.3, or "latest")
# Env: MIRROR - optional URL prefix, e.g. https://gh-proxy.example.com/
set -u

BIN=/usr/sbin/singbox
VER="${1:-v1.14.3}"

arch=$(uname -m)
case "$arch" in
    x86_64)          SARCH=amd64 ;;
    aarch64|arm64)   SARCH=arm64 ;;
    armv7l|armv7*)   SARCH=armv7 ;;
    armv6l|armv6*)   SARCH=armv6 ;;
    mips64*)         SARCH=mips64 ;;
    mips*)           SARCH=mipsle ;;
    i386|i686)       SARCH=386 ;;
    riscv64*)        SARCH=riscv64 ;;
    *) echo "unsupported arch: $arch" >&2; exit 1 ;;
esac

if [ "$VER" = "latest" ]; then
    VER=$(curl -fsSL --max-time 20 https://api.github.com/repos/SagerNet/sing-box/releases/latest \
        | grep -m1 '"tag_name"' | cut -d'"' -f4)
    [ -n "$VER" ] || { echo "cannot resolve latest version" >&2; exit 1; }
fi

name="sing-box-${VER#v}-linux-$SARCH"
url="${MIRROR:-}https://github.com/SagerNet/sing-box/releases/download/$VER/$name.tar.gz"

TMPD=$(mktemp -d /tmp/sblite_bin.XXXXXX)
trap 'rm -rf "$TMPD"' EXIT INT TERM

echo "downloading $url"
curl -fsSL --max-time 120 --retry 2 -o "$TMPD/sb.tgz" "$url" || { echo "download failed" >&2; exit 1; }
tar -xzf "$TMPD/sb.tgz" -C "$TMPD" || { echo "extract failed" >&2; exit 1; }
install -m 755 "$TMPD/$name/sing-box" "$BIN" || { echo "install failed" >&2; exit 1; }
"$BIN" version | head -1
echo "installed to $BIN"
