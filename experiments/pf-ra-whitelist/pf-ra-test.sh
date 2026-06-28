#!/bin/bash
# pf-ra-test.sh — EXPERIMENT (not a product feature)
#
# Question: does dropping inbound Router Advertisements from every source EXCEPT the gateway
# (via macOS pf) PREVENT the intermittent IPv6 default-route loss, instead of only repairing it?
#
# Mechanism: a pf rule loaded into the stock `com.apple/*` wildcard anchor (so /etc/pf.conf is
# never modified). Not boot-persistent — a reboot clears everything. The IPv6Monitor app keeps
# running as a safety net. See ../../docs/superpowers/specs/2026-06-28-pf-ra-whitelist-experiment-design.md
#
# Usage:  sudo ./pf-ra-test.sh on [--iface en10]
#         sudo ./pf-ra-test.sh off
#         sudo ./pf-ra-test.sh status
#         sudo ./pf-ra-test.sh report
set -u

ANCHOR="com.apple/ipv6monitor"
STATE_DIR="/var/run/ipv6mon-pf"
SNIFF_SECS="${SNIFF_SECS:-60}"
PING_TARGET="${PING_TARGET:-2606:4700:4700::1111}"   # Cloudflare v6
PFCONF="/etc/pf.conf"

# --- helpers ---------------------------------------------------------------

require_root() {
  [ "$(id -u)" -eq 0 ] || { echo "Please run with sudo."; exit 1; }
}

# Resolve the invoking user's IPv6Monitor log even when running under sudo (HOME=/var/root).
monitor_log() {
  local u h
  u="${SUDO_USER:-$USER}"
  h=$(dscl . -read "/Users/$u" NFSHomeDirectory 2>/dev/null | awk '{print $2}')
  [ -n "$h" ] || h="/Users/$u"
  echo "${IPV6MON_LOG:-$h/Library/Logs/IPv6Monitor/IPv6Monitor.log}"
}

detect_iface() {
  local i
  i=$(route -n get -inet6 default 2>/dev/null | awk '/interface:/{print $2; exit}')
  [ -n "$i" ] && { echo "$i"; return; }
  scutil --nwi 2>/dev/null | awk '/^[[:space:]]+en[0-9]+ : flags/{gsub(":",""); print $1; exit}'
}

do_ping() {
  if command -v ping6 >/dev/null 2>&1; then
    ping6 -c 2 -i 1 "$PING_TARGET" >/dev/null 2>&1
  else
    ping -6 -c 2 -i 1 "$PING_TARGET" >/dev/null 2>&1
  fi
}

# Sniff RAs for $SNIFF_SECS and print the link-local source(s) advertising router lifetime > 0.
detect_gateways() {
  local iface="$1" tmp td
  tmp=$(mktemp)
  echo "Sniffing Router Advertisements on $iface for ${SNIFF_SECS}s to identify the gateway" >&2
  echo "(the source advertising router lifetime > 0)…" >&2
  tcpdump -ni "$iface" -vv -l 'icmp6 and ip6[40] == 134' >"$tmp" 2>/dev/null &
  td=$!
  sleep "$SNIFF_SECS"
  kill "$td" 2>/dev/null
  wait "$td" 2>/dev/null
  awk '
    /router advertisement/ { cur=""; for (i=1;i<=NF;i++) if ($i==">") cur=$(i-1) }
    match($0, /router lifetime [0-9]+s/) {
      s=substr($0,RSTART,RLENGTH); gsub(/[^0-9]/,"",s)
      if (s+0>0 && cur!="") print cur
    }
  ' "$tmp" | sort -u
  rm -f "$tmp"
}

rollback() {
  pfctl -a "$ANCHOR" -F rules  >/dev/null 2>&1
  pfctl -a "$ANCHOR" -F Tables >/dev/null 2>&1
  if [ -f "$STATE_DIR/token" ]; then
    pfctl -X "$(cat "$STATE_DIR/token")" >/dev/null 2>&1
    rm -f "$STATE_DIR/token"
  fi
}

