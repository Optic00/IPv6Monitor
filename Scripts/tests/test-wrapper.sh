#!/bin/bash
set -u
HERE="$(cd "$(dirname "$0")/.." && pwd)"
WRAPPER="$HERE/ipv6monitor-pf"
fail=0
check() { # desc, expected, actual
  if [ "$2" = "$3" ]; then echo "ok - $1"; else echo "FAIL - $1: expected [$2] got [$3]"; fail=1; fi
}

# --- Task 1: dispatch + sourcing guard ---
"$WRAPPER" bogus >/dev/null 2>&1; check "unknown cmd exits 2" 2 "$?"
"$WRAPPER" >/dev/null 2>&1; check "no cmd exits 2" 2 "$?"
out=$(set -u; . "$WRAPPER"; echo "sourced-ok"); check "sourcing runs no dispatch" "sourced-ok" "$out"

# --- source functions for unit tests ---
. "$WRAPPER"

# --- Task 2: interface validation ---
valid_iface "en10; rm -rf /" ; check "rejects injection" 1 "$?"
valid_iface "wlan0"          ; check "rejects non-en" 1 "$?"
valid_iface "en99999"        ; check "rejects nonexistent en" 1 "$?"
real_en=$(ifconfig -l | tr ' ' '\n' | grep -E '^en[0-9]+$' | head -1)
if [ -n "$real_en" ]; then valid_iface "$real_en"; check "accepts real en" 0 "$?"; fi

# --- Task 3: parse RA sources ---
sample=$(cat <<'EOF'
12:00:01 IP6 (class 0xc0) fe80::962a:6fff:fef2:ad > ff02::1: ICMP6, router advertisement, length 88
	hop limit 64, Flags [none], pref high, router lifetime 1800s, reachable time 0ms
12:00:02 IP6 (flowlabel 0x1) fe80::452:d241:d24a:d549 > ff02::1: ICMP6, router advertisement, length 40
	hop limit 0, Flags [ipv6 only], pref medium, router lifetime 0s, reachable time 0ms
12:00:03 IP6 (class 0xc0) fe80::962a:6fff:fef2:ad > ff02::1: ICMP6, router advertisement, length 88
	hop limit 64, Flags [none], pref high, router lifetime 1800s, reachable time 0ms
12:00:04 IP6 (flowlabel 0x2) fe80::18ec:c4fb:de39:bedb > ff02::1: ICMP6, router advertisement, length 40
	hop limit 0, Flags [ipv6 only], pref medium, router lifetime 0s, reachable time 0ms
EOF
)
gwline=$(printf '%s\n' "$sample" | parse_ra_sources | sed -n '1p')
otherline=$(printf '%s\n' "$sample" | parse_ra_sources | sed -n '2p')
check "gateway is the lifetime>0 source" "GW fe80::962a:6fff:fef2:ad" "$gwline"
check "two distinct lifetime-0 senders" "OTHER 2" "$otherline"

# --- Task 4: rule generation ---
rules=$(build_rules en10 fe80::962a:6fff:fef2:ad)
echo "$rules" | grep -qF 'table <ipv6mon_gw> const { fe80::962a:6fff:fef2:ad }' && r1=ok || r1=no
echo "$rules" | grep -qF 'pass  in log quick on en10 inet6 proto icmp6 from <ipv6mon_gw> to any icmp6-type 134 code 0 no state label "ipv6mon:pass-ra-gw"' && r2=ok || r2=no
echo "$rules" | grep -qF 'block in log quick on en10 inet6 proto icmp6 from fe80::/10 to any icmp6-type 134 code 0 label "ipv6mon:block-ra-other"' && r3=ok || r3=no
check "table line" ok "$r1"; check "pass line" ok "$r2"; check "block line" ok "$r3"
echo "$(build_rules en10 fe80::a fe80::b)" | grep -qF '{ fe80::a, fe80::b }' && r4=ok || r4=no
check "multi-gateway table" ok "$r4"

# --- Task 5: path-integrity ---
tmp=$(mktemp -d); sub="$tmp/x"; : > "$sub"
path_is_safe "$sub"; check "user-owned path is unsafe" 1 "$?"
path_is_safe "/usr/bin/true"; check "system path is safe" 0 "$?"
rm -rf "$tmp"

# --- Task 6: parse pf labels ---
labels=$(cat <<'EOF'
ipv6mon:pass-ra-gw 40 9313 1490080 0 0 0 0 0
ipv6mon:block-ra-other 120 8678 520680 0 0 0 0 0
EOF
)
out=$(printf '%s\n' "$labels" | parse_labels)
check "labels parsed" "PASS 9313 BLOCK 8678" "$out"
empty=$(printf '' | parse_labels)
check "empty labels -> zeros" "PASS 0 BLOCK 0" "$empty"

# --- Task 7: json_status ---
js=$(json_status true en10 9313 8678 true)
check "json shape" '{"active":true,"iface":"en10","pass":9313,"block":8678,"default_route":true}' "$js"
js2=$(json_status false "" 0 0 false)
check "json inactive" '{"active":false,"iface":"","pass":0,"block":0,"default_route":false}' "$js2"

exit $fail
