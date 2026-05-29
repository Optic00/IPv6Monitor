# IPv6 Default Route Loss — Root-Cause Analysis & Fix Options

A collection of findings so far on the question: *Why does the IPv6 default route disappear, and can a real fix be built for it?*

## Where the bug actually lives

The symptoms point clearly to a **kernel bug in the macOS `netinet6` stack** (BSD-derived, closed source). In the failure state, every userspace-visible data source is consistent — only the kernel routing table disagrees:

| Data source | State during failure |
|---|---|
| Global IPv6 addresses on the interface | ✅ present |
| `ndp -r` (Neighbor Discovery router list) | ✅ router listed |
| SystemConfiguration | ✅ correct router |
| Packet capture of Router Advertisements | ✅ valid RAs |
| `route -n get -inet6 default` | ❌ "not in table" |

→ The inconsistency arises **inside the kernel** (likely in RA/RIO processing), not in any of the userspace components.

### Suspected trigger

Networks where standard IPv6 gateways coexist with **Apple Thread Border Routers** (Apple TV, HomePod mini). These send Router Advertisements carrying **Route Information Options (RIO)** for ULA prefixes with **router lifetime `0`** (i.e. they should not become the default route themselves). The hypothesis: macOS' processing of these RAs/RIOs, under certain conditions, triggers the deletion of the existing default route.

## Implication for a "real" fix

A **real** fix — addressing the root cause — **cannot be built** as an outside party. It would require patching Apple kernel code, which is blocked by SIP, signed kernels, and the absence of source. This is a **platform boundary, not a difficulty level** — better tooling/models change nothing here.

Everything you can build yourself is **workaround-class**: detect + restore the route (exactly what IPv6Monitor does today) — or, better, prevent the trigger.

## Realistic levers (beyond the status quo)

1. **Event-driven instead of polling**
   Rather than polling SystemConfiguration + the routing table: subscribe to a **`PF_ROUTE` socket** and react to `RTM_DELROUTE` for the default route. Catches the deletion the moment it happens → faster and more resource-efficient.

2. **Prevention instead of reaction** *(most promising)*
   If the trigger is the Thread Border Routers' RIO/RA processing:
   - Investigate `sysctl net.inet6.*` knobs (RA/RIO acceptance, possibly per interface)
   - Filter the RAs from the Apple TV / HomePod sources
   → would potentially *prevent* the problem instead of merely repairing it. The biggest genuine improvement over the reactive approach.

3. **Cleanly isolate / reproduce the trigger**
   A targeted test: inject an RA with RIO + lifetime 0 (`scapy` / `rtadvd`) and observe when the default route drops. This verifies lever 2 — and produces the best material for a bug report to Apple (Feedback Assistant).

## Conclusion

- **Real fix:** not possible without Apple (kernel is closed source).
- **Best self-buildable progress:** move from reactive restoration toward *reproducing and preventing the trigger*.
- **Incremental improvement to the existing tool:** an event-driven `PF_ROUTE` monitor instead of polling.

---
*Written as an analysis note; not yet verified through reproduction. As of: 2026-05-29.*
