# IPv6 Default Route Loss — Root-Cause Analysis & Fix Options

A collection of findings so far on the question: *Why does the IPv6 default route disappear, and can a real fix be built for it?*

## Where the bug actually lives

The symptoms point clearly to a **kernel bug in the macOS `netinet6` stack** (BSD-derived, closed source). In the failure state, every userspace-visible data source is consistent — only the kernel routing table disagrees:

| Data source | State during failure |
|---|---|
| Global IPv6 addresses on the interface | ✅ present |
| `ndp -r` (Neighbor Discovery router list) | ✅ router listed, non-zero lifetime |
| SystemConfiguration (`State:/Network/…/IPv6`) | ✅ correct router |
| Packet capture of Router Advertisements | ✅ valid high-pref RAs, lifetime 1800s |
| `scutil --nwi` | ✅ IPv6 on interface "Reachable" |
| `route -n get -inet6 default` | ❌ "not in table" |

→ The inconsistency arises **inside the kernel**, not in any userspace component. The accurate framing is a **loss of consistency between the IPv6 Default Router List / SystemConfiguration state and the kernel scoped route table**: even with multiple IPv6 routers present, macOS ends up with *no* default route on the physical interface while a valid high-preference default router is still being advertised and still present in ND and SystemConfiguration.

## What is ruled out (reproduction on factory-new hardware)

The issue reproduces on a **factory-new MacBook Air (M5), first day of use, over Wi-Fi, with no VPN and no third-party software**, and on a **Mac mini (M4)** via both its built-in Ethernet and a USB-C 5GbE adapter. This rules out a whole class of alternative explanations:

- **Not VPN/`utun`-related.** Earlier failure captures showed kernel defaults surviving only via `utun0-7` (that machine ran a mesh VPN with its own ULA range). The vanilla machine has no VPN and still loses the route — the `utun` defaults were incidental, not causal.
- **Not interface- or driver-specific.** Wi-Fi, built-in Ethernet, and a USB-C adapter are all affected.
- **Not accumulated/broken configuration.** A day-one factory machine reproduces it.
- **Not a single-unit hardware fault.** Two different Mac models are affected.

**The only constant across all affected machines is the LAN's IPv6 environment** (a UniFi gateway plus multiple additional IPv6 RA senders). The trigger therefore lives in macOS' handling of that RA environment.

## The RA environment: two distinct sender types (do not conflate)

Observations show **two different kinds of additional RA sender**, which must be kept separate:

1. **Apple Thread Border Routers** (Apple TV, HomePod mini) — in the May 18 2026 capture these send RAs with **router lifetime `0`** plus **Route Information Options (RIO)** for private ULA prefixes (`fd00::/8`). With lifetime 0 they should *not* enter the Default Router List at all.
2. **Multiple medium-preference *default* routers.** A live `ndp -rn` on the active interface (2026-06-26) showed **8 default routers**: 1 × `pref=high` (the gateway, ~30 min lifetime) and **7 × `pref=medium` with non-zero ~2 h lifetimes**. These are advertising Router Lifetime > 0 and are genuine default-router-list entries — *not* the lifetime-0 RIO devices above.

This second observation materially changes the picture: the LAN does not just have one gateway plus passive RIO devices — it has *several* devices competing as default routers. Which of the two types is present at the moment of each loss is the key open question (see "what the tool now captures").

## Suspected trigger (updated ranking)

1. **macOS bug in IPv6 default-route management under a multi-RA-sender / multi-default-router LAN.** (leading) The kernel drops the physical-interface default while the Default Router List and SystemConfiguration still hold a valid high-preference router.
2. **Thread Border Router lifetime-0 RIO handling specifically.** Plausible but not yet isolated from (1).
3. ~~VPN/`utun` scoped-route interaction~~ — **ruled out** by the vanilla-hardware reproduction.

## Implication for a "real" fix

A **real** fix — addressing the root cause — **cannot be built** as an outside party. It would require patching Apple kernel code, blocked by SIP, signed kernels, and the absence of source. This is a **platform boundary, not a difficulty level**.

Everything you can build yourself is **workaround-class**: detect + restore the route (what IPv6Monitor does today) — or, better, prevent the trigger from reaching the host.

## Realistic levers (beyond the status quo)

1. ~~**Event-driven instead of polling.** Subscribe to a `PF_ROUTE` socket and react to `RTM_DELROUTE`.~~ **Ruled out (2026-06-27).** A continuous `route -n monitor` shows the default route emits **no `RTM_DELETE`** when it is lost — it stops resolving silently. An event-driven detector waiting for `RTM_DELROUTE` therefore cannot catch this bug; polling remains necessary (see the 2026-06-27 update below).

