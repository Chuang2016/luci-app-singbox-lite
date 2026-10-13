-- tests/test_parser.lua - run: cd root/usr/lib/singbox_lite && lua5.1 ../../../tests/test_parser.lua
package.path = './?.lua;' .. package.path
local parser = require('parser')
local json = require('json')

local LINKS = {
  'vless://11111111-2222-3333-4444-555555555555@1.2.3.4:443?encryption=none&security=reality&sni=www.microsoft.com&fp=chrome&pbk=PUBKEY123&sid=abc123&type=tcp&flow=xtls-rprx-vision#VLESS-Reality',
  'vless://22222222-2222-3333-4444-555555555555@cdn.example.com:443?encryption=none&security=tls&sni=cdn.example.com&type=ws&path=%2Fray&host=cdn.example.com#VLESS-WS',
  'vmess://eyJ2IjogIjIiLCAicHMiOiAiVk1FU1MtV1MiLCAiYWRkIjogIjIuMi4yLjIiLCAicG9ydCI6ICI4MCIsICJpZCI6ICJhYWFhYWFhYS1iYmJiLWNjY2MtZGRkZC1lZWVlZWVlZWVlZWUiLCAiYWlkIjogIjAiLCAic2N5IjogImF1dG8iLCAibmV0IjogIndzIiwgInR5cGUiOiAibm9uZSIsICJob3N0IjogIiIsICJwYXRoIjogIi92bWVzcyIsICJ0bHMiOiAiIn0=#ignored',
  'trojan://password123@3.3.3.3:443?sni=trojan.example.com#Trojan-TLS',
  'ss://YWVzLTI1Ni1nY206cGFzc3dvcmQ=@4.4.4.4:8388#SS-AES',
  'ss://YWVzLTEyOC1nY206cHdkQDUuNS41LjU6ODM4OA==#SS-FULL',
  'hysteria2://letmein@6.6.6.6:443?sni=hy2.example.com&insecure=1#HY2',
  'tuic://uuid-1234:pass5678@7.7.7.7:443?congestion_control=bbr&sni=tuic.example.com&alpn=h3#TUIC',
  'wireguard://cHJpdmF0ZWtleQ==@8.8.8.8:51820?publickey=cHVibGlja2V5&address=10.66.66.2/32#WG-Home',
  '# this is a comment',
  '',
  'not-a-link',
}

local fails = 0
local function check(cond, msg)
  if cond then print('PASS ' .. msg)
  else fails = fails + 1; print('FAIL ' .. msg) end
end

local result, errs = parser.parse_text(table.concat(LINKS, '\n'))
check(errs == 1, 'exactly 1 bad line skipped (got ' .. errs .. ')')
check(#result.outbounds == 8, '8 outbounds parsed (got ' .. #result.outbounds .. ')')
check(#result.endpoints == 1, '1 wireguard endpoint (got ' .. #result.endpoints .. ')')

local by_tag = {}
for _, o in ipairs(result.outbounds) do by_tag[o.tag] = o end

local r = by_tag['VLESS-Reality']
check(r and r.type == 'vless' and r.server == '1.2.3.4' and r.server_port == 443, 'vless reality basics')
check(r and r.tls and r.tls.reality and r.tls.reality.public_key == 'PUBKEY123', 'vless reality pbk')
check(r and r.flow == 'xtls-rprx-vision', 'vless flow')

local w = by_tag['VLESS-WS']
check(w and w.transport and w.transport.type == 'ws' and w.transport.path == '/ray', 'vless ws transport')
check(w and w.transport.headers.Host == 'cdn.example.com', 'vless ws host header')
check(w and w.tls and w.tls.server_name == 'cdn.example.com', 'vless tls sni')

local v = by_tag['VMESS-WS']
check(v and v.type == 'vmess' and v.server == '2.2.2.2' and v.server_port == 80, 'vmess basics')
check(v and v.uuid == 'aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee', 'vmess uuid')
check(v and v.transport and v.transport.type == 'ws' and v.transport.path == '/vmess', 'vmess ws')

local t = by_tag['Trojan-TLS']
check(t and t.type == 'trojan' and t.password == 'password123', 'trojan basics')
check(t and t.tls and t.tls.server_name == 'trojan.example.com', 'trojan sni')

local s1 = by_tag['SS-AES']
check(s1 and s1.type == 'shadowsocks' and s1.method == 'aes-256-gcm' and s1.password == 'password', 'ss form1')
local s2 = by_tag['SS-FULL']
check(s2 and s2.server == '5.5.5.5' and s2.method == 'aes-128-gcm', 'ss form2')

local h = by_tag['HY2']
check(h and h.type == 'hysteria2' and h.password == 'letmein' and h.tls.server_name == 'hy2.example.com', 'hysteria2 basics')
check(h and h.tls.insecure == true, 'hysteria2 insecure')

local tu = by_tag['TUIC']
check(tu and tu.type == 'tuic' and tu.uuid == 'uuid-1234' and tu.password == 'pass5678', 'tuic basics')
check(tu and tu.congestion_control == 'bbr', 'tuic cc')

local wg = result.endpoints[1]
check(wg and wg.type == 'wireguard' and wg.tag == 'WG-Home', 'wg endpoint tag')
check(wg and wg.peers[1].public_key == 'cHVibGlja2V5' and wg.peers[1].port == 51820, 'wg peer')

-- round-trip through json encoder (what genconfig consumes)
local enc = json.encode(result)
local dec = json.decode(enc)
check(dec and #dec.outbounds == 8, 'json round-trip')

if fails > 0 then print(fails .. ' FAILURES'); os.exit(1) end
print('ALL TESTS PASSED')
