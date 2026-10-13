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
actual disposable-guest init/exit execution. GFP-backed fallible placement and stronger pinning remain separate work; scoped
partial-init cleanup is now provided by the typed API below. Physical page
accounting and host/guest balloon protocols remain separate from process reclaim.


## Typed reservations

`withTypedAllocation(of:capacity:_:)` reserves `capacity * MemoryLayout<Element>.stride`
bytes with actual-address alignment. The count must be positive; multiplication
must fit `Int`. Invalid count/extent returns `.invalidSize`; an aligned extent
that does not fit returns `.capacityExceeded`. Refusal skips the callback and
leaves bytes unchanged. `Element` and the result can be noncopyable, but must be
escapable. A borrowed Span/Ref is not an independently owned result.

The callback receives a standard-library `OutputSpan<Element>` initially containing
zero elements and a disjoint byte remainder. `append` consumes an element;
`removeLast` transfers an independent element out. Overfilling or removing from
an empty output span is a programmer error checked by the standard library,
not an allocation refusal. Its safe API tracks the initialized prefix, including
partial initialization before a thrown error.

```swift
switch arena.withTypedAllocation(of: UInt64.self, capacity: 4, { output, remainder in
  output.append(17)
  output.append(29)
  return output.span[0] + output.span[1]
}) {
case .allocated(let sum): print(sum)
case .refused(let reason): print(reason)
}
```

The library deinitializes the borrowed UInt8 extent and explicitly binds the
uninitialized memory to Element. A private function owns/destroys the output
span **before** the caller explicitly binds and initializes UInt8 again.
Temporary `withMemoryRebound` is intentionally not used across unrelated types: its
layout-compatibility requirement still applies to previously bound storage. Its standard
`OutputSpan` destructor destroys every remaining live element. An outer `defer`
reinitializes the entire reserved extent as zero UInt8 values, even when the
callback throws or replaces the output span with an empty one. Alignment padding
and unreserved bytes are untouched. Byte-only `withAllocation` keeps its original
preserve-content behavior; the typed API deliberately has a different contract.

The library owns no backing allocation or heap object-tracking table. Ordinary Swift
generic metadata/runtime initialization is not excluded for arbitrary element/result
types; only the pinned Embedded fixtures have a compiler-checked no-allocation
contract. This does not remove normal Swift runtime RSS.

Empty element types use their standard stride (at least one byte); they still
reserve bounded capacity. Destruction order within one prefix is unspecified.

Use checked builds (`-Onone` or `-O`), as the gates do. `-Ounchecked` removes
standard-library preconditions and is outside this safety contract, just as for
Array and Span. This package does not weaken or disable exclusivity/safety checks.

Cleanup is O(live elements + reserved bytes). This is not secure erasure, a promise
of immediate physical-page release or fallible construction of arbitrary Swift
classes/collections. Constructors/destructors can allocate, block or invoke syscalls.
A trap/process termination does not run normal cleanup. Unsafe output-span
`finalize`/pointer APIs can violate initialization tracking; callers must respect
their unsafe contracts. Do not suspend, retain raw pointers or return loans from
this synchronous callback. Remaining elements are destroyed before PageRegion can
retire/reclaim/release its pages; actual page release belongs to the owner.

These are movable Swift values appended to their final scratch storage, **not**
self-referential in-place initialization, a Rust-style Pin, physical pin or
registration-safe address stability. Kernel GFP contexts, IRQ/DMA ownership and
OOM policy still need separate reviewed adapters.

### Typed validation and kernel dependencies

Native release and AddressSanitizer tests exercise partial construction lengths
0...4, exact destruction identities, success/error reuse, replacement, independent
noncopyable transfer and ARC-owned page-backed resources before reclaim. An
independent actual-address grid verifies typed alignment, zero restoration and
untouched bytes. Six new emit-SIL consumers reject initialized-span return,
outer-lifetime storage, parent reentry, captured-owner moves, nested-owner moves and
output/remainder aliasing; the positive consumer exercises scalar
return. iOS18 module compatibility and Linux CI remain gates.

`EmbeddedTypedProbe` combines the sources into one Embedded module and runs 1,000
cycles (5 partial-error requests plus success/nesting per cycle), with a checked
37,000 destructor checksum, zero restoration after each throw, and actual-address
alignment padding. Only the standalone combined-module Embedded mode is checked;
normal package consumers exercise the imported-module API. It compiles with `-no-allocations`,
strict memory safety and warnings as errors. The fixture uses a stack-owned
counter pointer with a bounded native loan; it adds no general raw-pointer API.

The optional LLVM experiment now audits separate `typed_arena_trace` objects for
ARM64/x86-64. Unlike the earlier byte trace, dynamic typed zero restoration and
stack-counter lifetime may require `memset`, `__stack_chk_guard` and
`__stack_chk_fail`. **Stack protection is retained.** The gate enumerates actual
imports and refuses every dependency outside that explicitly declared set; it
still verifies whole-object no-FP/SIMD operands and retains the unrelated-symbol
negative control. An import-free byte trace does not establish an import-free
whole library. A kernel adapter must provide correct architecture-specific guard,
failure and zeroing contracts and validate final relocation/stack/hardening paths;
these objects have not been linked into Kbuild or booted in a guest.

Upstream semantics were checked against the pinned
[Swift6.4.1 OutputSpan source](https://github.com/swiftlang/swift/blob/swift-6.4.1-RELEASE/stdlib/public/core/Span/OutputSpan.swift)
and installed interfaces, then exercised natively. Explicit binding follows the
[raw-pointer memory-state contract](https://github.com/swiftlang/swift/blob/swift-6.4.1-RELEASE/stdlib/public/core/UnsafeRawPointer.swift);
ASan alone cannot validate type-binding/TBAA rules. No custom object runtime,
allocator interposer or borrowed upstream allocator implementation was added.
