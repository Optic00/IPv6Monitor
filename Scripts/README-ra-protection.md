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

### Integration evidence (2026-06-30, en10)

`detect`/`status` were verified directly against the real LAN; `on`/`off` were **not**
exercised against the live anchor because `com.apple/ipv6monitor` was already loaded and
active from `experiments/pf-ra-whitelist/pf-ra-test.sh on`, running continuously since
2026-06-28 — switching anchors mid-test would have interrupted real RA protection, so that
swap is deferred to a planned maintenance window instead of being done opportunistically.

- `status` against the live, 2+ day old anchor: `{"active":true,"iface":"en10","pass":10473,"block":9351,"default_route":true}`
  — thousands of gateway RAs passed, thousands of rogue RAs blocked, IPv6 default route intact.
  This is a stronger soak test than the originally planned short manual run.
- `detect en10` (fixed wrapper, `SNIFF_SECS=5`): `{"gateways":["fe80::962a:6fff:fef2:ad"],"others":0}`
  — correctly identified the real gateway; matches the `route -n get -inet6 default` gateway.
- **Bug found and fixed during this check:** on a quiet interface (expected here, since the
  active `block` rule already suppresses most RA traffic), `tcpdump` can sit in a blocking BPF
  `read()` that ignores `SIGTERM`, hanging `sniff_ras`'s `kill "$td"; wait "$td"` indefinitely
  (reproduced for 38+ minutes, confirmed via `sample` — bash stuck in `__wait4`, tcpdump stuck
  in `pcap_read_bpf`). Fixed by escalating to `SIGKILL` after a 3s grace period.
- **Remaining manual step:** a full `on`/`off` cycle through *this* wrapper (replacing the
  original script's anchor ownership) is still outstanding — do it in a maintenance window,
  not opportunistically while real protection is active.
