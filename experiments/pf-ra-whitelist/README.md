# pf RA-Whitelist Experiment

> ⚠️ **Status: EXPERIMENTAL / throwaway.** Not part of the app, not a supported feature, not
> shipped in the IPv6Monitor bundle. It manipulates `pf` (root) and is meant for hands-on
> testing on the author's own machine. If the experiment succeeds, the mechanism may later be
> reimplemented as a proper app toggle; otherwise this directory gets deleted.

A throwaway experiment to answer one question:

> Does dropping inbound Router Advertisements from every source **except the gateway** (via
> macOS `pf`) **prevent** the intermittent IPv6 default-route loss — instead of only repairing
> it after the fact?

Background and rationale: [`../../docs/root-cause-analysis.md`](../../docs/root-cause-analysis.md)
and the design spec under `docs/superpowers/specs/` (local).

## What it does

Loads a tiny `pf` rule into the stock `com.apple/*` wildcard anchor (so `/etc/pf.conf` is
**never modified**):

```
pass  in log quick on <iface> inet6 proto icmp6 from <gateway> to any icmp6-type 134 code 0 no state
block in log quick on <iface> inet6 proto icmp6 from fe80::/10 to any icmp6-type 134 code 0
```

The gateway is found by sniffing RAs and picking the source(s) advertising **router lifetime
> 0** (in the affected LAN, only the real gateway; the seven Apple TV / HomePod Thread Border
Routers all advertise lifetime 0).

## Safety

- **Not boot-persistent** — a reboot clears everything (guaranteed escape hatch).
- **No `/etc/pf.conf` edits** — only a sub-anchor is loaded/flushed.
- **Auto-rollback** if connectivity that was working breaks right after the rule loads.
- **IPv6Monitor keeps running** as a safety net (it will repair the route if anything slips).
- If `pf` is already enabled with a custom ruleset lacking the `com.apple/*` anchor, the script
  **aborts** instead of touching it.

## Usage

```sh
sudo ./pf-ra-test.sh on            # auto-detects + proposes the interface, sniffs ~45s for the gateway
sudo ./pf-ra-test.sh on --iface en10   # skip the interface prompt
sudo ./pf-ra-test.sh status        # show the loaded rule, gateway table, current default route
sudo ./pf-ra-test.sh report        # go/no-go readout (losses, blocked RAs, elapsed)
sudo ./pf-ra-test.sh off           # remove it (or just reboot)
```

## How to read the result (`report`)

Success needs **all three**: no route losses, a **rising "blocked" counter** (proof rogue RAs
actually arrived and were dropped), and the gateway still refreshing. The script prints a
verdict:

- **SUCCESS** — 48h+, rogue RAs blocked, zero losses → `pf` prevention works; worth promoting
  into the app as a toggle.
- **FAILURE** — losses continued despite a rising block counter → dropping the RAs does not
  prevent the kernel corruption; abandon `pf`.
- **inconclusive** — block counter still 0 → no rogue RAs seen yet; keep it running.

## Notes / caveats

- Blocking the RIO senders means this host stops learning the Thread/Matter ULA routes they
  advertise. Fine for the experiment (HomeKit reaches accessories via its hubs).
- `pf` evaluates inbound IPv6 before Neighbor Discovery (`pf_af_hook` in `ip6_input()` ahead of
  `nd6_ra_input()`), which is why blocking an RA before the kernel admits it is even possible.
- Targets **en10 only** (the monitored interface; the loss is per-interface and en10-local).
