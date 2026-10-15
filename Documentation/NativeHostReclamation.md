# Native macOS host reclamation

SwiftOSPrimitives can retire and reclaim its **own** macOS page backing without
Virtualization.framework, a guest, a daemon, kernel extensions or custom assembly.
The opt-in `PageRegion.allocate(backing: .reclaimable)` path already uses native
Mach purgeable objects. This slice adds native page-disposition observations and
bounded experiments; it does not change the existing default backing.

```swift
var region = try PageRegion.allocate(byteCount: 2 * 1024 * 1024, backing: .reclaimable)
try region.withMutableBytes { bytes in bytes[0] = 73 }
try region.eraseContents() // Sensitive current bytes: erase BEFORE discarding.
let request = try region.discardContents()
let flags = try region.darwinPageDispositionCounts()
let resident = try region.residentPageCount()
try region.resetToZero() // Required before lending bytes again.
try region.release()     // Explicit error reporting and retry ownership.
```

`darwinPageDispositionCounts` and `DarwinPageDispositionCounts` are macOS-only APIs. The package
requires macOS27; iOS18 and Linux keep their existing native APIs. No older macOS
fallback or iOS counterpart is advertised. `residentPageCount` remains portable.

## Observation contract

The owner queries only its current mapping through `mach_vm_page_range_query`.
Each batch queries at most255 native pages into256 `integer_t` entries (1KiB
scratch). The request reserves one spare entry and initializes count to pages+1;
only a returned count equal to pages is accepted. An echoed/unwritten count,
wrong granularity, short reply or error therefore fails before any entry is read.
The native count is a **number of entries**, not bytes. The owner retains its state
and can retry. Released and uncertain-release owners refuse the query. Retired
contents remain unreadable while metadata can still be observed.

The operation is O(mapped pages), uses bounded temporary storage, and can block or
allocate in the kernel. A caller-declared `.nonblocking` context refuses before
making any native query; it is not an IRQ-state detector. No background sampler,
actor hop, monitoring thread, raw pointer or cross-task authority is added.
Run observations outside latency-critical network executors.

The returned counters count XNU's PRESENT, PAGED_OUT and REUSABLE flags, including
rounded allocation padding. REUSABLE is a subset of PRESENT in the pinned walker;
the selected counters are not a partition. They are collected
across successive queries, not atomically with each other, `mincore` or task ledgers.
PAGED_OUT includes compressed backing; it does not uniquely identify disk swap.
PRESENT is the native disposition, not a physical frame number. XNU's optional
`task_self_region_footprint` path can synthesize accounting dispositions. Thus even
this lower-level observation must not become a universal physical-release oracle.

Both page-disposition and the existing Darwin `residentPageCount` bracket their
native queries with read-only mode checks. `vm.self_region_footprint` must be0;
`vm.self_region_page_size` must report automatic1 or the owner's native page size.
The actual kernel key is `page_size`, not `page_shift`. Denied/malformed reads or
unsupported modes fail closed. The library never changes these settings. The
checks do not establish atomicity against another thread toggling task-wide mode
and restoring it between reads. This is not a physical ownership decision API.

Darwin mincore also caps each vector extent against the current XNU minimum4KiB
query geometry. A finer override must not overrun a vector sized for16KiB pages.
The shared guard compiles on iOS18; runtime permissions and device acceptance are
unverified, and a sandbox denial produces a typed refusal rather than unchecked
sampling. A Darwin caller can now receive a refused-mode observation error where
it previously received potentially misinterpreted data.

A WIRED constant in a header is insufficient evidence of working per-page wired
telemetry. The pinned public range-query implementation does not set that bit in
its normal object traversal; this API intentionally exposes no misleading wired
counter. Wired residue is exercised by actually wiring one owned page, observing
retention, unwiring, requesting EMPTY again and observing its disappearance.

Neither request acceptance nor a counter delta populates
`Reclamation.physicalReleasedBytes`: it remains `nil`. Global free-memory changes
are noisy and are not attributed to this probe. Unmapping, purge and erasure have
separate ownership and security meanings; see
[MemorySecurityAndReclamation](MemorySecurityAndReclamation.md).

