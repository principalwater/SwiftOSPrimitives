# Freestanding Swift memory PAL experiment

This optional executable links the existing BoundedMemory typed scratch API into
a complete ARM64 ELF image. Its RAM fill/copy and terminal failure handlers are
implemented in Swift 6.4.1. A small assembly boundary sets the initial stack,
installs exception vectors, enters Swift and invokes PSCI SYSTEM_OFF; separate
assembly test hooks change the guard cookie or execute a deliberate BRK.
The C header declares that boundary for the compiler's C importer and contains no
C implementation. Neither package product exports these guest-local ABI symbols.

This is a reproducible compiler/link/guest-execution experiment. It is not a Linux
module, kernel allocator, general runtime or secure boot environment.

## RAM fill and ownership

`guestMemoryFill` accepts an exclusive, valid writable RAM extent, truncates the
fill value to eight bits and returns the original pointer. A zero count permits
nil. Positive nil, counts exceeding Int.max and address wrap trap before writes;
validity of the entire mapping remains the unsafe caller's obligation.

Leading byte stores align the actual destination to eight bytes; aligned UInt64
stores fill the middle, and byte stores fill the tail. Compiler-native volatile
operations keep this implementation from being rewritten as a recursive call to
its own `memset` export. This is ordinary RAM filling: no DMA ownership, MMIO
width contract, atomic synchronization or secure-erasure guarantee is implied.

`memset` exists only under GUEST_BUILD. The ordinary host fill probe does not
interpose libc. Platform.swift is supplied only to the guest link, never a package
target. Do not include it in an application as a replacement for its runtime.

The optional Swift `memcpy` PAL implements non-overlapping RAM copy with checked
count/address arithmetic, zero-count/nil handling and a same-address no-op.
Matching source/destination alignment allows aligned UInt64 copying; other
alignments use byte copies. Volatile operations prevent recursive lowering into
the export itself. Both complete mappings remain an unsafe caller obligation;
this is not memmove, secure erasure, MMIO or synchronized DMA access. Native
acceptance observes all 128 destination/source bytes over 16,896 cases. Separate
checked host controls trap for positive nil, excessive count, wrap and overlap.

FrameLedger additionally manages sixteen linker-owned 4 KiB frames. Across 100
cycles, actual RAM receives poison, allocated-range fills, released-range reuse
and independently checked bytes. All tickets are released and full capacity is
reserved again. A complete initialized 4 KiB canary padding region on each side
is checked, including a deliberately corrupted nonadjacent final byte. These are
canaries, not MMU-enforced guard pages. Frame-number subtraction is bounded before
signed conversion or pointer construction. Package bookkeeping remains separate
from this unsafe physical mapping adapter.

The guest reserves 4096 linker-owned bytes and lends 4094 bytes between two
canaries. Across 100 repetitions it constructs prefixes of zero through four
noncopyable elements, throws the original payload error, observes destruction
through a volatile checksum and verifies restored zero bytes before reuse.
The expected destruction checksum is 2000. Existing OutputSpan ownership ends
before the library rebinds reserved storage to initialized UInt8 bytes.

## Pinned guest and compiler path

The tested path uses Swift 6.4.1, LLVM opt/llc/readelf/nm/objdump 22.1, and the
Swift toolchain's clang and LLD 21.0.0. Their versions and each command are retained
by the checker. LLVM IR is verified, internalized to an explicit guest entry set
and stripped of unreachable definitions. The function profile disables FP/SIMD,
requests strict ARM alignment and no red zone, and preserves stack-protection
attributes. This explicit IR transformation is research tooling, not an upstream
Swift kernel compilation profile. Different compiler releases require validation.

LLD rejects orphan sections and unresolved symbols. The checker audits the final
ELF's complete imports and instruction operands, ELF64 little-endian ARM64 identity,
file-backed aligned entry, bounded physical load ranges, physical/virtual address
equality, non-overlapping loads, segment flags, stack declaration and absence of
dynamic linkage, TLS and relocation sections. Mutated images exercise refusals
and are never executed. This is a bounded acceptance policy for this generated
image, not a general-purpose hostile ELF loader or a complete hardening audit.

