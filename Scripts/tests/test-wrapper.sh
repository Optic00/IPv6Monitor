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

exit $fail
