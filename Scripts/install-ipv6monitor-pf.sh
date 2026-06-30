#!/bin/bash
# Installs the RA-protection privileged helper to a root-only path and prints the sudoers line.
set -eu

SRC="$(cd "$(dirname "$0")" && pwd)/ipv6monitor-pf"
DEST="/Library/PrivilegedHelperTools/ipv6monitor-pf"

[ "$(id -u)" -eq 0 ] || { echo "Run with sudo: sudo $0" >&2; exit 1; }
[ -f "$SRC" ] || { echo "Source not found: $SRC" >&2; exit 1; }

mkdir -p /Library/PrivilegedHelperTools
install -o root -g wheel -m 0755 "$SRC" "$DEST"

# Integrity gate: the destination and every parent must be root-owned and not
# group/other-writable, or the NOPASSWD sudoers rule becomes a root-escalation hole.
. "$SRC"   # defines path_is_safe (sourcing guard prevents dispatch)
if ! path_is_safe "$DEST"; then
  echo "REFUSING: $DEST or a parent directory is not safely owned (root-escalation risk)." >&2
  rm -f "$DEST"
  exit 1
fi

user=$(stat -f '%Su' /dev/console)
echo "Installed $DEST (root:wheel 0755, integrity OK)."
echo
echo "Add this sudoers line — run:  sudo visudo -f /etc/sudoers.d/ipv6monitor"
echo
echo "$user ALL=(root) NOPASSWD: $DEST detect *, $DEST on *, $DEST off, $DEST status"
echo
echo "Do NOT grant pfctl broadly — only this wrapper with these fixed subcommands."
