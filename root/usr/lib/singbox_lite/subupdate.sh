#!/bin/sh
# subupdate.sh - fetch subscriptions, decode, parse into nodes.json
# Part of luci-app-singbox-lite. Requires: curl, lua, base64.
set -u

DIR=/etc/singbox_lite
LIB=/usr/lib/singbox_lite
TMPD=$(mktemp -d /tmp/sblite_sub.XXXXXX)
trap 'rm -rf "$TMPD"' EXIT INT TERM

log() { logger -t singbox_lite "$1"; echo "$1"; }

fetch_one() {
    # $1 = url, $2 = output file
    curl -fsSL --max-time 30 --retry 2 -A "singbox-lite/1.0" "$1" -o "$2" 2>/dev/null
}

mkdir -p "$DIR"
: > "$TMPD/all.txt"

idx=0
while :; do
    sec=$(uci -q get singbox_lite.@sub[$idx] 2>/dev/null) || break
    enabled=$(uci -q get singbox_lite.@sub[$idx].enabled 2>/dev/null)
    url=$(uci -q get singbox_lite.@sub[$idx].url 2>/dev/null)
    idx=$((idx + 1))
    [ "$enabled" = "1" ] || continue
    [ -n "$url" ] || continue
    f="$TMPD/sub_$idx.txt"
    if fetch_one "$url" "$f"; then
        # v2ray-style subscriptions are base64 blobs of share links
        if grep -q "://" "$f" 2>/dev/null; then
            cat "$f" >> "$TMPD/all.txt"
        else
            dec="$TMPD/dec_$idx.txt"
            if base64 -d "$f" > "$dec" 2>/dev/null && grep -q "://" "$dec" 2>/dev/null; then
                cat "$dec" >> "$TMPD/all.txt"
            else
                log "subscription returned unrecognized content, skipped"
            fi
        fi
        echo "" >> "$TMPD/all.txt"
        log "subscription fetched: ${url%%\?*}"
    else
        log "subscription fetch failed: ${url%%\?*}"
    fi
done

# manually imported links (written by LuCI)
[ -f "$DIR/manual.txt" ] && cat "$DIR/manual.txt" >> "$TMPD/all.txt"

if [ ! -s "$TMPD/all.txt" ]; then
    log "no links collected, keeping existing nodes.json"
    exit 0
fi

if lua "$LIB/parser.lua" "$TMPD/all.txt" > "$DIR/nodes.json.new" 2>"$TMPD/parse.err"; then
    n=$(LUA_PATH="$LIB/?.lua;;" lua -e "local d=require('json').decode(io.open('$DIR/nodes.json.new'):read('*a')); print(#d.outbounds + #d.endpoints)" 2>/dev/null || echo 0)
    mv "$DIR/nodes.json.new" "$DIR/nodes.json"
    date +%s > "$DIR/sub_updated_at"
    log "nodes updated: $n nodes/endpoints"
else
    log "parse failed: $(cat $TMPD/parse.err)"
    exit 1
fi
