# RA Protection — privileged helper (`ipv6monitor-pf`)

> ⚠️ **This is an active packet filter, not diagnosis.** It tells `pf` to allow incoming IPv6
> Router Advertisements on one interface **only from the gateway** and block all other
> link-local RA senders — which removes the multi-RA trigger of the macOS IPv6 default-route
> loss (proven in a 48 h A/B: 0 losses, `ndp -rn` 8→1). It applies to **one interface only**,
> and a reboot or `off` removes it.

## What it does

`ipv6monitor-pf` is the root-owned helper the app calls. It loads a rule into the **stock
`com.apple/ipv6monitor` anchor** (it never edits `/etc/pf.conf`), detecting the gateway by
sniffing for the RA source with **router lifetime > 0**.

Subcommands (JSON on stdout):

- `detect <iface>` — `{"gateways":[…],"others":N}` (read-only)
- `on <iface>` — apply the filter, then print status
- `off` — flush only our anchor, release our pf token
- `status` — `{"active":…,"iface":…,"pass":…,"block":…,"default_route":…}` (read from `pfctl`)

## Install

```sh
sudo Scripts/install-ipv6monitor-pf.sh
```

This copies the helper to **`/Library/PrivilegedHelperTools/ipv6monitor-pf`** (`root:wheel`,
`0755`) and prints the sudoers line to add via `sudo visudo -f /etc/sudoers.d/ipv6monitor`.

**Security:** the helper must live where neither it nor any parent directory is writable by a
non-root user (the installer verifies this and refuses otherwise). A `NOPASSWD` rule pointing
at a user/admin-writable location (e.g. `/usr/local/sbin`, which Homebrew makes writable) would
be a local root-escalation hole. **Never** grant `pfctl` broadly — only this wrapper with its
fixed subcommands.

## Manual integration check (on the affected LAN)

Run after stopping any other RA-filter (e.g. `sudo experiments/pf-ra-whitelist/pf-ra-test.sh off`)
so they don't both touch the `com.apple/ipv6monitor` anchor:

```sh
sudo /Library/PrivilegedHelperTools/ipv6monitor-pf detect en10   # {"gateways":["fe80::…"],"others":N}
sudo /Library/PrivilegedHelperTools/ipv6monitor-pf on en10       # status JSON, "active":true
ndp -rn                                                          # collapses toward 1 within ~2h
sudo /Library/PrivilegedHelperTools/ipv6monitor-pf status        # pass>0, block rising
sudo /Library/PrivilegedHelperTools/ipv6monitor-pf off           # anchor flushed, token released
```

Expected: `on` keeps IPv6 up (`ping6` works), the JSON parses, `off` cleanly reverts.
