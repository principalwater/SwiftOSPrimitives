# Host balloon research results

The isolated Swift6.4.1 candidate987b0c4 adds a32-byte value-only target planner and a
separate native QMP laboratory. It preserves existing PageMemory, typed mapped-value,
scratch/frame ownership and public package APIs. Package products remain entirely Swift;
the hosted QMP example uses standard Foundation/POSIX APIs, while privileged boot/vector
assembly stays confined to the optional freestanding fixture. No production adoption is
implied.

## Actual native results

| Gate | Observed outcome |
|---|---|
| macOS release and AddressSanitizer package tests |38 and38 passed |
| Existing compiler/lifetime/ownership consumers |36 passed |
| Hosted QMP wire/diagnostic gates, release/AddressSanitizer |5 and5 passed |
| iOS18 deployment module with SDK27 |Compilation passed |
| Default macOS framework consumer |Build and real runtime passed |
| Freestanding ARM64/x86 profiles and whole guest audit |Passed; no Linux kernel claim |
| Diskless/networkless QEMU guest outcomes |14 exact success/negative outcomes passed |
| Real QMP host modes |Cycles, missing device, cancel while inflated, wrong target passed |
| StaticLinux standby native probe |Two strictly capped runs passed |

The real host cycle collected21 `query-balloon` logical-size observations:
initial67108864 bytes, then ten67092480→67108864 transitions. Guest ownership and real
used-ring completions precede actual updates. Ten cycles reuse all eight queue slots,
changing heads between laps. Returned donor memory is initialized before CPU inspection.
The host observes the final value while the guest deliberately stays alive, then issues
QMP quit. No arbitrary pause is used as a completion receipt.

Wrong-target testing deliberately bypasses the planner and sends an unsupported8-page
target to the real guest; no pages are inflated. Wrong-index and poisoned-used-ID controls
reach distinct driver refusals. Cancellation destroys/joins the owned disposable VM,
retaining its donated-frame tickets until VM exit. This does not prove live-driver restart
or safe reuse after a cancelled DMA operation.

The staticLinux probe exercised12288 planner steps, independent checksum503316480,
existing256 exactly-once typed destructions, frame checksum509256,1024 compact Atomic
slots and a2MiB mapping touch/discard/reset. Under32MiB RAM,10% CPU,8 tasks and15-second
limits, its own CPU was5.24/6.45ms and measured wall time59.50/80.08ms. Final RSS was
4829184 bytes (about4.61MiB). Transient service accounting also includes namespace/shell
startup:75–79ms CPU and724–763ms runtime. These are whole synthetic-probe observations,
not network request latency, isolated planner latency, VM RAM costs or a fair Rust comparison.
Runtime primary/service/config identities matched before/after; this is not a measurement
of every production client's jitter. Exact remote binaries/private empty directory removed.

## Limits and follow-up

The Mac backing-page size is16KiB. Pinned QEMU emits its larger-page balloon warning;
the raw diagnostic is retained and qualified. QMP actual is logical guest capacity, not
physical host RSS/footprint. `physicalReleasedBytes` stays unknown. Physical-reclaim
acceptance needs a dedicated4KiB backing host, larger exclusive donor extents and native
host memory observations. No QEMU load/install, kernel/module load or production mutation
was performed on the standby VPS.

The IRQ/device code is a deliberately unsafe identity-mapped, MMU-off fixture. The new
ordering correction follows the architecture contract; single-CPU TCG success cannot prove
arbitrary cached/multicore hardware ordering. The bounded clock/reset failure branches,
full UInt16 queue-counter wrap, adaptive pressure policy, general safe DMA typestate and
live-VM recovery remain open. LinuxKbuild, perCPU guard ABI, CFI/ORC/hardening and Apple
Virtualization.framework/container integration require separate acceptance.

Actual Sonnet5.5/max-requested returned an opinion on a public snapshot, without tools.
Ordering, stale-head detection, reset waiting and negative-control findings were reconciled
against source/native evidence. A broad Opus request timed out after3600.575s without a
final report and was not accepted. A narrower actual Opus5.5/max-requested opinion returned
after691.770s, accepting budget/QMP arithmetic but identifying two lifecycle acceptance bugs.
The CLI now requires handled exit0/no escalation and the complete expected diagnostic.
Its receipt records actual warning count, termination, errors and final verdict after checks.
A synthetic QMP peer demonstrated the old binary's falsePASS0 after abnormal SIGTERM
and trailing assertion text; the corrected owner refuses it with exit1 and passfalse receipt.
Four real QEMU modes passed the corrected owner, with actual exit0 and no escalation.
That synthetic peer tests lifecycle refusal only, not device/balloon correctness. Both
reviewers examined supplied snapshots; later fixes were checked natively and by the root,
not misrepresented as a complete final-source model signoff. Provider-effective effort
is unreported. Candidate branchCI38611435069 passed Mac27/Ubuntu; successor acceptance
for the lifecycle correction is recorded in the release evidence.
Graph AST has787 nodes/1383 edges and0 dangling endpoints;17 Swift parse gaps and
semantic-document gaps are retained, so it is a navigation map rather than correctness proof.

Contracts and reproduction are in [HostBalloon](HostBalloon.md). Full memory/kernel
framework work stays open. Original Macray task0106, production network and public links
remain outside this research change.
