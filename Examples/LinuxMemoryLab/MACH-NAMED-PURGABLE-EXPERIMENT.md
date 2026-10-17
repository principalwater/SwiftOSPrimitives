# Private named purgable Mach backing for dynamic RAM

Status: PENDING product adoption. Private `codex/named-purgable-linux` experiment only.
Main Native and Product sources and installed runtimes remain unchanged. All five original
product gates remain OPEN. Nothing is exported into the public PageMemory library.
Qualified environment: macOS 27.0.1, SDK 27, Swift 6.4.1, Apple M2 Max, native 16 KiB pages.
Other operating systems, host page sizes and future kernels require separate qualification.

## Ownership and destruction

Each dynamic 2 MiB extent owns one named purgable Mach object and one host mapping. The
retained memory-entry send right holds one object reference; its owner mapping holds the
second. After stage-2 unmap the observed count must be exactly two. An alias makes three
and refuses destruction. The condition is never weakened to a maximum or minimum count.

`MachNamedBacking` is a confined final class with no implicit native-resource release in
`deinit`. All methods and pointer access require its native creator thread. The pointer is
unavailable while detached, closed or poisoned. Only explicit close releases resources,
after actual CPU joins and native destruction. Abandonment retains them until process exit.
A class identity prevents accidental value-copy double close through the existing Extent.

Construction uses public Darwin APIs directly from Swift:

- `mach_make_memory_entry_64` with NAMED_CREATE, PURGABLE and READ/WRITE for exactly 2 MiB.
- Kernel-selected `mach_vm_map`, offset zero, no copy, host current/maximum RW and NX,
  application tag 240 and INHERIT_NONE. No caller supplies an address.
- Checked returned size, native page size, address alignment, end arithmetic and partial
  resource cleanup. Cleanup failures remain attached to the primary error.

Before destruction every affected guest CPU is parked and every affected stage-2 mapping
is removed. `ownedRegion()` proves exact shape, tag, object identity, maximum protection,
no external pager and no shadow. Unknown or replaced mappings poison the owner. Explicit
close rechecks ownership and never frees an unknown range. Known-object aliases, temporary
protection drift and wiring are recoverable refusal conditions before any destruction.

Inspection validates NONVOLATILE state before recoverable reference refusal. An alias must
not hide contents already lost by an external EMPTY. Native query errors, lost identity or
unprotected contents are fatal. Only a pre-destruction Refusal permits full stage-2 restore
and BUSY/REPORT_SKIPPED. A restore failure is fatal too. These checks detect cooperating
code's accidental misuse; they are not atomic protection against hostile native code in
this same task. Process isolation remains the stronger boundary.

The exact object is rechecked immediately at destruction, including after bulk planning.
Per-entry SET EMPTY/GET, then SET NONVOLATILE/GET discard the whole object's contents.
No live object is made VOLATILE; there is no global purge or sub-range purge. EMPTY is the
first destructive operation. Every error from that point is sticky and cannot roll back.

`mach_memory_entry_get_page_counts` must report zero resident and zero compressed/paged-out
pages before any host read, cold stage-2 remap, ACK or resume. Kernel success alone is
insufficient: a separate wired-page negative control returned success while one page stayed
resident. Cold replacement keeps the same HVA/object and GPA; no host memset warms it. Held
control reuses preserved pages and explicitly zeroes them before guest reuse. Unplug can
remove the known HVA while retaining its emptied entry for a later replug. Boot RAM remains
outside this dynamic-owner experiment and still uses its existing backing.

## Failure and evidence

MemoryDevice latches `nativeFailure` on uncertain ownership, native failure or failed
restoration. No later plug/retirement is permitted. NativeControl withholds boot-resource
retirement and its process-admission lease on that flag. A poisoned known object can still
be explicitly closed after CPU shutdown; lost mapping ownership is retained until exit.
The actual fatal TRUE/new-manager admission path remains to be fault-qualified.

