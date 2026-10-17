# Native container memory checkpoint — 2026-10-18

## Status and scope

This is a preserved research checkpoint, not a production release. All five product
acceptance gates remain OPEN. The operator requested publication of the achieved
source and a concrete continuation plan. No new experiments, production rollout,
installed container/OrbStack changes, household network changes or data migration
were performed as part of this checkpoint.

The framework is SwiftOSPrimitives. ContainerWorkspace is the temporary application
identifier; final branding is undecided. The intended product is a native Swift
macOS container workspace using Apple container components, with autonomous memory
management and an eventual Docker/Compose migration experience. That product is
not yet complete or equivalent to OrbStack.

The most important distinction: the qualified reclamation path owns its RAM in a
custom Hypervisor.framework VMM implementing Apple Containerization interfaces.
It does not acquire authority over somebody else's VZ-owned allocation, and it
does not add this capability to the installed stock Apple container service.

## What exists

| Layer | Implemented and exercised | Important remaining limit |
|---|---|---|
| SwiftOSPrimitives | Native PageMemory ownership and bounded-memory/control primitives; optional hosted/freestanding research | Not a replacement kernel, Foundation, global allocator or language runtime |
| Native VMM | Linux boot, vminitd/vsock lifecycle, owned backing, up to four-vCPU/two-NIC experimental geometry, CPU parking/join/destruction | Only finite configurations qualified; real product networking and broad image support remain open |
| Guest memory control | Dedicated Foundation-free Swift monitor, bounded framing, sequences/epochs/deadlines, native lifecycle owner | Trusted guest only; full channel/security isolation and untrusted workload support remain open |
| Reclamation | Classic balloon PFN ownership and separate FPR modes; metadata pin refusal, target-zero rescue, cold remap before ACK/resume | Current named owner is coarse 2 MiB dynamic objects; immutable boot floor is excluded |
| Named Darwin backing | Per-object EMPTY/NONVOLATILE transition, direct object residency/compression counts, identity/exclusivity checks, explicit release | Private candidate; fatal-process admission and long soaks still need qualification |
| Application | Native SwiftUI workspace/import/machine list, explicit start/stop, approved helpers/monitor, live resources and reopen/reap | Product autonomy is OFF; no general production container workload or Docker compatibility |
| Storage/recovery | Copy-first private import, file/descriptor authority, native child ownership and finite crash-recovery research | General database sync/unmount, unattended durable recovery and update rollback remain open |

The portable package products are Swift. Optional guest code, the VMM and app are
also Swift. Linux, ClickHouse, Apple frameworks and their public ABI are existing
system components; this work does not rewrite their kernels or allocators in Swift.

## Confirmed measurements

Environment: Apple M2 Max Mac Studio, 32 GiB RAM; macOS 27.0.1 (26A434), SDK 27,
Swift 6.4.1. The lab, build/cache paths, private APFS clones and data are on a
dedicated external test directory. One owned VM runs at a time. Production data
and the installed network/container stacks are excluded.

### Hosted contracts

- Native baseline: 123 release contracts before the ownership diagnostic.
- Ownership diagnostic: 137 release contracts with the original dependency pins.
- Named candidate: 152 strict release contracts after all repairs; final pass
  50.222 seconds, no compiler warnings. Native test execution and collection are
  distinguished: the build wrapper cannot fully map this Swift Testing event
  stream, so the complete native log is retained.
- App/helper: 116 unfiltered release contracts; final exact-source run
  159.745 seconds. Actual signed GUI tests exercised import/boot, RPC and monitor
  readiness, resources, native stop/reap, workspace reopen and native Quit.

The app was qualified against Native commit a3838f9, not the later named-backing
candidate. Compiling or linking the candidate into the app is not yet a qualified
integration or authorization to enable product autonomy.

### Actual native memory controls

1. An ordinary named 64 MiB object's resident backing remained 64 MiB while removing
   half its host virtual views reduced task RSS/footprint by 32 MiB. RSS reduction
   and VA removal alone do not prove backing destruction.
2. Per-entry purgable control completed three 64 MiB resident-to-zero/regrowth
   cycles. Direct resident and compressed/paged-out counts were zero BEFORE reads.
3. A real single-vCPU RWX guest over host RW/NX backing completed 69,633 native
   guest runs, 12,288 exact stage-2 faults and three 64 MiB discard/regrowth cycles
   in 0.444190 seconds. Guest zero checks preceded host probes/refill. Native CPU,
   VM, mapping, port cleanup and process reap succeeded.
4. A one-page wiring negative control returned KERN_SUCCESS from EMPTY but retained
   one resident 16 KiB page. Success alone is insufficient: pre-wire checks and
   post-discard direct counts are mandatory.
5. All four real single-vCPU ordinary/cold FPR and ordinary/cold classic-balloon
   owner/wire modes passed in 1.069256 seconds total. They exercised aliases,
   split PFN ownership, metadata pins, corruption/poison/quarantine, cold regrowth,
   deflate, acknowledgement and explicit close.

