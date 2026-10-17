# Autonomous balloon controller: experimental qualification

This is an opt-in native Swift HVF backend implementing the reviewed Apple
Containerization API. It is not the installed Apple container runtime, a product
release, or production approval. All five product acceptance gates remain open.
The pinned API is Containerization 0.47.0, as used by Apple container 1.5.0;
a newer upstream version requires a separate compatibility qualification.

An applied configuration is not a guest acknowledgement, completed drain or
proof of physical free-list credit. `physicalReleasedBytes` remains unknown.
The measurements below concern this process's individually inspected resident
backing objects and its task physical footprint.

## Public control and ownership

`NativeBalloonGovernor` consumes `NativeMemorySession` and one
`NativeVirtualMachine`. The caller owns its run task, joins it before stopping
the VM, and reserves the VM's full configured peak. Reclaimed backing never
creates admission credit. One owner generation controls one device epoch.

The controller validates fresh, ordered host-clock observations, preserves a
512 MiB guest reserve and grows the balloon in 128 MiB steps up to 2 GiB. Both
pre- and post-observation device states must be fully settled before positive
growth or ceiling completion. A new pulse can use newly freed headroom; it
cannot reuse a stale admission ceiling.

A pulse has a native, non-renewable eight-second lease. The earlier zero request
leaves four seconds plus one pending interval for wire exchange and native drain.
Idle sampling is one hertz; progress sampling and retained histories are bounded.
No-progress pulses back off rather than continuously churning pages.

`requestStop()` closes admission synchronously. The first stop fixes the drain
deadline; later calls cannot renew it. An already current policy zero is adopted
rather than replaced with a generation the guest has not read. Cleanup survives
caller cancellation. Reuse requires the same device epoch, applied generation,
zero target/actual/owned pages and a guest read of the latest zero configuration.
Cancellation or transport failure retires positive authority and quarantines
reclamation; valid deflates remain possible.

Native admission, owner/epoch validation, device application and published
balloon state share one nonblocking critical section. Stale positive requests
are rejected and quarantined without falsely reporting application or turning
an authority rejection into an unrelated VM-fatal failure. Manual ownership
uses the explicit zero owner identity.

`NativeBalloonApplication` reports coordinator application with a host
`ContinuousClock` instant, owner/epoch/generation and previous native page counts.
Its bounded journal makes fault tests causal; it grants no page ownership.

## Backing-object recycling

Only a complete independently owned 2 MiB dynamic object is eligible. All vCPUs
must be parked. Metadata pointers are pinned before publication; pinned or aliased
objects are refused. The old object is unmapped, inspected for exclusive unshadowed
ownership, deallocated, checked absent, replaced with a cold zero-filled object
and remapped at the same guest physical address before vCPU resume.

Complete-object work remains pending across native turns, with at most four
attempts across the entire parked epoch, including every MMIO callback. One
refused extent cannot veto its healthy neighbors. Deflate, reset, zero rescue,
expiry and quarantine revoke pending work; actual PFN ownership is rechecked
at each destructive operation. Positive settlement includes this backlog.

Inflated PFNs remain guest-owned balloon pages until deflate acknowledgement.
A replacement after inflate acknowledgement is recorded as such, with its actual
balloon epoch and before-resume proof. It is never mislabeled pre-acknowledgement.
Counters distinguish attempts, replacements and pin/evidence refusals; tests
compare the cached full-extent count with an independent PFN-set model.

Partial-object live-page copying is not implemented. An external design review
identified required pointer, transaction, cache-coherency and rollback proofs;
it did not authorize discarding unowned neighbors or using a residency oracle
to skip live guest data.

## Executed release evidence

Pinned Swift 6.4.1 full release v23 passed 106 tests. Ownership compile-fail consumers
also passed; the root ownership APIs are unchanged. Additional tests cover
atomic application/publication, stale authority, stop-zero adoption, manual
owner normalization, backlog settlement, parked-window budget and 1000
deterministic PFN mutations against an independent Set.

Actual v22 two-vCPU/two-private-NIC ClickHouse fault cases passed on one frozen executable:

