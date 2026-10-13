# SwiftOSPrimitives

Native Swift operating-system primitives, starting with **PageMemory**.

PageMemory owns anonymous private mappings without a class, ARC ownership or COW
storage. It lends synchronous `Span`/`MutableSpan` views, retires contents before
reclamation and explicitly releases mappings. The package has no third-party
dependencies and contains no C, Rust, shell or Python implementations.

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
- Advice failures conservatively retire contents. Access remains denied until a
  successful reset; advice and explicit release can be retried.
- Advice reports bytes submitted, not a fictional physical-memory delta.
- Residency is observed with bounded scratch memory; it is not RSS/PSS/physical footprint.
- Explicit release reports errors and is idempotent; destruction attempts release
  but cannot report a failed syscall. Use explicit release where error handling matters.

Mapped bytes may be reclaimed without reducing code/runtime RSS. This component
does not replace the Swift runtime, provide a global malloc implementation,
guarantee recovery from OOM killing or implement VM ballooning.

## Validation

```text
swift test -c release
swift run -c release page-memory-probe soak 300
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

## Scope

Version 0.1 is an initial standalone primitive. Production adoption requires the
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