# Ensure the stock com.apple/* wildcard anchor is active so our sub-anchor is evaluated.
ensure_anchor_available() {
  if pfctl -s info 2>/dev/null | grep -q "Status: Enabled"; then
    if pfctl -sr 2>/dev/null | grep -q 'anchor "com.apple/\*"'; then
      return 0
    fi
    echo "pf is already enabled with a custom ruleset that has no com.apple/* anchor."
    echo "Refusing to modify it. Aborting."
    exit 1
  fi
  echo "pf is disabled; loading the stock $PFCONF and enabling pf (token-based)…"
  pfctl -f "$PFCONF" >/dev/null 2>&1
  local tok
  tok=$(pfctl -E 2>&1 | awk '/Token/{print $NF}')
  [ -n "$tok" ] && echo "$tok" > "$STATE_DIR/token"
  if ! pfctl -sr 2>/dev/null | grep -q 'anchor "com.apple/\*"'; then
    echo "com.apple/* anchor still absent after loading stock pf.conf; aborting."
    rollback
    exit 1
  fi
}

# --- commands --------------------------------------------------------------

cmd_on() {
  require_root
  mkdir -p "$STATE_DIR"

  local iface
  iface="${OPT_IFACE:-$(detect_iface)}"
  if [ -z "$iface" ]; then
    echo "Could not auto-detect the interface. Re-run with --iface <name>."; exit 1
  fi
  if [ -z "${OPT_IFACE:-}" ] && [ -t 0 ]; then
    local ans
    read -r -p "Use interface '$iface'? [Enter to accept, or type a different name]: " ans
    case "$ans" in
      ""|y|Y|yes|YES|j|J|ja|JA) : ;;   # keep the proposed interface
      *) iface="$ans" ;;
    esac
  fi
  if ! ifconfig "$iface" >/dev/null 2>&1; then
    echo "Interface '$iface' does not exist. Aborting (nothing changed)."; exit 1
  fi
  echo "Interface: $iface"

  # connectivity BEFORE the rule (so we don't blame a pre-existing loss on ourselves)
  local pre_ok=1; do_ping || pre_ok=0

  local gws=() line
  while IFS= read -r line; do [ -n "$line" ] && gws+=("$line"); done < <(detect_gateways "$iface")
  if [ "${#gws[@]}" -eq 0 ]; then
    echo "No RA source with positive router lifetime seen in ${SNIFF_SECS}s — cannot pick a gateway."
    echo "Is $iface the right interface? Aborting (nothing changed)."; exit 1
  fi
  echo "Gateway(s) to allow (router lifetime > 0): ${gws[*]}"

  local list; list=$(printf '%s, ' "${gws[@]}"); list="${list%, }"
  local rules; rules=$(mktemp)
  {
    echo "table <ipv6mon_gw> const { $list }"
    echo "pass  in log quick on $iface inet6 proto icmp6 from <ipv6mon_gw> to any icmp6-type 134 code 0 no state label \"ipv6mon:pass-ra-gw\""
    echo "block in log quick on $iface inet6 proto icmp6 from fe80::/10 to any icmp6-type 134 code 0 label \"ipv6mon:block-ra-other\""
  } > "$rules"

  ensure_anchor_available

  # rollback on any failure from here on
  trap 'echo "Error — rolling back."; rollback; rm -f "$rules"; exit 1' ERR INT

  if ! pfctl -n -a "$ANCHOR" -f "$rules" 2>/tmp/ipv6mon-pf.err; then
    echo "Rule failed to parse:"; cat /tmp/ipv6mon-pf.err; rollback; rm -f "$rules"; exit 1
  fi
  pfctl -a "$ANCHOR" -f "$rules"
  rm -f "$rules"
  trap - ERR INT

  # record state for `report`
  date +%s > "$STATE_DIR/start"
  echo "$iface" > "$STATE_DIR/iface"
  local _b; _b=$(grep -c "Route verloren" "$(monitor_log)" 2>/dev/null); echo "${_b:-0}" > "$STATE_DIR/loss_baseline"

  echo "Rule loaded into anchor $ANCHOR."

  # sanity: only roll back if we DEMONSTRABLY broke working connectivity
  sleep 3
  if do_ping; then
    echo "Sanity OK: IPv6 connectivity is up (ping6 $PING_TARGET)."
  elif [ "$pre_ok" -eq 1 ]; then
    echo "Sanity FAILED: connectivity was up before and is down now — rolling back."
    rollback; exit 1
  else
    echo "Note: IPv6 was already down before the rule (likely a pre-existing loss);"
    echo "the monitor will repair it. Rule left in place."
  fi

  echo
  echo "Active. Let it run ~48h, then: sudo $0 report"
  echo "Escape hatches: 'sudo $0 off'  or simply reboot."
}

