# Frame comparison

Standalone, single-context synthetic benchmark. It touches its own fixed metadata
only: no networking, VPS configuration, devices, privileged memory or kernel state.
Package products remain Swift-only; reference.rs is an optional comparator.
See [the report](../../Documentation/FrameComparison.md) for interpretation.

## Build and inspect

Use pinned Swift 6.4.1 and a fresh scratch directory outside the checkout.
On macOS set SDKROOT to the installed macOS SDK; Linux uses its native toolchain.
The fixture requires macOS 27 or 64-bit Linux, not the package's iOS 18 floor.
No allocations, overflow, bounds or exclusivity checks are disabled.

```text
swiftc -swift-version 6 -O -wmo -parse-as-library -warnings-as-errors \
  -enable-experimental-feature Embedded -enable-experimental-feature Lifetimes \
  -enable-experimental-feature Volatile -no-allocations -strict-memory-safety \
  Sources/BoundedMemory/FrameLedger.swift Examples/FrameComparison/main.swift \
  -o /path/to/scratch/frame-embedded
/path/to/scratch/frame-embedded > /path/to/scratch/frame-embedded.txt
swift Tools/InspectFrameComparison.swift /path/to/scratch/frame-embedded.txt
```

For hosted Swift, omit Embedded and no-allocations; retain every other safety flag.
For the scanning baseline, extract FrameLedger.swift from commit
9cb8cf27e12096ac9d3548af02f3c0abcf774a87 and use that file with this same harness.
Do not compare only the optimized Swift algorithm with scanning Rust.

The optional Rust reference uses core/no_std, no dependencies, aborting panics and
checked overflow. Development used Rust 1.96.0:

```text
RUSTC_BOOTSTRAP=1 rustc --edition 2021 -C opt-level=3 -C panic=abort \
  -C overflow-checks=yes -Z stack-protector=strong -D warnings \
  Examples/FrameComparison/reference.rs -o /path/to/scratch/frame-rust-baseline
RUSTC_BOOTSTRAP=1 rustc --edition 2021 -C opt-level=3 -C panic=abort \
  -C overflow-checks=yes -Z stack-protector=strong -D warnings --cfg cached \
  Examples/FrameComparison/reference.rs -o /path/to/scratch/frame-rust-cached
```

RUSTC_BOOTSTRAP is scoped to each command to request the experimental protection
flag; it is not a global setup change. Verify actual guard imports for the target.
On macOS pin MACOSX_DEPLOYMENT_TARGET=27.0. Local M2 measurements also pinned
Swift -target-cpu apple-m2 and Rust -C target-cpu=apple-m2. Use an appropriate
common CPU on other hosts; neither flag is a universal target.
The prepared Rust Linux ABI assumes x86-64/AArch64 two-i64 timespec and libc.
Its Linux execution is not yet a claimed acceptance gate.

## Observation format (version 2)

Output is 637 newline-delimited unsigned decimal integers:

1. Five header words: version 2, clock numerator, denominator, metadata bytes,
   and metadata address modulo 64. The address itself is never emitted.
2. 32 durations of consecutive clock reads, in raw ticks.
3. 15 rows, capacities 128/1024/4096/16384/65536, modes 0/1/2 in order.
   Each row has 40 words: capacity, mode, iterations, p50/p95/p99 nanoseconds per
   batch-average step, digest, final generation, then 32 unsorted batch durations.

The inspector validates geometry, independently derived digests/generations and
the arithmetic from raw observations; CI runs the hosted and Embedded Swift
fixtures on both Mac and Linux. It does not impose timing thresholds.

Mode 0 uses 256 steps per batch; each step reserves three tickets, releases three,
observes availability twice and checks first-fit reuse. Mode 1 uses 32 refusals
while a full reservation remains live. Mode 2 uses 16 refusals with sufficient
total free space but two separated quarter-capacity holes.

Each mode has two discarded warmup batches and 32 retained batches. Setup and
held-ticket release are outside timing; generation persists across batches.
The requests are owner-bound volatile UInt64 scalar reads. Swift uses _Volatile;
Rust uses read_volatile. This single-context experiment establishes neither
cross-language atomic semantics nor synchronization/IRQ safety.

Native clocks are mach_absolute_time on Darwin and CLOCK_MONOTONIC_RAW on Linux.
Clock pairs are diagnostic; no clock cost is subtracted. Sorting, output and full
metadata verification occur outside timing. Fixed stack metadata is 524,296 bytes
(512 KiB plus 8), plus stack frames: run on a sufficiently sized main-thread stack,
never transplant this fixture onto a small worker or kernel stack.

Run at low priority, bound external execution and retain native CPU/RSS counters.
Interleave baseline/cached/language variants and retain raw samples. Concurrent
host work, scheduler stalls and different compiler/runtime decisions still limit
language comparisons. No weak production VPS should be used for load testing.
