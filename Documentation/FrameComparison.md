# Cached frame-count comparison

Measured 2026-10-14 on M2 Max, 32 GiB, macOS 27.0.1 (26A434).
Swift 6.4.1 uses its shipped LLVM toolchain; Rust 1.96.0
(ac68faa20, LLVM 22.1.2) uses core/no_std. This does not compare compiler-identical
backends. Every native target pins apple-m2, with macOS deployment 27.0.

## Change and contract

FrameLedger previously scanned all frame words for every availableCount read.
It now retains an exact native-Int count, updated only after successful reserve
and fully validated release. Requests exceeding the free count refuse before
search, after the original argument and generation guards.

The metadata format, first-fit behavior, noncopyable/nonescapable loans,
explicit-release/drop behavior and error precedence stay intact. Release rejects
zero generations, verifies the entire range and checks the derived count invariant
before clearing any slot. No backing allocation or physical page reclamation
occurs. External unsafe metadata writes while a ledger is live violate the cache's
contract; this is not a self-repairing corruption census.

## Method

The same Swift fixture runs with immutable experimental.4 source and current
source, in both Embedded and ordinary hosted modes. Rust has both corresponding
algorithms, selected at compilation. All six executables retain checked arithmetic,
bounds/assertions and stack protection. Rust requests strong guards with a scoped
experimental flag; actual guard heuristics and placement differ between compilers,
so identical whole-program hardening is not claimed.

Three observations per executable were interleaved, with the middle order reversed.
Processes ran at nice 19. The first observation included cold process-launch work;
initialization, sorting/output and metadata checks are outside the timed batches.
Other host activity remained enabled. All 18 runs agreed on all 15 independent
digests, generations and complete post-release metadata checks.

The machine code retains repeated noninlined step calls and owner-scalar loads
inside the measured loops. Swift Embedded imports only libSystem functions:
stack guard/failure, entropy, bzero, clock and character output. Rust imports
guard/failure, abort, bzero, clock and output. No Swift heap-allocation or ARC
imports occur in this Embedded executable; this does not audit foreign-library
allocation or an entire hosted application's memory behavior.

Native timebase is 125/3 ns per tick (about 41.67 ns). Consecutive-read median
durations round to zero ticks. The 32-iteration full-refusal samples at 2–3 ns per
step are close to quantization/call overhead; they cannot rank the two languages.
All raw clock pairs and batch durations were retained, without subtracting cost.

## Results

Ranges are the observed p50 of 32 batch-average steps in each of three runs,
not individual-request tail latency. At 65,536 frames:

| Algorithm/build | Churn cycle | Full refusal | Fragmented refusal |
|---|---:|---:|---:|
| Swift Embedded, scanning | 56,761–58,586 ns | 140,014–144,733 ns | 80,979–81,924 ns |
| Swift Embedded, cached | 35–38 ns | 2 ns, near floor | 53,500–57,380 ns |
| Rust core, scanning | 60,045–61,241 ns | 157,544–165,085 ns | 77,429–78,986 ns |
| Rust core, cached | 33–35 ns | 3 ns, near floor | 52,677–54,239 ns |
| Swift hosted, cached | 35–36 ns | 2 ns, near floor | 51,916–55,880 ns |

A churn cycle includes three reservations, three releases, two availability
observations and correctness checks. Most improvement comes from removing
O(capacity) observation work. Fragmented searches remain O(capacity); the cached
counter does not transform this first-fit table into a buddy allocator.
One Rust baseline observation had a roughly 1.95 ms p99 batch mean for full refusal:
retain it as scheduler/host noise rather than silently discarding it.

Across capacities 128–65,536, cached churn p50 ranges were 34–38 ns for Swift
Embedded and 33–35 ns for Rust. These comparable synthetic results do not prove
general Swift/Rust superiority or production network latency.

## CPU and memory

Whole-process user CPU for this bounded suite was about 0.93–0.94 seconds for
scanning Swift Embedded and 0.98–1.02 seconds for scanning Rust, versus 0.04 seconds
for both cached variants. System CPU rounded to 0.00 seconds in the cached runs.
These coarse counters include untimed setup and are not per-operation CPU metrics.

| Cached fixture | Binary bytes | Maximum RSS bytes | Peak physical footprint bytes |
|---|---:|---:|---:|
| Swift Embedded | 54,560 | 2,195,456 | 1,720,680 |
| Rust core | 57,864 | 2,195,456 | 1,704,296 |
| Swift hosted, minimal | 57,488 | 2,473,984 | 1,900,976 |

The fixed table itself occupies 524,296 bytes on the main stack; the count costs
one additional native word per ledger. RSS includes touched stack, image and
system accounting. Physical footprint is a different Darwin counter. The small
hosted result uses no Foundation/NIO/UI payload and cannot explain every earlier
daemon/runtime RSS difference. Neither a global allocator nor VM ballooning was
added to obtain these results.

## Validation and limits

Local release and ASan pass 30 tests. The new naive occupancy oracle exercises
144 geometries; added cases protect alignment/exhaustion precedence and unchanged
generations after both fast and scanned refusals. All 24 negative lifetime
consumers and three positive controls pass. iOS 18 module compilation, static
Linux build, whole ARM64/x86-64 Embedded objects and all six isolated QEMU guests
pass. Existing ELF/stack-guard/memory-boundary controls remain enforced.

Opus 5.5 and Sonnet 5.5 returned tool-free source opinions with max effort
requested and 1,800-second timeouts. The provider reports canonical 5.5 models;
effective effort is not separately attested. Their concrete counter/contract/test
findings were reconciled; later portability/observation tooling received native
validation, not a falsely claimed second model review.

The fixture is prepared for 64-bit Linux, and Swift hosted/Embedded execution is
part of CI. Rust Linux execution additionally checks actual stack-guard imports
and both algorithm traces. No weak live VPS was loaded; weak-VPS measurements
remain separate work. Physical allocator policies, typed Pin,
interrupt/DMA contracts, Linux Kbuild integration and VM ballooning remain outside
this release. Consumer production adoption requires its own acceptance.

See [the fixture](../Examples/FrameComparison) for exact flags, observation format
and reproduction.