| Fault | Native zero application | Guest/native drain | Result |
| --- | ---: | ---: | --- |
| Requested stop | 14.667 microseconds | 177.315542 milliseconds | New owner admitted after join |
| Caller cancellation | 20.375 microseconds | 361.866709 milliseconds | Retired/quarantined |
| Telemetry-input disconnect | 6.0145 milliseconds | 266.418375 milliseconds | Typed failure; retired/quarantined |

Each fault occurred during a query using at least 16 MiB, with native application
journal evidence, exact SQL result, a separately verified 400,000-row durable hash,
fresh canaries and unchanged guest capacity. CPU/native workers joined without
OOM, swap growth or cleanup errors. These cases include the final native publication/recycling repairs. Later v23
changes concern network readiness diagnostics, receiver guards and echo accounting;
they are not same-artifact fault receipts for v23.

The v20 native core passed actual cold/warm device controls (0.796590 and
0.032033 seconds). The v21 change affects only the workload batching; native
source parity is independently recorded.

### Two complete resident-return cycles

The v21 entropy fixture uses 2 vCPUs, 2 private NICs and 3 GiB guest capacity:
a 512 MiB boot floor and 2560 MiB normal dynamic backing. ClickHouse holds
2176 MiB of random String payload (557,056 rows), in 17 batches of 128 MiB.
`max_block_size=2047` leaves SIMD-padding space; all original resource, query,
quota, time and integrity limits remain unchanged.

Both actual v21 cycles passed the resident-return/data/capacity checks:

| Cycle | Owned resident backing returned | Time after workload release | Task footprint before → after |
| --- | ---: | ---: | ---: |
| 1 | 1,489,059,840 bytes | 0.827010084 s | 3,226,783,680 → 1,742,180,408 bytes |
| 2 | 1,442,840,576 bytes | 0.767086667 s | 3,238,301,920 → 1,797,099,936 bytes |

The SQL query remained live, exact results/hashes/canaries and full guest capacity
were restored, and no OOM, swap or native cleanup error occurred. Peak fully
owned dynamic objects: 711; attempts = replacements = 1399, with no skipped
objects. Every backing replacement retained the parked/ownership/remap proof.
The original source image and immutable boot inputs remained unchanged.

**The overall independent v21 run is rejected.** Its genuinely idle 30-second
window consumed 4,000,657 process CPU microseconds, above the unchanged
3,000,000-microsecond limit. Guest synthetic CPU/NIC beacons were joined, no
extra balloon pulse/request occurred and 30 bounded observations were taken.
Two successful RAM cycles are not an idle-performance or production pass.
A separate normal-release v21 build also failed idle CPU (3,948,609 microseconds),
so testability did not explain the problem.

## Retained counterexamples

- Compressible repeated-hash fixtures returned less resident memory than logical
  backing retired. A footprint drop cannot replace resident-byte evidence.
- Earlier random-column fixtures hit padded allocation/query/server limits before
  ballooning. No guard was disabled; block padding and batching were corrected.
- V12 two-vCPU entropy replaced 245 objects, returning 486,539,264 resident bytes,
  below the required 1 GiB in eight seconds.
- V19 manual two-vCPU functional control passed. Its four-vCPU control timed out
  on DROP at the original five-second wire fence after HOLD completed in about
  0.608 seconds. Native teardown joined cleanly. The SMP failure is unresolved.
- V19 entropy returned 242,974,720 resident bytes despite 687 replacements.
- V20 first cycle returned 1,346,371,584 resident bytes in 1.114308208 seconds;
  the second reached the unchanged 100-query quota. V21 reduces request count
  at the same total payload and unchanged per-query/overall limits.
- V21 four-vCPU entropy was not executed. V22 four-vCPU results are recorded below;
  older successful finite controls do not qualify autonomous idle performance.

## Native socket readiness and later evidence

A two-second, exact-owned-PID normal-release profile contained 164 CPU samples;
the synthetic Ethernet peer accounted for 28.08% inclusive cycle weight while
polling an idle socket every millisecond. This is a short diagnostic, not a fair
stock-runtime comparison.