QEMU 10.2.0 runs the versioned `virt-10.2` machine with cortex-a72, single-threaded
TCG, one CPU and 64 MiB RAM. NICs, graphical output, monitor, disks and shared
filesystems are absent. Semihosting is disabled; power-off uses PSCI HVC.
The machine's generated device tree was checked for RAM at 0x40000000,
PL011 at 0x09000000 and PSCI's HVC conduit. The image starts at 0x40080000.
Interrupts are masked; the MMU is off. EL1h uses an aligned vector table and a
separate 4 KiB terminal-diagnosis stack. There is no interrupt service, register
restoration, exception return or recovery; an unexpected exception emits TRAP
and powers off. ELF RX/R/RW and
non-executable-stack flags are declarations, not MMU-enforced W^X. Scratch is
explicitly initialized; this example is not a portable real-hardware boot sequence.

Every QEMU invocation has a ten-second deadline. Acceptance requires both a normal
zero power-off exit and the exact marker, rather than exit status alone:

| Image | Required output | Observable contract |
|---|---|---|
| Success | GUEST_PASS | Fill bytes, two canaries, original errors, destruction and reuse |
| Guard corruption | STACK_FAIL | An actually instrumented returning function detects a changed cookie |
| Memory corruption | MEMORY_FAIL | A volatile canary write is detected by the independent observation |
| Frame padding corruption | FRAME_FAIL | The final byte of the complete after-padding scan detects corruption |
| Deliberate BRK 0x641 | BRK_PASS | EL1h synchronous vector 4, EC 0x3c and the expected immediate match |
| Different BRK 0x642 | TRAP | A different syndrome is refused as the intended test exception |

The cookie is deterministic test data, not production entropy or Linux's per-task
or per-CPU guard ABI. A missing guard check returns GUARD_BYPASSED and fails the
runner. The corruption fixture is not a real exploit. Unexpected traps, hangs or
different markers refuse acceptance. Generic TRAP cannot pass the deliberate
BRK test; the second image exercises that distinction. Terminal fault diagnosis
is demonstrated, while production recovery is not. Evidence-size checks occur during execution and after exit;
the polling interval allows an overshoot rather than providing a byte-exact quota.

## Run

The ordinary low-level checker includes an Embedded/no-allocations host fill probe:
8192 combinations of offset, count and signed fill value check pointer identity,
every resulting byte and the surrounding sentinels. Set both optional variables
to also link and execute the guest; requesting QEMU without LLVM is refused.

```text
KERNEL_LLVM_BIN=/path/to/llvm-22.1/bin
GUEST_QEMU_BIN=/path/to/qemu-system-aarch64
```

Export those variables, select the Swift 6.4.1 compiler and, on macOS, export
SDKROOT for the installed macOS SDK. Then run:

```text
/path/to/swift-6.4.1/bin/swift Tools/CheckLowLevel.swift /path/to/swift-6.4.1/bin/swiftc . /path/to/owned-scratch
```

The checker creates a fresh UUID directory and retains IR, objects, ELF images,
disassembly, invocations, logs and mutated controls. Its host process supervision
is tooling; do not reuse this synchronous runner as a production daemon manager.
Default macOS/Linux CI validates the host fill and existing ownership checks;
the optional QEMU/LLVM guest path requires explicitly provisioned tools and is
currently a local gate.

## Remaining kernel work

No physical page allocator, fallible Swift runtime allocator, execution-context
allocation policy, Linux Kbuild/ORC/CFI integration, IRQ/DMA subsystem, arbitrary
object pinning or VM balloon protocol is provided. PageMemory's user-space mmap
and reclamation APIs remain separate. A guest-local RAM fill does not reduce
hosted Swift's baseline runtime RSS or reclaim memory belonging to another owner.

Primary platform references: [QEMU virt](https://www.qemu.org/docs/master/system/arm/virt.html)
and [Arm semihosting ABI](https://github.com/ARM-software/abi-aa/blob/main/semihosting/semihosting.rst).
The vector layout follows the primary
[Arm AArch64 exception model](https://documentation-service.arm.com/static/67ac57fb091bfc3e0a9479cc).
The tested BRK syndrome contract follows the
[Arm architecture reference](https://developer.arm.com/Architectures/CPU%20Architecture/A-Profile/docs/ddi0487/latest).