cmd_off() {
  require_root
  rollback
  rm -f "$STATE_DIR/start" "$STATE_DIR/iface" "$STATE_DIR/loss_baseline"
  echo "pf RA-whitelist removed (anchor flushed; pf token released if we set one)."
}

cmd_status() {
  echo "== pf =="
  pfctl -s info 2>/dev/null | grep -E "Status:" || echo "  (pfctl unavailable)"
  echo "== anchor $ANCHOR rules =="
  pfctl -a "$ANCHOR" -sr 2>/dev/null || echo "  (none loaded)"
  echo "== gateway table =="
  pfctl -a "$ANCHOR" -t ipv6mon_gw -T show 2>/dev/null || echo "  (no table)"
  echo "== IPv6 default route =="
  route -n get -inet6 default 2>&1 | grep -E "gateway:|interface:" || echo "  not in table"
}

cmd_report() {
  if [ ! -f "$STATE_DIR/start" ]; then
    echo "Not active. Run 'sudo $0 on' first."; exit 1
  fi
  local start now elapsed_h elapsed_m base cur losses blocked passed
  start=$(cat "$STATE_DIR/start"); now=$(date +%s)
  elapsed_m=$(( (now - start) / 60 )); elapsed_h=$(( elapsed_m / 60 ))
  base=$(cat "$STATE_DIR/loss_baseline" 2>/dev/null); base=${base:-0}
  cur=$(grep -c "Route verloren" "$(monitor_log)" 2>/dev/null); cur=${cur:-0}
  losses=$(( cur - base ))
  blocked=$(pfctl -a "$ANCHOR" -s labels 2>/dev/null | awk '/ipv6mon:block-ra-other/{print $3}')
  passed=$(pfctl -a "$ANCHOR" -s labels 2>/dev/null | awk '/ipv6mon:pass-ra-gw/{print $3}')
  : "${blocked:=0}"; : "${passed:=0}"

  echo "Elapsed:                 ${elapsed_h}h (${elapsed_m} min)"
  echo "Route losses since on:   $losses   (baseline pattern ~5/day)"
  echo "Rogue RAs blocked:       $blocked"
  echo "Gateway RAs allowed:     $passed"
  echo
  if [ "$blocked" -eq 0 ]; then
    echo "VERDICT: inconclusive — no rogue RAs blocked yet (no exposure). Keep it running."
  elif [ "$losses" -gt 0 ]; then
    echo "VERDICT: FAILURE — losses continued despite blocking rogue RAs. pf prevention does not work; abandon."
  elif [ "$elapsed_h" -ge 48 ]; then
    echo "VERDICT: SUCCESS — 48h+ with rogue RAs blocked and zero losses. pf prevention works; promote to app toggle."
  else
    echo "VERDICT: on track — blocking works, no losses yet. Keep running until 48h."
  fi
}

# --- dispatch --------------------------------------------------------------

cmd="${1:-}"; [ $# -gt 0 ] && shift
OPT_IFACE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --iface) OPT_IFACE="${2:-}"; shift 2 ;;
    *) echo "Unknown argument: $1"; exit 1 ;;
  esac
done

case "$cmd" in
  on)     cmd_on ;;
  off)    cmd_off ;;
  status) cmd_status ;;
  report) cmd_report ;;
  *) echo "Usage: sudo $0 {on [--iface <name>] | off | status | report}"; exit 1 ;;
esac