## Bounded native experiment

```text
swift run -c release page-memory-probe native-reclaim held        8 2097152
swift run -c release page-memory-probe native-reclaim erased      8 2097152
swift run -c release page-memory-probe native-reclaim anonymous   8 2097152
swift run -c release page-memory-probe native-reclaim reusable    8 2097152
swift run -c release page-memory-probe native-reclaim reclaimable 8 2097152
```

The CLI caps the candidate region at16MiB and cycles at16. A separate8MiB live
canary is checked in full before and after each cycle; erasure and reuse are also
checked in full. The probe releases only its own regions, with no VM, network,
service, swap, memory-pressure or system allocator reconfiguration. Native page
queries are bracketed by `mincore`; self RSS and footprint are recorded separately.
No aggregate throughput, idle cost, packet p99 or universal language comparison is
inferred. `erase_verify_ns` includes readback; `discard_ns` times the request only.
The accepted final probe initializes bounded numeric record storage before the
measurement window and formats JSON only after release. It records the actual
Reclamation fields, not a manufactured physical-release value. Held and erase-only modes provide
finite paired controls, not a sustained-pressure experiment.

Final eight-cycle results per mode on M2 Max/macOS27.0.1/Swift6.4.1,
with native16KiB pages and numeric records initialized before measurement:

| Mode | PRESENT after, 2/16MiB | REUSABLE, 2/16MiB | RSS delta | Footprint delta |
|---|---:|---:|---|---|
| Held |128/1024 |0/0 |0 |0 |
| Erase only |128/1024 |0/0 |0 |0 |
| Anonymous/MADV_FREE |128/1024 |0/0 |0 |0 |
| MADV_FREE_REUSABLE |128/1024 |128/1024 |0 |-2/-16MiB |
| Mach purgeable EMPTY |0/0 |0/0 |-2/-16MiB |-2/-16MiB |

PAGED_OUT was0 throughout these controlled runs. The earlier probe formatted
records inside the measurement window and showed up to48KiB of observer noise;
those historical results are retained separately. The final80-cycle matrix
observed only the exact deltas shown above, without that formatter noise.
Both `mincore` observations agreed with the state shown; canary/reuse checks
passed. XNU mincore and page query share the same range-info walker: their
agreement checks our plumbing, not an independent physical classifier.
A separate region-info/GET_STATE control below corroborates the result. This is
evidence of removal of this exclusive mapping's resident backing,
not a guarantee that a global free-memory counter must rise by2MiB. EMPTY may skip
busy/wired pages and compressor work in flight. These are normal-pressure results;
forced compression, COW/fork, DMA and hard real-time contexts are outside this test.

## Independent aggregate control and unverified cases

A separate native control queries `mach_vm_region_recurse` with the actual SDK27
V3 layout, exact returned size, expected base/extent, read/write protections and
non-submap status. The region's own object uses a distinct aggregate walker.
`VM_PURGABLE_GET_STATE` separately checks NONVOLATILE before and EMPTY after purge.
Native execution reported128→0 resident pages,0 compressed pages,0 user wiring,
V3 `pages_wired == 0`, share_mode2/private,ref_count1,shadow_depth0, and EMPTY2.
A separate complete one-page mapping reported V3 wired1 and resident1 after
EMPTY, then wired0/resident0 after munlock and repeated EMPTY. Using the complete
one-page mapping avoids assuming mlock leaves a larger map entry unsplit.
These results belong to the constructed exclusive regions, not arbitrary mappings.
The control refuses older/shorter layouts; it is a macOS27 experiment with no
inferred compatibility fallback. Its output contains no raw virtual addresses.

Compressed-positive runtime classification remains **UNVERIFIED**: none of these
runs produced a PAGED_OUT page. Source argues the flag's compressor semantics;
that is not an actual compressed-page positive control. Shared/COW/alias handling,
footprint-mode interpretation, transient busy-page and pressure/compressor races
also remain outside the physical-attribution claims. The library returns raw
selected flags and makes no multi-source physical verdict.