Observation records distinguish object content discard from virtual-range removal. Named
replacement reports `oldVirtualRangeAbsent=false` and `ownerVirtualBytesDeallocated=0`.
It includes backing kind, exact object/offset/reference count, direct resident/dirty/swapped
counts, after-discard and after-remap counts, quiescent epoch, ACK/resume and host-zeroing
provenance. Region/task counters are context only. Compressed logical bytes are not resident
return, and `physicalReleasedBytes` remains null: global free-list attribution is not made.
Histories remain bounded; total events and retained sample counts are distinct.

## Regression and hardware qualification

Three real own-memory negative controls failed before their corresponding repairs:

| Regression | Intended failure before repair |
|---|---|
| Old owner after fixed remap to a different object | Four issues; foreign mapping wrongly exposed and freed |
| Object externally made EMPTY | Three issues; lost contents wrongly reported recoverable |
| EMPTY object with retained alias | Three issues; alias refusal hid lost contents |

Omitting only the exact reference guard separately caused two alias regressions to fail
with five issues. Guard restoration and the ownership/state repairs passed all 152 strict
release tests. The final source clarification passed in 50.222 s, with no compiler warnings.
Foreign-thread fixtures use a real pthread and join. Address-absence and abandonment checks
run in fresh children; cleanup errors are recorded. Actual faults and wrong native answers
are never replaced with synthetic zero counts.

Freeze `native-named-backing-v1` contains 273 source files, signed host/standalone artifacts
and matching host symbols (UUID `1D2BBA52-9B0C-3E26-B699-113C0CC3E890`). Original protobuf
1.38.1 and other dependency pins were forced and preserved.

All four real single-vCPU wire controls passed in 1.069256 s total: ordinary/cold FPR and
ordinary/cold classic balloon. They exercised alias restoration, split PFN ownership,
metadata pins, zero/canary/regrowth/corruption, poison/quarantine, deflate and explicit close.
A separate real guest-execution control passed 69,633 native runs, 12,288 exact stage-2
faults and three 64 MiB discard/regrowth cycles with guest RWX over host RW/NX memory.

The fresh two-vCPU/two-NIC isolated Linux/ClickHouse run passed in 79.461 s (102.906 s with
independent collection and original base hashing). Its two cycles removed 1304 and 1340 MiB
of directly observed resident backing in 1.080 and 1.182 s. Both SQL integrity/load checks
matched; guest OOM/swap were zero. Original >=1 GiB, 8 s, active workload, 512 MiB guest
reserve and <=5 GiB host peak gates were preserved. Peak RSS was 4,182,687,744 bytes. The
30-second idle window used 1.701084 CPU seconds, 30 samples, zero idle requests and pulses.
This is a functional pass, not an optimized-idle claim.

All 1322 retired extents were checked by the native path. The bounded history retained 1024
records, each showing exact references=2, whole 2 MiB/offset zero, no HVA hole, zero direct
resident/swapped counts after discard and cold remap, no host zeroing and mapping before
resume/ACK. Ownership diagnostic samples took 25.417 and 27.709 microseconds. No compressed
logical byte was credited as resident return. Both actual CPUs joined/destroyed, VM/IO
cleanup succeeded and final balloon PFNs/targets/pending were zero. Original rootfs content,
metadata and boot hashes were preserved. Native failure was null and process-retirement
required was false; that does not qualify the TRUE branch.

The workload explicitly cooperates with a guest allocator purge. Arbitrary-app transparency
and a causal speedup over older runs are not established. Retained G24 evidence outside Git:
`named-backing-two-v1-independent.json`, `named-device-wire-v1-independent.json`, their native
receipts, signed source/host/symbol freezes and before/after regression logs.

Next: actual post-EMPTY failure and new-manager refusal, multi-vCPU idle/wake, resource
fairness and long soaks, durable recovery, compatibility and the remaining five product
gates. No production adoption, performance-parity or OrbStack-equivalence claim follows
from this private experiment.