2. **Prevention instead of reaction** *(most promising)*. Stop the host from ever seeing multiple competing default routers:
   - **`pf` whitelist:** block inbound RAs (`icmp6-type 134`) on the interface except from the gateway's stable EUI-64 link-local. The rogue senders use rotating RFC 7217 privacy addresses, so whitelisting the one stable gateway is more robust than blocklisting the others. If macOS only ever sees one default router, the multi-router selection path can't be exercised.
   - **RA Guard at the network** (switch / UniFi): suppress rogue RAs before they reach any client — the textbook fix, independent of per-host config.
   - Investigate `sysctl net.inet6.ip6.*` (RA/RIO acceptance), though these lack per-source granularity.
   - Caveat for diagnosis: any such filter makes the symptom disappear, so keep at least one host unfiltered to keep collecting evidence for Apple.

3. **Cleanly isolate / reproduce the trigger.** Targeted experiments: (a) power off the Apple Thread Border Routers for a period and see whether the vanilla machine stays stable; (b) inject an RA with RIO + lifetime 0 (`scapy` / `rtadvd`) and watch for the drop. Either pins down which sender type matters and produces the best material for the Apple Feedback report.

## What the tool now captures (evidence collection)

IPv6Monitor now records, automatically, exactly the data this analysis needs:

- **On every loss:** a forensic snapshot to `~/Library/Logs/IPv6Monitor/` including `ndp -rn`, `netstat -rn -f inet6`, `route -n get -inet6 default`, `ifconfig`, `scutil --nwi`, and recent `configd`/`networkd` logs.
- **A compact, dated, greppable log line** capturing each RA sender's remaining lifetime at the moment of loss:
  ```
  RA@loss total=8 high=[29m50s] medium=[1h59m55s,…] low=[]
  ```
  Collected over many *natural* losses, this answers two questions at once: does the loss correlate with the high-preference gateway's RA lifetime lapsing, and which of the two RA-sender types is present each time.

## Update 2026-06-27 — packet capture + routing-socket correlation

Three instrumented sources were run simultaneously on the affected host: the monitor's
per-loss snapshot, a continuous Router-Advertisement `tcpdump`, and a continuous
`route -n monitor` (routing-socket) log. **Five dated losses** were captured within ~24 h,
all with the gateway's own router lifetime freshly refreshed (~29 min remaining).

1. **The loss emits no `RTM_DELETE`.** In the routing-socket log, no deletion of the
   physical-interface default route appears in the ~90 s before each loss — only unrelated
   `wifip2pd` (AWDL) and VPN-overlay route churn. The global default simply stops resolving.
   This is strong evidence for a **silent kernel inconsistency** rather than a route removed
   through the normal routing path — and it means an event-driven detector waiting for
   `RTM_DELROUTE` cannot catch this bug (polling is required).

2. **Scoped vs. unscoped split, observed at the socket.** At each loss,
   `route -n get -inet6 default` returns "not in table" while the same lookup with
   `-ifscope <iface>` resolves (flags include `IFSCOPE,GLOBAL`). **Caveat:** the resolving
   scoped route carries the `STATIC` flag — it is the monitor's *own* mitigation route from a
   previous repair, so this split is **indicative, not probative**, of a native kernel
   inconsistency. A passive run (mitigation disabled) is required to capture the native state.

3. **Loss follows a fresh high-preference RA, not expiry.** In every captured loss the real
   gateway sent a normal high-preference RA (lifetime 1800 s) a few seconds before detection,
   with ~29 min of its own router lifetime still remaining. The gateway never advertised
   lifetime 0 in 14 h of capture.

4. **The "second sender type" was a misread — correcting the section above.** Packet capture
   shows the seven medium-preference entries in `ndp -rn` all advertise **Router Lifetime 0**
   on the wire (thousands of RAs, never non-zero), carrying only Route Information Options.
   They are a single type — RIO-only senders (Thread Border Routers) — which per RFC 4861
   should not enter the Default Router List at all, yet macOS lists all seven as medium
   default routers with a multi-hour expiry. There is no separate class of "genuine medium
   default routers".

**Caveat on the capture host.** It runs a VPN overlay and AWDL, which manipulate routes
independently; the formerly factory-new test machine has since had similar software
installed too. The historical vanilla-hardware reproduction still stands, but newer captures
are no longer interference-free — a clean passive run is the remaining gap.

## Conclusion

- **Real fix:** not possible without Apple (kernel is closed source).
- **What the evidence now supports:** a macOS kernel consistency bug between the IPv6 Default Router List / SystemConfiguration and the scoped route table, reproducible on factory-new hardware across all interface types and without any VPN — triggered by a LAN with multiple IPv6 RA senders.
- **Best self-buildable progress:** prevent the trigger (network RA Guard on the gateway, or a host `pf` filter that admits RAs only from the gateway link-local) and keep collecting evidence. An event-driven `PF_ROUTE` redesign is *not* viable — the loss emits no `RTM_DELETE` (see 2026-06-27 update).

---
*Living analysis note. Updated 2026-06-27 with: packet + routing-socket correlation across five dated losses (no `RTM_DELETE` on loss; scoped/unscoped split with mitigation-route caveat; single RIO-only sender type), correcting the earlier "two sender types" framing and the event-driven lever. Earlier (2026-06-26): factory-new-hardware reproduction and automatic `RA@loss` capture.*