The16MiB matrix runs the modes in reverse order and repeats eight cycles per
mode. Across both sizes all80 cycles retained the complete canary and reused
correctly. The final median native query was40.6–72.5us for2MiB and
295.3–301.7us for16MiB across the five modes. These are observations on this host,
not statistical tail bounds or independent calibration of kernel classification.
No automatic polling or network-path calls were installed.

## Validation and allocation scope

Final native Release and Address Sanitizer runs each passed44 tests in6 suites.
All36 compiler ownership/lifetime contracts passed. The iOS18 module compiled,
and the x86_64 static Linux consumer built with the official Swift6.4.1 SDK;
neither is a new device/VPS runtime acceptance. The standalone Mach fault and
native V3/alternatives controls also passed. Product symbol inspection found no
fixture aliases defined in the package executable.

A private consumer actually calling the new counters built and ran in hosted
Embedded mode, checked a warm2MiB region and its EMPTY result, and released it.
An additional full-source build with `-no-allocations` was **refused** by Swift6.4.1
with allocating String/collection-storage diagnostics. Its cause has not been
isolated to a particular library or compiler path. Embedded compilation alone
therefore does not establish an allocation-free PageMemory consumer. The
allocation-free frame/guest examples have their own separate compile gates;
those results must not be generalized to this API. Kernel/libSystem work may
also allocate or block regardless of Swift heap behavior.

## Native alternatives and assembly

`munmap`/`mach_vm_deallocate` release owned virtual mappings. Mach EMPTY allows a
purgeable virtual reservation to survive while reclaiming eligible backing.
`malloc_zone_pressure_relief` asks a native malloc zone to return freed reserves;
it cannot collect live Swift objects, repair ARC cycles or discard live NIO buffers.
Its returned byte count is the allocator's report, not a physical-memory meter.
Use a measured bounded goal outside packet processing; do not poll every zone.

An additional native control used an exclusively owned malloc zone with64 live
64KiB blocks (4MiB). A bounded4MiB pressure-relief request returned0 while blocks
were live and preserved every byte. After explicit erase/free of all blocks, it
again returned0 and RSS was unchanged. This is a valid ineffective-relief result,
not evidence that the API always fails or that cached pages were physically freed.
Destroying that owned zone completed the control; no other zone was targeted.
There is no new allocator-relief wrapper or automatic global purge loop.

SDK27 also exposes `MADV_ZERO`. The pinned XNU `vm_map_zero` implementation zeros
resident pages and drops compressed pages rather than faulting them in. This is
not eager physical reclamation of all resident pages, and is not a substitute for
`eraseContents`' overwrite-before-discard security contract. A native2MiB control confirmed no resident pages were created for a cold region
(0→0); all128 warm pages remained resident after ZERO while full zero readback
passed. RSS was unchanged. This slice adds no overlapping public erasure wrapper
for it.

ARM's `DC ZVA` is an accelerated zero-writing operation, not a page-free operation.
The Arm-owned optimized memset implementation checks `DCZID_EL0`, length and
alignment before using it. Ad-hoc unchecked inline assembly can overwrite beyond
the requested range or be unavailable/trapped; it gains no kernel authority.
`MADV_ZERO_WIRED_PAGES` is another native map-entry behavior: it requests zeroing
of still-wired pages when an entry is deleted. It is neither a general reclaim
operation nor a replacement for erasing all current owned bytes before discard.
Cache maintenance, CPU fences and ordinary zero stores do not decrement VM object
references, remove mappings or release an allocator's reservations. Replacing the
supported Mach/libSystem boundary with hardcoded SVC numbers would still cross
the kernel boundary while adding ABI risk. No custom assembly was added here.

Swift already compiles to native machine code. Its direct calls through imported
Mach/POSIX ABI declarations are native OS integration; an implementation in another
language is not required. Further optimizations should target measured object
ownership, pool budgets, batch size and syscall frequency, retaining validation,
non-elidable erasure and error-reporting/retry ownership.

