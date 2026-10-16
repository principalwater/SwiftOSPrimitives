# G24 native memory-control API qualification

This is a qualified research slice, not production acceptance. The exact signed
host UUID is `B0EFB050-290E-3AE6-8816-986C0A345F54`, with matching symbols and 197
frozen source files. Swift 6.4.1, macOS 27.0.1, Apple M2 Max/32 GiB and pinned
Containerization 0.47.0 were used. The unchanged static guest was reused from G23;
it was not rebuilt. Its SHA256 remains
`fa2cf01b3daa74d3e64de80cc34753e51b173f3048e73dbe6b89eeaa8dc204e0`.
All workloads used isolated owned storage. Production services were excluded.

## Public API and actual ownership

The bounded control channel, host-timestamped session and autonomous governor now
live in NativeLinuxVMM. The real workload executable consumes that public API.
The library does not depend on the UI or a lab executable. The caller owns and
joins the governor task. Retained telemetry is bounded to 512 samples/32 requests.

A per-VM generation excludes simultaneous manual setters or another controller.
An already-cancelled task cannot claim; unsettled capacity refuses before the
VM's generation changes, allowing a verified retry. Stop closes new admissions
at the policy's own linearization point while preserving completion and one
restoration of pending shrink. Ordinary growth cannot indefinitely renew an
unsettled-capacity deadline. Typed earliest fences distinguish wire, capacity,
completion, drain and lifetime failures; completion wins exact ties.

Failure retires setter authority and signals the actual native coordinator.
With all vCPUs parked, the device freezes its actual current extents, publishes
an acknowledgement and returns BUSY for later PLUG/UNPLUG/UNPLUG_ALL. Readonly
STAT and malformed-input checks remain. In-flight native transactions finish
before acknowledgement. A bounded acknowledgement failure requires outer VM/
process retirement; a host-side retired flag alone does not prove native safety.
The hot path adds one atomic check, not an extent scan; no speedup is claimed.

## Executed evidence

Release tests passed: root 42, native 43 declarations and original product 1;
38 compiler-ownership check records passed. The optional APFS fixture was not
supplied in G24; G23's separate real disk test is historical evidence only.
The independent validator accepted all 17 exact-artifact profiles below.

| Profile | Seconds | Cumulative backing retired, MiB |
|---|---:|---:|
| cancel-release | 21.146 | 0 |
| unsettled | 14.018 | 0 |
| expired-stop | 13.835 | 0 |
| continuous-two | 32.598 | 358 |
| continuous-four | 31.121 | 334 |
| adaptive | 34.771 | 212 |
| manual | 27.684 | 256 |
| busy | 23.185 | 0 |
| cancel | 16.261 | 0 |
| pending-stop | 18.031 | 128 |
| history-soak | 78.643 | 286 |
| history-churn | 58.462 | 2494 |
| lifetime-expire | 15.707 | 0 |
| sustained | 133.315 | 324 |
| dynamic-wide | 31.296 | 4096 |
| boot-wide | 28.468 | 512 |
| uart | 35.164 | 340 |

BUSY is accepted only for its exact expected completion refusal and clean
retirement. Warm manual/wide profiles additionally require fully resident
inspected backing with no paged-out pages. Functional profiles retain actual
residency separately. Four GiB in dynamic-wide is cumulative over two cycles,
not four GiB simultaneously free. RSS, task footprint, backing retirement and
attributed global free-list return are distinct; `physicalReleasedBytes` remains
null. No claim establishes an attributed global free-list increase.

Actual SIGKILL and recovery passed in 39.623 seconds. The previous child was reaped
before replacement, the same journaled ext4 retained 400,000 rows and the exact
count/sum/payload oracle, and two new load/integrity cycles passed. Both vCPUs,
two private NICs, VM and owning worker retired cleanly. Sampled guest OOM,
OOM-kill and swap counters remained zero. No timeout or resource cap was raised.

## Retained counterexamples and external review

The original v1 governor incorrectly returned success for a stop requested after
owner lifetime expiry: an exact-source hardware regression failed in 15.686 s.
The original v2 backend continued a delivered shrink after controller cancellation:
a real held-alias release retired another 128 MiB in 18.927 s. Original binaries,
symbols, sources and failures are retained; both regressions now pass. Cached
`requested = plugged` was rejected as a repair because published counts can lag
an in-flight native operation and accidentally request growth.

First-party Opus 5.5/max returned in 1108.801 s and Sonnet 5.5/max in 1590.910 s,
within their original 2700 s limits. Their static findings were reconciled with
real source and hardware evidence. They are not final v3 security signoff.

## Remaining product work

All five product gates remain OPEN: persistent owned helper/runtime API and live
UI; general configuration and autonomous multi-GiB pressure; global multi-VM
reservations/fairness and resource/security soaks; fair clean-host comparisons;
and signed distribution, update/rollback, general image/network/share/volume/
exec support, Docker/Compose contracts and copy-first migration. The current UI
still inspects saved evidence. No helper/service, installer, production cutover
or push was performed. Branding remains undecided.
