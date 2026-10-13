# BoundedMemory: borrowed scratch storage

`BoundedMemory` is an experimental, standard-library-only product for Swift 6.4.1.
It supplies fallible scoped byte reservations over initialized, exclusively
borrowed storage. It is useful in ordinary Swift and explicit Embedded consumers.
It is not a Linux allocator, typed-object Pin, physical-memory manager, VM balloon,
IRQ/DMA-safe abstraction or kernel-ready runtime.

## Contract

`ScratchArena` is noncopyable and nonescapable. Its initializer consumes a
`MutableSpan<UInt8>` loan, retaining its owner lifetime. Each `withAllocation`
returns an independent `AllocationOutcome` or propagates the original typed
callback error. The outcome is copyable only when its payload is copyable.

- Positive byte count; positive power-of-two alignment.
- Padding is calculated from the actual base address. Capacity includes padding.
  `byteCount + alignment - 1`, when representable, suffices for any base address.
- The callback runs once on success, never on refusal. It receives the reserved
  mutable span and a disjoint child arena over the remaining bytes.
- The parent is inaccessible during the callback; nested reservations use the child.
- No persistent cursor exists. Return or throw releases every scoped reservation.
  No native allocation, syscall, locking, sleep or reclaim occurs in this component.
- Bytes remain initialized and retain previous values, including writes before a
  callback error. There is no implicit zeroing, secure erasure or typed destruction.
- The result payload is escapable: it cannot contain borrowed spans or arenas.
  Raw access through the standard library's `withUnsafe…` APIs remains subject to
  its unsafe pointer contract; extracted pointers cannot be dereferenced after the loan.
- The backing owner performs actual release/reclaim. A stack/array owner, PageRegion
  and a future reviewed kernel backing adapter have different release semantics.

The arithmetic guards prove `padding + byteCount <= capacity <= Int.max` before
constructing either span. Wrapping operations after that proof remove redundant
overflow traps; input validation remains intact. Generic callback work, nesting
stack depth and callback allocations/blocking are the caller's responsibility.
A library does not grant an execution-context or privilege exemption.

## Use

The target and consumers defining lifetime-dependent APIs must enable the
experimental `Lifetimes` feature. Keep the compiler pinned and run the full
compiler-negative suite before changing it. The iOS deployment floor remains 18;
InlineArray fixtures are host examples requiring newer Apple availability.

```swift
import BoundedMemory

var buffer = [UInt8](repeating: 0, count: 4096)
var arena = ScratchArena(storage: buffer.mutableSpan)
switch arena.withAllocation(byteCount: 32, alignment: 16, { bytes, remainder in
  bytes[0] = 73
  return Int(bytes[0]) + remainder.capacity
}) {
case .allocated(let value): print(value)
case .refused(let reason): print(reason)
}
```

The array/print in this host example allocate; the arena itself does not. For an
existing PageRegion callback, reborrow its inout span with
`bytes._mutatingExtracting(0..<bytes.count)` and consume that loan. The underscore
API is another pinned toolchain dependency. See the release test for this adapter.

## Validation

The native tests cover refusals without callback/storage effects, an independent
first-fit alignment grid, exact-fit recovery after typed errors, noncopyable
payloads, nested disjoint loans and actual PageRegion reclamation.
Compiler negatives reject copied owners, escaped byte/arena loans, reentry and
returning the remainder. `swap` is currently rejected because its type requires
Escapable; this is recorded separately from a lifetime-escape diagnostic.

`Examples/EmbeddedArenaProbe` executes 1000 nested cycles and an error/reuse path
under `-no-allocations`. Its allocating negative control must fail compilation.
The exercise is one combined module; cross-module Embedded specialization is not
promised. Existing PageMemory remains separate and does not pass whole-module
`-no-allocations`.

With `KERNEL_LLVM_BIN` explicitly set, `Tools/CheckLowLevel.swift` additionally:

1. Emits optimized Swift 6.4.1 IR for ARM64 and x86-64.
2. Uses LLVM internalization/global DCE, preserving the C entry and retained roots.
3. Applies explicit per-function no-red-zone and no-FP/SIMD attributes. LLVM function
   attributes override command-line feature defaults, so the transformation is retained.
4. Lowers the whole reachable object, with x86 kernel code model, and checks every
   undefined symbol and disassembled operand for FP/vector register use.
5. Compiles an undefined-dependency control that passes `-no-allocations` but has an
   unresolved symbol. This demonstrates why both checks are needed.

The local experiment uses LLVM 22.1.0 after Swift 6.4.1 IR generation. Its version,
IR, object, imports and assembly are retained. It is not solely the Swift backend,
not a final Kbuild-linked kernel image, and not proof of red-zone/stack/hardening
conformance for arbitrary future code. The small retained exception-personality
stub traps; autolink metadata can remain. Existing input/Span checks are preserved.

Kernel integration still needs a pinned kernel configuration, Kbuild/Kconfig,
module/versioned-symbol ABI, final link/section/TLS/relocation/stack analysis,
objtool/ORC and applicable CFI/retpoline/IBT protections, a panic contract and
actual disposable-guest init/exit execution. GFP-backed fallible typed placement,
partial-init cleanup and stronger pinning are separate work. Physical page
accounting and host/guest balloon protocols remain separate from process reclaim.
