# Rust-for-Linux and native Swift boundaries

This research is pinned to Linux v7.2 source and the official Swift 6.4.1
toolchain. It describes tested primitives and missing integration work, not a
proposal to load a Swift module into a production kernel.

## What Rust in Linux actually does

Rust kernel code uses `no_std`; it cannot use a normal process runtime. The kernel
generates C API bindings and builds reviewed Rust abstractions over them.
Drivers use those abstractions rather than the bindings directly. There are
small C helpers for inline functions and macros bindgen cannot expose. Therefore
"native Rust in the kernel" does not mean replacing every C component.
See the kernel's [general information](https://www.kernel.org/doc/html/latest/rust/general-information.html).

For a concrete network example,
[ax88796b_rust.rs](https://github.com/torvalds/linux/blob/v7.2/drivers/net/phy/ax88796b_rust.rs)
implements PHY driver callbacks, reads/writes typed PHY registers, and delegates
link negotiation and power management to the existing PHY subsystem. It is not
a user-space proxy that issues a syscall for each packet.

Kernel code calls kernel APIs directly. User-space Rust normally calls libc or
an OS-specific syscall implementation, crossing the same protection boundary as
Swift. A language does not grant additional hardware privileges. Avoiding that
transition requires an appropriate kernel/subsystem design, not a different
syntax. Batch work, reuse buffers/mappings, avoid redundant syscalls, and bound
queues before considering a lower-level transport.

## Hardware and memory contracts

The v7.2 [I/O abstraction](https://github.com/torvalds/linux/blob/v7.2/rust/kernel/io.rs)
checks access width, offset and mapping extent and routes ordinary accesses to
Linux readb/readw/readl and write counterparts. Relaxed accessors use the kernel's
relaxed operations. These carry architecture-specific behavior; plain volatile
operations are insufficient to replace all of it.

The [DMA abstraction](https://github.com/torvalds/linux/blob/v7.2/rust/kernel/dma.rs)
is device-bound. CPU virtual, physical and device bus addresses differ, and
IOMMU/cache maintenance and transfer lifetime matter. The
[DMA guide](https://www.kernel.org/doc/html/latest/core-api/dma-api-howto.html)
explains why a pointer cannot simply be handed to a device. PageMemory's anonymous
user mappings are not DMA mappings. CPU-borrowed Span views must not cover memory
that a device is concurrently mutating.

The [allocator](https://github.com/torvalds/linux/blob/v7.2/rust/kernel/alloc.rs)
is fallible and takes GFP flags. GFP_KERNEL may reclaim/sleep; GFP_NOWAIT avoids
direct reclaim but may fail. Atomic and NMI contexts have additional restrictions.
Native Swift Array/class allocation cannot be silently used in those contexts.

Kernel [mutex initialization](https://github.com/torvalds/linux/blob/v7.2/rust/kernel/sync/lock/mutex.rs)
uses pinned, in-place construction. `Pin` and pin-init protect addresses that
kernel objects retain. Swift `~Copyable` prevents copying but allows movement:
it is not an immovable type. A PageRegion's mapping remains at one virtual
address when its small owner moves; that does not pin a stored Swift value,
lock physical pages, provide DMA identity, or prohibit kernel page migration.

## What Swift already supports

Embedded mode and ownership types allow useful low-level Swift code today.
Swift 6.4 added generalized existential/error support; assessments based only
on older Embedded limitations are incomplete. The
[6.4 Embedded announcement](https://www.swift.org/blog/embedded-swift-improvements-coming-in-swift-6.4/)
also describes its platform abstraction layer. The supported package mode remains
separate from the explicitly experimental Embedded consumers in this repository.

The actual official 6.4.1 distribution includes `_Volatile`, whose
[source](https://github.com/swiftlang/swift/blob/swift-6.4.1-RELEASE/stdlib/public/Volatile/Volatile.swift)
implements integer access using transparent compiler builtins. Our optional
RegisterTrace example uses it directly, without C or assembly. The optimized
ARM64 and x86-64 leaf retains two volatile loads and two stores, with no calls.
Volatile preserves those accesses, but allows reordering relative to ordinary
memory. The module explicitly forbids using it for thread synchronization.
It is an underscored compiler dependency, not a stable device-driver API.

PageMemory now avoids importer-incompatible errno/MAP_FAILED macros using their
native Darwin/Glibc/Musl ABI equivalents. Native Mach field addresses replace
key-path offset queries unsupported by the exercised Embedded specialization.
Residency inspection uses bounded temporary scratch storage instead of an Array
owner and keeps the existing iOS 18 deployment target. The standard temporary
allocator may choose stack or a fallback allocation: no universal stack-only
promise is made.

The current complete PageMemory consumer passes ordinary Embedded mode. It
does not pass whole-module `-no-allocations`; error/string-related support still
needs allocation. The isolated register leaf passes that flag. This separates
an actual nonallocating primitive from a generic promise about the entire library.

## Gaps and the right place to fix them

| Requirement | Library work | Compiler/kernel integration work |
|---|---|---|
| Unique resources and bounded bytes | Noncopyable owners, Span loans, typed failure, explicit release | Stabilize lifetime-related APIs; validate upgrades |
| Stable object address | Owned out-of-line storage, scoped access, partial-init cleanup | A stronger pinning/placement model if a safe API needs one |
| Register operations | Typed offsets/widths, mapping-owner loans, device backends | Stable volatile primitives and architecture/device barriers |
| Fallible allocation | Explicit fallible arenas/containers with limits | A context-aware allocator/PAL contract for implicit allocations |
| IRQ/atomic-context safety | Keep nonallocating, nonblocking leaf code separate | Context/effect checking, IRQ-safe runtime and locking integration |
| Kernel binary correctness | Retained codegen/dependency tests | Kbuild/Kconfig, module metadata, symbols, modversions, sanitizers, hardening |
| Physical/DMA pages | Device-specific lifetime state machine | Actual DMA/page APIs, IOMMU and coherency integration |
| Returning process memory | Reclaim only retired owned anonymous pages | No kernel change required for mmap/madvise/munmap |
| VM ballooning | Host/guest protocol and byte/page accounting | Guest balloon device/driver and hypervisor backing release |

In particular, Linux's
[x86 build](https://github.com/torvalds/linux/blob/v7.2/arch/x86/Makefile)
sets no-red-zone, kernel code model, restricted vector features and security
options for Rust. A Swift freestanding triple alone does not supply the complete
kernel profile. Even unused compiler-generated Embedded support code can need
runtime symbols or contain vector instructions. Inspect the whole final linked
image before asserting kernel suitability; our leaf test is narrower.

## Direction for users of this library

Keep ordinary Swift for server/UI orchestration and use small measured native
primitives for memory and OS resource lifecycles. Current evidence does not
require replacing that control plane with Rust. Neither kernel acceptance nor
a rewrite speedup in another project establishes a universal language ranking.

The next defensible kernel experiment is a disposable VM with a pinned kernel
configuration: build-profile/undefined-symbol checks, then a minimal module
init/exit through reviewed kernel bindings. Only after that should mapping
ownership, interrupt teardown, barriers and device-specific DMA be implemented.
Never infer permission to run it on a production host from these examples.

For memory ballooning, preserve the boundary between freeing a process mapping,
lowering Darwin's footprint ledger and returning guest physical backing to the
host. They are distinct mechanisms with distinct tests. PageMemory can supply
host-side buffer ownership, not the missing guest balloon protocol by itself.
