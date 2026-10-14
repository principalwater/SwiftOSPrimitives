# SwiftOSPrimitives

Ownership and bounded-memory primitives for Swift systems software, with optional
freestanding validation. Complements typed OS bindings; this is not an OS, kernel
allocator, runtime or Foundation replacement.

PageMemory owns anonymous private mappings without a class, ARC ownership or COW
storage. It lends synchronous `Span`/`MutableSpan` views, retires contents before
reclamation and explicitly releases mappings. The package has no third-party
dependencies; its package products are implemented entirely in Swift. An optional,
standalone Rust benchmark reference is kept outside the products for comparisons.

## Requirements

Swift 6.4 or later; development and validation use Swift 6.4.1.
macOS 27 release tests pass; the static Linux build and runtime probe pass.
Native Linux package tests are a separate CI gate. The declared iOS 18 target compiles with the iOS 27
SDK using back-deployable Span APIs; device behavior is not claimed.

## Use

```swift
import PageMemory

var region = try PageRegion.allocate(
  byteCount: 64 * 1024,
  maximumMappedBytes: 1024 * 1024
)
try region.withMutableBytes { bytes in
  bytes[0] = 42
}
let first = try region.withBytes { bytes in bytes[0] }
let reclamation = try region.discardContents()
try region.resetToZero()
try region.release()
```

For payload code that throws, use `withReadAccess` or `withWriteAccess`:

```swift
let value = try region.withReadAccess { bytes in
  try decodePayload(bytes)
}
```

The original callback methods retain typed `PageMemoryError` failures and now
also return independent noncopyable values. The throwing methods propagate
original payload errors; writes made before a payload failure remain present.
Nested payload code may itself throw `PageMemoryError`, so that type alone does
not identify which region failed. These are source APIs: rebuild consumers when
upgrading rather than mixing precompiled v0.1 binaries with newer modules.

Callbacks are synchronous and nonescaping. Their result is an ordinary escapable
value; safe spans cannot outlive the callback. Return `Result` to represent a
callback failure. The owner is noncopyable and deliberately not `Sendable`.
Allocate/use/release within one isolation domain rather than bypassing concurrency checks.

The allocation limit applies per region, includes page rounding and does not
constitute a process-wide memory budget. No arbitrary foreign allocations,
allocator heaps, executable pages, files or other processes are reclaimed.

## Reclamation semantics

- Linux: `MADV_DONTNEED` on exclusively owned anonymous private pages. Subsequent
  initialization can use the kernel's zero-on-demand behavior.
- Darwin: `MADV_FREE` is lazy advice. Reset explicitly zeros logical bytes because
  old contents may still exist; reset touches pages and can make them resident again.
- Darwin opt-in: `discardContents(using: .reusable)` uses `MADV_FREE_REUSABLE`,
  then reset balances it with `MADV_FREE_REUSE` before zeroing. The report keeps
  `.lazyFree` semantics and separately reports `usesReusableAccounting`. This can
  lower the footprint ledger while pages remain resident. Advice failure keeps
  access retired, and reset refusal remains retryable.
- Advice failures conservatively retire contents. Access remains denied until a
  successful reset; advice and explicit release can be retried.
- Advice reports bytes submitted, not a fictional physical-memory delta.
- Residency is observed with bounded scratch memory; it is not RSS/PSS/physical footprint.
- Explicit release reports errors and is idempotent; destruction attempts release
  but cannot report a failed syscall. Use explicit release where error handling matters.

Use one bounded region for repeated work. Call `resetToZero()` between payloads
when zero initialization is needed, and discard pages when the region becomes
idle. Linux reset after a successful discard avoids repeating `MADV_DONTNEED`.
Linux's reusable strategy uses the same discard/zero-on-demand behavior and does
not report Darwin ledger accounting. A default discard on a region already
retired as reusable is a no-op; reset completes the balancing step.

`ProcessMemorySnapshot.capture()` observes the calling process using native
Mach task counters or bounded Linux `statm` reads. RSS and Darwin physical
footprint remain separate; Linux footprint is unknown. `statm` RSS is the
kernel's approximate counter. Snapshots are observations, not lifecycle or
memory-budget authority.

Mapped bytes may be reclaimed without reducing code/runtime RSS. This component
does not replace the Swift runtime, provide a global malloc implementation,
guarantee recovery from OOM killing or implement VM ballooning.

