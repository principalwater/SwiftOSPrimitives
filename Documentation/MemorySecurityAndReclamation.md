# Memory security and physical reclamation

The opt-in PageRegion reclaimable backing uses a private nonvolatile Mach purgeable
object on Darwin. macOS uses mach_vm_*; the iOS18 SDK exposes the native vm_* family
instead. Linux keeps anonymous private mmap/DONTNEED. Existing anonymous/default
behavior is unchanged. All mappings remain single-owner, noncopyable, non-Sendable,
with synchronous lifetime-bound byte lending and native typed failures. There is no
raw pointer, remote-task authority, physical address, kernel module or automatic VM
controller in the package products.

```swift
var scratch = try PageRegion.allocate(byteCount: 2 * 1024 * 1024, backing: .reclaimable)
try scratch.withMutableBytes { bytes in bytes[0] = 73 }
try scratch.eraseContents() // When current bytes are sensitive, erase BEFORE discard.
let request = try scratch.discardContents()
let remaining = try scratch.residentPageCount()
try scratch.resetToZero() // Required before CPU access or reuse.
try scratch.release() // Explicit error reporting; failed release retains ownership.
```

## State and security boundary

Allocation starts nonvolatile/active. A purge request retires byte access BEFORE the
native call; an error leaves it retired and retryable. Reclaimable Darwin discard
always issues EMPTY, including repeated requests: busy/wired pages can survive an
otherwise successful purge. A later bounded request can reclaim residue after those
conditions clear. No automatic spin/retry/background process is installed. Before
initializing, reset/erase restores NONVOLATILE. Reset explicitly zeros logical bytes
on Darwin, rather than relying on all pages having been purged. Purged EMPTY contents
are never exposed. The library does not offer a volatile cache with retained contents.

Any explicit unmap failure quarantines the owner: only release retry is allowed;
reset, erasure, further discard and residency queries refuse uncertain backing.
Nonblocking release refusal leaves the previous state intact. Destruction makes one
final attempt and cannot report failure; use explicit release when an error matters.

Explicit erase overwrites the entire mapped extent, including rounded padding, using
memset_s on Darwin or explicit_bzero on Linux. Native erasure cannot be optimized out
as a dead ordinary store. Refused NONVOLATILE restoration or partial erasure errors
leave access retired; success restores zeroed active bytes. Caller-declared nonblocking
erase refuses before any state change or native write. Existing discard/reset methods
can fault/block; they are not IRQ-safe and must not run on a latency-critical executor.

Erasure can commit the entire mapped extent, even for a sparse or discarded region;
budget that temporary footprint before calling it. Do not skip nonresident pages based
on mincore: compressed/swapped bytes can still be sensitive. These APIs are cleanup
building blocks, not an automatic emergency memory-pressure loop.

Erasure is explicit, not an automatic destructor guarantee. Reset is not a secure erase either: Linux reset can discard current dirty frames,
and Darwin reset uses ordinary initialization. Erase sensitive bytes before reset,
discard or release. Erasing after discard can
allocate new zero-filled backing and cannot scrub already released old pages. Neither
erasure nor unmap promises removal of earlier copies in String/Data, registers, swap,
compressed snapshots (including Darwin compressor and Linux zswap/zram), COW copies held
by fork children, dumps or a device. Avoid copying secrets into general containers;
use dedicated key-management APIs for long-lived keys. No same-process memory API
protects against arbitrary unsafe code, root/debugger authority or raw task access.
Fork, external raw mapping mutation, pinning and DMA are outside this owner's safe
contract. mlock can deliberately prevent physical reclaim; do not impose it on a
reclaimable pool while expecting those pages to be returned.

## What each observation means

- Erasure proves current addressable bytes were overwritten, not that RAM was returned.
- Advice/purge success proves native request acceptance, not a number of reclaimed bytes.
- mincore reports residency of this mapping at one point. It is not global free RAM.
- Process RSS and Darwin physical footprint are separate native observations. Reusable
  ledger advice may drop footprint while pages remain resident, and an accepted native
  reusable request can be skipped without changing the ledger (for example shared/shadowed
  objects). usesReusableAccounting records advice state, not independently measured effects.
- Mach EMPTY can remove actual backing while preserving the virtual reservation. Its
  successful return still does not count skipped busy/wired pages. physicalReleasedBytes
  remains nil; no released-byte value is manufactured from the request size.
- VM balloon target and device-used-ring acknowledgement are independent. Guest CPU
  ownership must remain relinquished until real deflate/reset quiescence, even if a
  host target or footprint looks correct. This page owner cannot reclaim another VM's
  pages or release DMA frames based on arithmetic alone.

The backing is a useful native building block for an application cache/scratch pool.
Virtualization.framework and apple/container require a separate tested adapter and
host/guest ownership protocol. Existing networkless guest/QMP tests are not physical
VM-backing proof. LinuxKbuild, cache-coherent DMA and physical pinning remain open.

## Primary references

[XNU vm_object_purge](https://github.com/apple-oss-distributions/xnu/blob/main/osfmk/vm/vm_object.c)
explicitly skips busy and wired pages and reaps purgeable backing. The installed SDK's
mach/vm_purgable.h and mach/vm_statistics.h define EMPTY/NONVOLATILE and PURGABLE flags.
[Linux madvise](https://man7.org/linux/man-pages/man2/madvise.2.html) describes anonymous
DONTNEED and page locking. [Linux explicit_bzero](https://man7.org/linux/man-pages/man3/bzero.3.html)
distinguishes non-elidable erasure from elimination of other copies. Platform deployment
and actual native checks are documented in the accompanying report; iOS compilation
alone is not device runtime or App Store acceptance.
