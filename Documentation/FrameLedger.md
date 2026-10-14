# FrameLedger: retained reservations over borrowed metadata

`BoundedMemory.FrameLedger` is a standard-library-only bookkeeping primitive for
Swift 6.4.1. It retains multiple contiguous reservations and allows out-of-order
release. Frame identifiers are numbers: a reservation grants no pointer, mapping,
physical page ownership or privilege. Backing storage and its release belong to
the caller. Enable the experimental `Lifetimes` feature, as for ScratchArena.

## Storage and ownership

Supply an exclusively borrowed, initialized `MutableSpan<UInt64>` containing at
least two slots. Slot zero is a persistent generation counter; every remaining
slot must initially be zero. Each remaining slot describes one frame. For N frames,
the caller supplies `8 * (N + 1)` bytes, with checked sizing in the backing owner.
There is no additional heap allocation, class, ARC table, Foundation dependency
or synchronization inside the ledger. Ordinary hosted runtime initialization and
page faults are not excluded by this source-level contract.

`FrameLedger`, `FrameReservation`, `FrameAllocation` and `FrameRelease` are
noncopyable and nonescapable. Reservations retain the backing loan's lifetime.
Keep the ledger until all its tickets have been released. Dropping a reservation
keeps its slots occupied; dropping or replacing the ledger strands live tickets.
This deliberate explicit-release API does not silently free a lost capability.

```swift
import BoundedMemory

var metadata = [UInt64](repeating: 0, count: 129)
if var ledger = FrameLedger(metadata: metadata.mutableSpan, firstFrame: 3) {
  if case .reserved(let ticket) = ledger.reserve(frameCount: 4, alignment: 8) {
    // The first aligned frame is 8; this number does not authorize dereferencing it.
    precondition(ticket.firstFrame == 8)
    switch ledger.release(consume ticket) {
    case .released: break
    case .refused: preconditionFailure("The same untouched ledger must accept its ticket")
    }
  }
}
```

The array in this ordinary host example allocates. Fixed InlineArray storage is
used by the Embedded fixtures. The package still compiles for its iOS 18 floor;
host examples using InlineArray require the applicable newer Apple availability.

## Refusal and release contracts

- The exclusive end `firstFrame + capacity` must fit UInt. Initially occupied slots,
  empty capacity or overflowing geometry refuse construction without writes.
- Requests require a positive count and positive power-of-two alignment in frame
  units. First-fit alignment uses the actual frame-number base, not offset zero.
- Fragmentation or an unsatisfiable aligned range returns `capacityExceeded`.
  Every refused request preserves all metadata, including the generation counter.
- Successful reservation increments the counter exactly once. UInt64.max is
  issued at most once; later reservations return `generationExhausted`, while
  existing tickets can still be released. The counter never wraps.
- Release checks storage identity, geometry and the entire range's generation
  before clearing any slot. A foreign or stale release leaves metadata unchanged
  and returns the original ticket for a surviving rightful ledger.
- Reconstruction after complete release preserves slot zero. Unsafe pointer-backed
  callers must never decrease it while stale tickets might exist. Pointer reuse or
  manually resetting generations can violate the unsafe lifetime/ABA contract.
- Safe loan exclusivity prevents simultaneous aliasing/reset. Nonlocal exclusivity
  can be checked dynamically; do not disable it, bypass lifetimes or use Ounchecked.

Reserve, release and availability observation are synchronous and O(capacity).
This first-fit table is suited to small bounded pools, not claimed as a replacement
for a complete Linux buddy allocator. It provides no locking, atomics, reclaim,
GFP execution-context policy, DMA/IRQ safety, typed-object Pin or balloon driver.

## Acceptance

Seven frame test methods cover alignment, fragmentation, out-of-order reuse,
foreign-ticket return, dropped tickets, generation exhaustion, UInt geometry,
reconstruction, stale raw-pointer tickets and whole-range refusal before mutation.
The raw-pointer fault tests intentionally own their storage and do not introduce
a production test hook. Together with existing tests, release and ASan run 29 tests.

Five additional emit-SIL negatives reject ticket copies, double consumption,
escape, reuse of the consumed metadata loan and reset of the borrowed owner.
Combined acceptance is 24 negative fixtures and three positive fixtures. Exact
diagnostics are toolchain-specific; unrelated compiler failures do not count.

`FrameProbe` executes 1,000 cycles with three reservations and three releases per
cycle, checks the exact digest 511500, persistent generation 3000 and every free
slot. The independent digest follows from first-fit frame 8, second frame 4 and
the sum of iteration numbers 0...999. Embedded compilation forbids allocations.
Whole reachable ARM64/x86-64 objects are audited for imports and FP/SIMD operands.
The guest validates the ledger against actual assigned RAM; see
[FreestandingGuest](FreestandingGuest.md).

## Scoped Mac measurement

`Examples/FrameBenchmark` uses the same changing trace and fixed stack storage,
eight warmups and 128 measured batches of 1,000 cycles. It builds with Embedded,
Lifetimes, strict memory safety, Werror, O and `-no-allocations`; checks remain on.
The macOS helper measures mach_absolute_time, checks every batch's exact digest,
checks final generation 408000 and all free slots, then outputs p50/p95/p99
nanoseconds per cycle and digest 65472000. Sort and output occur outside timing.

On an M2 Max, macOS 27.0.1, Swift 6.4.1, three local low-priority runs observed:

| Metric | Observed range |
|---|---:|
| p50, batch-average cycle | 185–189 ns |
| p95, batch-average cycle | 197–207 ns |
| p99, batch-average cycle | 202–223 ns |
| Binary | 54,304 bytes |

A cycle includes three reservations, three releases, two complete availability
scans over 128 slots and validation/checksum work. These percentiles describe
batch averages, not individual-request tail latency. Concurrent host work was not
disabled, so this is a reproducible baseline rather than a controlled language
comparison or a production/network latency promise. No Rust comparator is added
for this new API yet.

The measured executable imports only libSystem, with stack checks, bzero, entropy,
clock and output functions; it does not import the normal dynamic Swift runtime.
The first run's process maximum RSS was 1,687,552 bytes and peak physical footprint
1,229,160 bytes; these are different counters. This standalone Embedded result
does not establish that an ordinary Swift/NIO daemon or UI has the same baseline.
No malloc interposer or whole-process memory-management claim is implied.

To reproduce the Mac fixture, combine FrameLedger.swift, FrameTrace.swift and
FrameBenchmark/main.swift with the pinned compiler and those flags. The ordinary
low-level checker also builds/runs it on Darwin and checks the observation format
and digest, without imposing a flaky timing threshold.
