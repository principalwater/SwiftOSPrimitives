# G21 continuous native RAM qualification

Qualified finite research slice: Swift6.4.1, macOS27.0.1/M2Max, Apple container1.5.0 library
integration using its pinned Containerization0.47.0 patch and Linux6.18.35. No global service,
production network, main0106/0117, VPS or protected data was changed. No push/release.

## Final runtime outcomes

All six final cases used one signed host-geometry artifact and static probe-runtime-liveness.
Native tests27/root tests39 pass with warnings-as-errors. Original180second VM watchdog,
8second memory/query budgets,12second SQL process wait and memory ceilings remain enforced.
Every trial used a fresh journalled8GiB COW disk on T7, two private AF_UNIX NICs,400K durable
ClickHouse rows and real320MiB guest pressure. The final query is the original4second G20
profile; pressure growth and subsequent reclaim occur after its live-memory admission.

| Trial | vCPU | Seconds | Cumulative backing retired | Task-ledger credit | Peak process RSS |
| --- | ---: | ---: | ---: | ---: | ---: |
| continuous-two-geometry | 2 | 31.378 | 384MiB | 402850080B | 1987.9MiB |
| continuous-four-geometry | 4 | 37.031 | 384MiB | 402850080B | 1982.6MiB |
| adaptive-geometry | 2 | 35.767 | 206MiB | 216105104B | 1969.2MiB |
| manual-geometry | 2 | 28.826 | 256MiB | 268566720B | 1995.5MiB |
| cancel-geometry | 2 | 18.248 | 0MiB | 0B | 1751.4MiB |

BUSY case exited1 as expected after23.457seconds: alias/refcount2 refusal restored all64 mappings,
zero premature frees, completionTimedOut, all vCPUs/coordinator joined and VM destroyed. It is
preserved as a matched expected failure, not rewritten to native exit0. Pending cancellation
also left zero retired extents and joined the observer before guest/native destruction.

The2/4vCPU continuous cases each performed three128MiB shrinks, two regrowths and two successful
active-load cycles. All retired extents were observed resident before deallocation; native
mapping absence, unique anonymous ownership and all-vCPU quiescence were checked. Both cases
credited402850080bytes to the task ledger. This is cumulative, not384MiB simultaneously freed.
Global physical free-list causality is unknown and physicalReleasedBytes remains null. Peak RSS
includes boot/guest backing and transient host/library buffers; production idle footprint and
Rust parity are not established.

The query remained live with>=16MiB after unplug, returned4999950000 and preserved the full
400K-row oracle. Both NIC echoes and every CPU canary continued; cgroup OOM/OOM-kill/swap
remained zero. The4vCPU run observed an actual guest-capacity lag sample, validating the new
mapping-versus-Linux-online completion fence.

## Implementation and boundaries

MemoryProbeSession owns one non-multiplexed guest transaction through reply validation. It
bounds commands, framing and history, closes on in-flight timeout/cancellation, and isolates
queue-only cancellation. Passive observation uses non-waiting admission, avoiding starvation
behind a foreground scan. No actor lock or raw guest pointer crosses an await.

One caller-owned ContinuousMemoryGovernor task reuses BalloonController, without a stored-task
retention cycle. Admission and native delivery are fenced without suspension; limits precede
side effects. Ordinary admissions wait for coherent native backing and guest MemTotal. Pending
shrink rescue and low-reserve restoration remain enabled during accounting lag. Completion
requires both stages inside the original8second deadline; graceful stop drains known work and
exceptional cancellation joins before teardown. The finite harness caps512samples/32requests,
so it is not an unattended, always-on service or a multi-VM global allocator.

Full64/320MiB checks now use MemoryCanary, with a256byte InlineArray tile and complete unaligned
word checks plus byte tails. Golden boundary/corruption tests preserve all byte coverage. The
host comparison is about11.8times faster for this operation only; see CANARY-PERFORMANCE.md.
Explicit guest replies wait for real CPU/NIC advancement within1second, rather than depending
on an accidentally slow scan. No counters are fabricated. Guest HTTP metadata retries transient
socket timeouts inside a clipped3second monotonic response deadline. Control-plane high is
112MiB below its unchanged128MiB hard ceiling; that calibration alone did not fix HOLD stalls.

## Evidence and limits

Signed host/dSYM UUID8AE39990-EF82-3C3F-ADE7-14CE8DA11BA5, static Linux probe7101400bytes,
176source hashes, raw native outcomes and test bundles are retained in the private research root.
Every initial compilation, tool-path, timing, stale counter, metadata and capacity-lag failure
is retained alongside its signed artifact and exact source snapshot. No retry overwrote a trial.
One retry overlapped evidence hashing and is explicitly excluded from final qualification.

Focused Opus5.5 max review returned a public answer after487.076seconds; implemented capacity
and pressure fixes plus subsequent hardware-driven corrections are documented separately.
Review is not certification. Graph AST refresh succeeded:1946nodes/3985edges/149communities,
24partial Swift parses and older semantic labels limit completeness; scoped query was truncated.
Generated maps remain outside Git. Source/compiler/runtime evidence has precedence.

The prior G19 process-kill/journal-recovery qualification is inherited evidence, not a newly run
G21 crash test. Linux-host KVM, CPU_OFF/live migration, power loss, changed upstream/kernel,
real VPS traffic and production deployment are unqualified. RAM return is limited to the owned
128MiB dynamic region; boot RAM stays allocated until VM destruction. Safe build-only closure
must preserve every retained hash; the root closure report records its actual outcome.