## Validation

```text
swift test -c release
swift run -c release page-memory-probe soak 300
swift run -c release page-memory-probe footprint reusable
swift run -c release page-memory-probe cycle reuse 1000 65536
swift Tools/CheckCompileFailures.swift /path/to/swiftc /path/to/built/modules Tests/CompileFail /path/to/scratch
```

Unit tests cover bounds/rounding, independent owners, borrowed access,
discard/reset, residency and release. `Tests/CompileFail` contains negative
consumers for double consumption, escaping/nested/mutable borrows, task capture
and release during a borrow, plus a positive control.
Those cases are expected to be rejected by the compiler, not built as package tests.
On macOS, set `SDKROOT` to the installed macOS SDK for the compiler helper.

The probe only uses its own mappings and bounded reads of Linux self-status/self-smaps.
`baseline` emits process-image counters; `smaps` emits mapping details;
`soak N` exercises at most one 1 MiB mapping at a time. `paced-soak N` adds 20 ms
between cycles for an isolated diagnostic run. Measurements are diagnostic,
not a language-performance ranking.

[NIOResourceLab](Examples/NIOResourceLab) is an optional, separately built example
for repeated loopback connections, timeout cleanup and descriptor accounting.
It pins its own NIO dependencies and does not add them to PageMemory.

## Embedded and low-level experiments

[EmbeddedPageProbe](Examples/EmbeddedPageProbe) validates the same PageMemory sources
in explicitly selected Embedded mode. [RegisterTrace](Examples/RegisterTrace) uses
Swift 6.4.1 compiler-native volatile operations and checks their optimized code
for ARM64 and x86-64 without touching hardware. These remain optional; the main
package does not force Embedded mode or import `_Volatile`.

[FreestandingGuest](Documentation/FreestandingGuest.md) adds a Swift-native RAM
fill PAL and a complete ARM64 ELF/QEMU execution gate, including actual compiler
stack-guard failure and memory-boundary negative controls. A small assembly boot
boundary remains necessary; this experiment adds no package runtime dependency.
[FillBenchmark](Examples/FillBenchmark) compares two standalone Swift volatile
fill variants on macOS and makes no language-performance ranking.
[FrameLedger](Documentation/FrameLedger.md) adds retained, generation-bound frame
reservations over borrowed fixed metadata, with explicit out-of-order release.
Its Embedded trace and Mac benchmark validate allocation-free machine code;
frame identifiers alone grant no physical-memory access.
[FrameComparison](Examples/FrameComparison) compares the scanning baseline and
cached counter with equivalent Rust reference algorithms. Its Swift fixture also
runs on Linux; measurements remain separate from production acceptance.

[Kernel Rust and Swift](Documentation/KernelRustAndSwift.md) explains the kernel
contracts, current Swift capabilities and remaining compiler/subsystem work.

## Scope

This is an evolving standalone primitive. Production adoption requires the
consumer's lifecycle, capacity and recovery acceptance. Future pool, event-loop,
allocator/PAL and VM-balloon integrations should be justified by measured needs.

The target enables strict memory-safety diagnostics. Its small unsafe boundary
binds Span lifetimes explicitly to the owner using the toolchain's underscored
`_overrideLifetime` helper and `_unsafeStart` initializers. Compiler upgrade checks
must validate these dependencies. Safe use requires Swift's exclusivity and
bounds checks; do not disable them or use `-Ounchecked`. Nonlocal
aliasing may be checked dynamically rather than diagnosed at compile time.
Syscall failure injection and destructive VMA-hole tests are not included.

Formatting follows a 100-column, two-space Swift profile informed by
[Google's Swift Style Guide](https://google.github.io/swift/) and
[Apple's API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).

## License

MIT. Operating-system APIs and the Swift toolchain retain their own licenses.

## BoundedMemory research product

Experimental `BoundedMemory` adds nonallocating borrowed byte/typed scratch reservations and
whole-object Embedded compiler checks. It is separate from PageMemory and requires
pinned Swift6.4.1 lifetime features. The typed API uses standard OutputSpan destruction
and restores reserved bytes after success or partial failure; constructors/destructors
remain caller work. See [the contract](Documentation/BoundedMemory.md).
This research branch does not yet combine the independently developed Windows main.