The standalone controls' exact tested Swift sources are preserved in
[Mach backing controls](../Examples/MachBackingControls/README.md). Public Darwin
interfaces were sufficient; no C implementation shim, private kernel API,
assembly shortcut or global purge was needed.

### Actual Linux/ClickHouse: named backing, two CPUs

The fresh two-vCPU/two-isolated-NIC run passed in 79.461491 seconds; independent
collection, hashing and preservation checks took 102.905853 seconds.

| Metric | Cycle 1 | Cycle 2 |
|---|---:|---:|
| Pressure table | 557,056 rows of 4 KiB random strings | Same |
| Held pressure payload | 2176 MiB | 2176 MiB |
| Directly observed resident backing retired | 1304 MiB | 1340 MiB |
| Release-to-observed-inflation time | 1.079936 s | 1.181851 s |
| Post-regrowth integrity | 400,000 original rows and expected checksums | Same |
| Post-regrowth load result | 4,999,950,000 | Same |
| Guest OOM / OOM kill / swap | 0 / 0 / 0 | 0 / 0 / 0 |

The original >=1 GiB resident return, 8-second deadline, live active workload,
512 MiB guest reserve and <=5 GiB host peak limits were NOT relaxed. Host peak
RSS was 4,182,687,744 bytes. The 30-second idle window used 1.701084 CPU seconds,
30 samples, no idle requests and no pulses. Host physical footprint in that window
was 1,837,012,200 -> 1,837,028,584 bytes (about 1.71 GiB), with the populated
ClickHouse server still running. This is neither empty-VM idle nor a fair OrbStack
comparison, and is not yet the desired low-idle performance result.

The native path checked 1322 retired whole objects. Its bounded history retained
1024 records: exact references=2; size 2 MiB/offset zero; known identity; no owner
VA hole; direct resident AND compressed/paged-out counts zero after discard and
cold remap; no host warming; stage-2 mapping before ACK/resume. Ownership coverage
samples took 25.417 and 27.709 microseconds. The retained sample is not the entire
history, and an ownership coverage upper bound is not a physical-return metric.

Both actual vCPUs joined and were destroyed; VM and IO cleanup succeeded.
Final balloon PFNs/targets/pending were zero. The original base image content,
inode/times and boot hashes were unchanged. Native memory failure was null and
process-retirement required was false.

The workload explicitly cooperates with a guest allocator purge. It does NOT
prove transparent reclamation of arbitrary applications' live or cached heaps.
No compressed logical byte was credited as resident return. Direct object
backing removal is measured; global free-list growth is not attributed because
other host activity and the compressor can change it independently.

### Failures retained, not explained away

- An older anonymous-backing two-CPU run failed the unchanged resident threshold:
  671.609375 MiB resident and 651.390625 MiB already compressed/paged-out logical
  bytes across 1324 MiB retired logical memory. It is not credited as 1324 MiB
  physical return. No causal dependency-version or speedup conclusion is drawn
  from one later successful named-backing run.
- A four-vCPU RAM run passed its RAM checks but used about 4.548 CPU seconds in
  its idle window, failing the <=3-second gate. The original 2 ms cadence remains.
- One earlier product start exceeded its deadline (10.737920 seconds observed).
  Later successful starts do not resolve the first-start failure.
- Source-only compatibility against Containerization 0.52.0 passed patch
  application checks only. It has NOT been built or runtime-qualified.

## Safety repairs in the named candidate

Three independent own-memory regressions failed before their respective fixes:
foreign fixed-remap cleanup (four issues), already-EMPTY contents (three), and
EMPTY hidden behind an alias (three). Omitting only the exact reference guard
separately caused two alias regressions to fail with five issues.

The corrected owner separates hard identity/shape proof from recoverable
alias/wiring refusal; checks protected content state BEFORE recoverable refusal;
rechecks ownership before explicit unmap; hides poisoned pointers; and never
restores/frees an unknown mapping. Before the first destructive call only a
known-content Refusal permits full restore/BUSY. Native/ownership/restoration
failures latch fatal state. NativeControl then retains process admission and
boot-resource authority.

The TRUE fatal-state/new-manager refusal path still needs an actual post-EMPTY
fault test. LLDB guidance/version was checked, but no fault injection or new
diagnostic production seam was implemented before this checkpoint. No source
field or ordinary successful run substitutes for that test. These checks are
not an atomic defense against a malicious native mutator in the same task.

## Apple container integration and upstream status