V22 replaces that polling with native GCD level-triggered readiness. A registration
owns a CLOEXEC duplicate, suspends after notification and re-arms only for a new
waiter. Cancellation and source closure are balanced, and the cancel handler
closes the actual duplicate after unregistering. Exactly one async receiver is
admitted. Cancellation before admission acquires no authority; cancellation after
admission retires async receiving while leaving synchronous/device I/O owned.

An exact Sonnet 5.5/max source review returned with no blocking primitive finding.
Its non-blocking findings prompted truthful post-send echo accounting, a stopped-
first entry guard, an active-before-suspend guard and stronger real-socket tests.
The implementation does not swallow arbitrary errors after a stop request.

V23's 106-test release run passed in 54.831259 seconds (test phase 8.420 seconds).
Tests wait for the real pending continuation, verify queued-data re-evaluation
and no spin, protect a competing receiver, and atomically replace a still-owned
caller FD to prove the watched duplicate cannot follow a reused descriptor number.
Native close status is also emitted in the lab's live result, not just a test seam.

The echo-counter regression was independently reproduced with a real saturated
socket: the old code reported one delivered reply while the reply could not be
sent. The clean BEFORE run failed exactly that assertion; the corrected test and
full suite passed. Earlier compiler/oracle mistakes are retained separately and
are not presented as memory/controller failures.

A standalone Thread Sanitizer build used the exact production readiness source,
a raw AF_UNIX fixture and only its two error constructors. All 4096 interleavings
and registration closes completed without a race report in 8.756501 seconds.
The linked sanitizer detected an intentional Swift access race in a separate
control and aborted that control. Both runs warned about an invalid dyld module
map and potentially unreliable backtraces. This is useful component evidence,
with that tooling limitation; it is not full-VMM/product sanitizer qualification.

### V22 hardware

The frozen v22 executable passed actual cold/warm device controls in 0.808580 and
0.029801 seconds, then the complete two-vCPU/two-NIC entropy profile:

| Cycle | Owned resident backing returned | Time after release |
| --- | ---: | ---: |
| 1 | 1,496,317,952 bytes | 0.882291709 seconds |
| 2 | 1,652,555,776 bytes | 0.563049917 seconds |

True idle used 2,823,212 process CPU microseconds over 30 seconds, under the
unchanged three-second limit. There were zero idle pulses/requests, 30 observations,
no footprint growth, no OOM/swap/quarantine and clean native/CPU joins.
All exact SQL/hash/canary/capacity and immutable-source checks passed.

Four vCPUs returned 1,382,023,168 and 1,371,537,408 resident bytes in 1.831920042 and
1.601641750 seconds with clean data/joins. The overall run is rejected: idle CPU
was 4,548,140 microseconds, above the same limit. This does not erase the earlier
v19 DROP wire timeout or complete the SMP/performance gate.

### V23 counterexample

The v23 two-vCPU replay is rejected after 32.485988 seconds: 691 objects were
replaced, but only 403,488,768 resident bytes were returned, below the required
1 GiB. At the workload peak, task footprint was 3,233,009,600 bytes while RSS
was only 1,941,454,848 bytes; the resident evidence was already reduced before
ballooning. That is consistent with host compression/paging, not a verified cause
of every difference. No host-side warming, purge or deadline relaxation was used.

All native workers joined with no native cleanup error, OOM or swap event.
Both async network registrations reported retired/not-waiting/native close zero.
The original image and immutable boot inputs remained unchanged. V22's successful
profile is therefore a bounded observation, not a promise that every host state
will produce the same resident-return amount. Global free-list credit remains
unknown. V23 four-vCPU performance is not qualified.

## Still required

- Meet the unchanged idle CPU budget, and qualify autonomous four-vCPU behavior,
  resets, actual monitor kill/stall, global OOM, cancellation phases and soaks.
- Integrate the library into a signed per-VM product helper with full-peak global
  reservations, distinct process/guest/drain/reap states and live native UI.
- Qualify the external ownership-disabled backing chain, distribution signing,
  upstream update/rollback, general devices/images and copy-first migration.
- Execute fair stock Apple container and OrbStack comparisons on a clean host.

All experiments are isolated from production services, installed runtimes,
household networking and original data. No OrbStack-equivalence claim is made.