## Reply freshness and mode regressions

A private identical echo fixture compiles against the preserved pre-fix source
(with only the unreleased API name adapted) and fails with `echoAccepted`. The
hardened source refuses the unwritten reply and passes. Standalone linker faults
also exercise native errors, short/oversized counts and nonblocking refusal. They
query a retired owner without re-enabling byte access, and reject release-pending
owners. Native task-footprint and per-thread4KiB overrides are refused by both
observation paths, then explicit native geometry is restored in that test process.
CI checks that fault definitions never appear in the normal product's defined
symbols. No production test hook or sanitizer bypass is added.

On the tested OS, a separate disposable probe observed getter1 initially, setter
4096/getter4096, setter0/getter-2147483648, and setter16384/getter16384. The library
refuses that invalid observation geometry. The test fixture seeds explicit native
geometry and restores that exact valid value; it does not claim zero restores the
automatic default. No process-external or persistent setting was changed.

## Sanitizer qualification

The root library's44 Release and44 Address Sanitizer tests pass, including the
five rounded-batch geometries. The standalone V3 native wired control also passes
without instrumentation. Its ASan version correctly refuses the required actual
wiring check: the runtime logs `AddressSanitizer ignores mlock/mlockall/munlock/munlockall`
and returns success from the intercepted mlock without wiring the page. This is
not a physical-wiring pass and is not bypassed or silently skipped. The earlier
aggregate-only standalone ASan control passed before adding the wiring condition.
The native acceptance remains required; no production/library guard was weakened.

This behavior is explicit in
[LLVM's mlock interceptor](https://github.com/llvm/llvm-project/blob/llvmorg-22.1.0/compiler-rt/lib/sanitizer_common/sanitizer_common_interceptors.inc).
A successful mlock return alone is insufficient evidence for a pinned or wired
memory claim under instrumentation. Actual kernel state must corroborate it.

## Primary references and limits

The source revision below is public upstream evidence, not a claim that it is the
exact source of the installed kernel:

- [XNU vm_object_purge and purgeable control](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/vm/vm_object.c)
- [XNU range query count/copyout](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/vm/vm_user.c)
- [XNU object/accounting query and vm_map_zero](https://github.com/apple-oss-distributions/xnu/blob/f6217f891ac0bb64f3d375211650a4c1ff8ca1ea/osfmk/vm/vm_map.c)
- [Apple non-elidable memset_s implementation](https://github.com/apple-oss-distributions/Libc/blob/71bbe350ab79eef58113991d817ccc6165061a64/string/NetBSD/memset_s.c)
- [Arm optimized memset and DC ZVA checks](https://github.com/ARM-software/optimized-routines/blob/97362b2eab91d35d30c4ac2c8c79dcd4dae4331b/string/aarch64/memset.S)

The Virtualization.framework helper's backing, general physical page allocation,
physical Pin/DMA,64KiB Linux, exact Linux Kbuild/hardening and production
apple/container adaptation remain independent open work. No production deployment
or service ownership transfers from this research slice.

## Emulation deadline qualification

During broader regressions one unchanged ring-wrap image hit its60s total budget;
a later full run hit the100ms per-completion inflate deadline. The earlier passing
and failing ring images have identical SHA256. The identical ring image completed
the exact protocol in an isolated run; the private validator initially forgot the
existing exact QEMU host-page warning, and immutable raw output was revalidated
against the same strict marker/diagnostic contract. The original failures remain.
No host-contention cause is asserted proven.

The reference QEMU guest now allows at most1s for a single completion, retaining
all descriptor identity/length/used-index/barrier/reset checks and the independent
60/120s wrap deadlines and host supervisor bounds. This calibrates the optional
emulation prototype, not a production network timeout or a hardware latency SLA.
The complete calibrated positive and injected-negative profile passed natively
in163.307s. Both earlier failed full runs and the raw isolated-image output
remain preserved; they are not relabeled as successful runs.
The4KiB guest/16KiB host balloon diagnostic remains retained and physical backing
unverified; absence of that warning would not establish physical reclamation.