The latest official container release checked on 2026-10-18 is
[1.5.0](https://github.com/apple/container/releases/tag/1.5.0), whose
[release manifest](https://github.com/apple/container/blob/1.5.0/Package.swift)
pins Containerization 0.47.0. The tested lab uses that lifecycle/vminitd/OCI
substrate with the checked-in small
[public-backend adapter patch](../Examples/LinuxMemoryLab/Patches/containerization-0.47.0-public-backend.patch).
It makes WriteFileFlags constructible/Sendable and exposes listener construction
and delivery to a separate VMM. It is not a wholesale upstream fork.

The current upstream main manifest is a moving development target; it must not
replace the pinned release silently. The dry-check 0.52.0 checkout is likewise
not an accepted upgrade. The original protobuf 1.38.1 pin was restored after a
private resolver moved it to 1.39.0; both histories are retained and later tests
used force-resolved versions.

The installed Apple container CLI/service is unchanged. There is no installed
production fork, stable backend selection, unattended multi-container runtime,
automatic upgrade integration or Docker/Compose migration yet.

## Recommended implementation sequence

1. **Qualify destructive failure and process retirement.** On an owned frozen
   debug target only, fail the NONVOLATILE restore after a successful EMPTY.
   Prove all CPUs stop/join, no ACK/remap resumes uncertain RAM, fatal authority
   persists, and an independent manager cannot admit a new VM in the same
   process. Include a causal control that removes only the lease-retention
   guard. Reap the process before recovery and preserve both failure and pass.
2. **Integrate one supported named backend.** Keep the stable interface between
   upstream container lifecycle, NativeLinuxVMM, per-VM helper and UI. Build the
   actual app/helper against the qualified candidate, retain approved artifact
   hashes, expose honest memory/failure state and repeat real GUI boot,
   workload, shrink/regrow, stop/reap/reopen. Keep autonomy OFF until this passes.
   Publish a reusable Darwin owner only after its lifetime contract is stable.
3. **Generalize RAM safely.** Exercise boot/dynamic geometry and fragmented PFNs,
   metadata/DMA pins, resets, cancellation, OOM rescue and compression. The
   current 2 MiB grain leaves smaller owned groups unreclaimable. Compare
   smaller named objects with their real kernel-port/map/counting overhead
   before choosing a grain. Ownership upper bounds alone are insufficient.
   Do not discard boot/kernel/metadata or live allocator pages by inference.
4. **Remove idle polling without losing wakeups.** Characterize the native
   WFI/WFE, timer/IRQ, cancellation and pre-entry wake path. Replace periodic
   work only with a tested event/deadline path. Require 1/2/4-vCPU idle passes
   and active IO/regrowth latency/tails without widening existing gates.
5. **Add global multi-VM authority and policy.** One authenticated controller
   must own cross-process reservations, memory pressure, priorities/fairness,
   minimum guest headroom and hysteresis. Handle stale samples, lost peers,
   controller death and all-exits-failed states. Per-controller reservations
   and a successful single VM are not global admission. Qualify XPC/
   SMAppService identity/lifetime contracts before installing a service.
6. **Complete durable and security contracts.** Stage database sync, workload
   stop, filesystem unmount and image close; test SIGKILL, reboot, interrupted
   update, disk reserve, corrupt inputs and recovery journals. Preserve original
   data through copy-first migration. Qualify AF_VSOCK/control authentication,
   guest privileges/capabilities/seccomp/namespaces and malformed device input
   before untrusted workloads. Run multi-hour/day resource and failure soaks.
7. **Finish product and upstream integration.** Implement supported images,
   networking/DNS/ports, volumes/shares/exec/logs and Docker API/Compose matrix.
   Add backend capability/version negotiation, signed packaging, update/rollback
   and explicit unsupported-feature refusals. Test pinned upstream upgrades in
   CI before promotion; keep the adapter patch minimal and upstreamable.
8. **Benchmark and release against explicit gates.** Compare stock container,
   this backend and OrbStack with matched workloads/resource budgets: physical
   object evidence, idle/peak RSS/footprint, CPU/energy, reclaim/regrow p50/p95/p99,
   throughput, data integrity and failure recovery. A second Mac is currently
   unavailable; do not disturb production to fabricate a clean-host comparison.
   Linux/Windows host ports are separate future qualification work.

The five acceptance gates are persistent lifecycle/workload/recovery, general
RAM geometry/overhead, multi-VM/resource/fault/security, fair baseline comparison,
and complete product/compatibility/migration. Every gate is still OPEN.

Do not replace Swift ARC or add a global allocator/assembly bypass without
evidence. Public native object ownership already solved the demonstrated
backing-release mechanism. The remaining critical work is ownership under
failure, policy, compatibility and complete product integration.

## Provenance and retained evidence

Core checkpoints: native a3838f9; named c2cb3a9; Mach ownership 517c77f;
coverage 7e8985c (equivalent named-branch cherry-pick 31a06f6); app ba7815c.
The named host/symbol UUID is 1D2BBA52-9B0C-3E26-B699-113C0CC3E890.
The selected measurements are also preserved as
[checkpoint evidence](MemoryBallooningCheckpoint-2026-10-18.json).

Complete signed sources, host/guest artifacts, native logs, failed runs and base
preservation receipts remain in the owning G24 T7 research directory. Build
caches, images, raw logs, private infrastructure and credentials are not Git
source. Requested exact Claude 5.5/MAX reviews were sometimes quota-limited or
returned mixed model provenance; such answers are not exclusive Opus 5.5
qualification. Parent native tests and independent evidence remain authoritative.
