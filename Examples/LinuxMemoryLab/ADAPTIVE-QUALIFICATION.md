# G20 adaptive native backing-RAM qualification

Accepted finite experimental integration, not a production governor. Swift6.4.1,
macOS27.0.1/M2Max/32GiB, Linux6.18.35/arm64/musl. Current Applecontainer release1.5.0
still pins Containerization0.47.0 exactly; upstream tag0.51.0 is separately newer
and unqualified, not silently substituted. Existing reviewed three-public-access
patch retained. No stock global container service or host-network connection.

## Result

The native backend now uses the existing noncopyable BoundedMemory.BalloonController.
One mutex snapshot captures requested/plugged bytes. Fresh sequenced guest samples,
ContinuousClock ages, native sysctl pressure, absolute reserved capacity, delivery
fences, later device convergence, hysteresis and explicit retirement remain distinct.
No PageMemory/BoundedMemory source/API/product/dependency changes were needed.

| Trial | vCPU | Whole run | Backing retired, cumulative | Task footprint credit, bytes | Whole-process max RSS, bytes |
|---|---:|---:|---:|---:|---:|
| bounded-adaptive-two | 2 | 35.466s | 212MiB | 222,412,968 | 2,044,821,504 |
| adaptive-four | 4 | 36.420s | 228MiB | 239,190,184 | 2,066,432,000 |
| manual-regression | 2 | 28.579s | 256MiB | 268,566,720 | 2,044,526,592 |

Each positive trial passed two cycles with both private NICs, live post-UNPLUG
ClickHouse query memory>=22,793,859bytes, the independent400K-row oracle
`400000\t79999800000\t9410121038903895322\t51176128`, expected load sum4999950000,
all-vCPU byte canaries, all NIC echoes, cgroup ceilings, zeroOOM/kill and zero swap.
These are cumulative retired bytes; simultaneous dynamic capacity is128MiB.
Whole-process RSS includes HVF/backend/runtime overhead; it is not guest RAM,
a framework-only allocation baseline, or a Swift/Rust performance comparison.

The2CPU policy grew84/86MiB;4CPU grew100/104MiB. Both follow real320MiB
checked guest allocation and native guest munmap on release. A partial restoration
is accepted only when later device state and exact guest capacity delta agree.
Eight policy samples/four requests per adaptive run; observed convergence upper
bounds62.556–746.077ms include guest RPC/polling and workload scheduling. Setter
return is only delivery (about7–15microseconds), never completion or a network SLO.

The real extra Mach alias at extent32 made preflight observe ref_count2: native
UNPLUG returnedBUSY, restored64 mappings and freed0bytes. Original negative process
exit1/21.932s retained; the controller's completionTimedOut was matched, all workers
joined, VM destroyed, zero cleanup errors. No unknown delivery is retried or counted
as successful reclaim. Existing root39 declarations/5suites and native18 declarations
pass. Raw Swift Testing output is primary; axbuild event mapping is partially supported.

## Memory evidence and safety

Every successful native extent was2MiB, private owned, ref_count1/offset0, with all
vCPUs parked and old virtual range absent after deallocation. All reported retired
bytes were observed resident immediately before retirement in these trials. That
observation includes host security zeroing; it is not all ClickHouse-owned data.
The task footprint ledger credit also includes small accounting/metadata changes.
Global physical free-list causality is unmeasured: physicalReleasedBytes remains null.

No production/main0106/0117, network/PF/DNS/Xray, global container service, VPS,
public-link or protected-data mutation. One VM at a time, nice19, normal host pressure,
1GiB boot+128MiB dynamic, jobs1 and original180s per-run watchdog. Build/scratch/data
only in the private T7 root. G19 and ancestors remain immutable. No push/tag/release.

## Original failures and review

Preserved, not waived: old SwiftPM triple-path packaging caused exit127 before VM;
G19 marker confinement refused G20 before VM; focused new-marker admission failed
before exact-marker port and passed after; first guest pressure allocation hit the
library default64MiB limit before any policy request. Only that workload allocation
now explicitly admits exactly320MiB; the library default remains unchanged. Every
started VM in these failures cleaned up without native cleanup errors.

Sonnet5.5/max requested, official CLI/tool-free source review timed out900.556s,
exit143/no public answer. No review approval or hidden reasoning is attributed.
No Opus re-run was made after G19's original3600s/no-result outcome. Final changes
were reviewed locally and exercised by executable contracts; external review remains
open. Public-model brief predates the final partial-growth/BUSY/admission repairs.

Graph1856nodes/3773edges/138communities, AST update+tree+HTML complete. Existing
23 partial Swift parse warnings remain;137 saved community labels do not fully
cover138 current communities. Semantic document/label refresh was not performed.

## Limits

This finite trusted workload drives observations at explicit checkpoints. Always-on
host-pressure scheduling, concurrent-VM capacity arbitration, arbitrary untrusted
guests, production idleCPU/throughput/SLOs, cross-version configuration migration,
host power loss and Linux-host KVM/weak-VPS deployment remain unqualified. Existing
G19 same-binary journalled process recovery is not re-claimed as a new G20 result.

Private results/frozen-bounded-source-and-symbols.json binds95 selected source/test
inputs and runtime hashes. Native host/dSYM UUID66A27B16-1558-3421-B815-C9320BDC8BB6;
stripped static guest7,097,304bytes with original debug binary retained. Original
results/deadlines, raw axbuild logs and both test bundles are retained before cleanup.
