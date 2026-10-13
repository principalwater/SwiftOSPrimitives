# Ecosystem, positioning and instruction boundaries

Research checked on 2026-10-14. This is a library for **ownership and bounded memory
in Swift systems software**, with optional freestanding compiler experiments.
`SwiftOSPrimitives` remains the repository identity. `BoundedMemory` replaces the
unpublished draft name `KernelMemory`: the component reserves borrowed initialized
bytes; it does not allocate Linux physical pages. Existing `PageMemory` APIs remain.
A compatibility layer over native OS APIs is appropriate; a competing OS or a
Foundation clone is not required to solve Macray's resource lifecycle problems.

## What to reuse

| Project | Actual scope inspected | Useful direction | Boundary |
|---|---|---|---|
| [swift-corelibs-foundation](https://github.com/swiftlang/swift-corelibs-foundation/tree/4b9721131c9845ab393f9fa63289c7a106e4594d) | Non-Darwin Foundation compatibility, shared swift-foundation implementation | Granular products, shared semantic contracts, platform adapters, cross-platform tests | Not a freestanding runtime; Apple clients use OS Foundation |
| [swift-linux](https://github.com/swift-compositions/swift-linux/tree/edefc85621119b6be468630665b4dd3120a1c95f) | Subsystem products/reexports, real io_uring support probe, lifetime-borrowed descriptor targets | Small imports; typed failure and descriptor lifetime conventions | User-space syscalls; multiple unpinned main dependencies; README and manifest differ |
| [swift-linux-standard](https://github.com/swift-linux-foundation/swift-linux-standard/tree/3a04e4791ba4663e512fdc4fd3867a9eda3fba37) | Typed syscall families, reexports and allocation statistics shim | Review individual Linux binding products before duplicating them | Community project, not Apple Foundation; declarations/system ABI are distinct from owned C implementation |
| [swift-os](https://github.com/asaptf/swift-os/tree/bdb9debadc94599999744b7c8cd0aa74beb5c20e) | ARM64 custom OS, PMM bitmap/refcount core, MMIO/heap/context interfaces | Disposable guest/PAL fixture ideas; caller-provided allocator tables and lifecycle tests | Own ABI; C and assembly bridges remain; not a Linux/macOS module |
| [Carette's kernel experiment](https://carette.xyz/posts/minimal_swift_kernel_on_qemu/) | Partial primary article and complete repository README retrieved | Explicit toolset, linker script, noalloc and orphan-section gates; stable C export direction | Recreational kernel; snapshot recommendation is not necessary for our tested release toolchain; full source/boot unverified |

Foundation's contemporary implementation split matters: corelibs supplies compatibility
APIs and reexports FoundationEssentials/Internationalization from
[swift-foundation](https://github.com/swiftlang/swift-foundation). Learn the module
boundaries rather than importing the full framework into the nonallocating core.
The existing PageMemory native platform boundary and the independent BoundedMemory
product already follow this separation. No upstream implementation was copied.

The Linux allocation-statistics shim replaces malloc/free using dlsym/pthread_once
and per-thread counters. Its `bytesAllocated` is cumulative allocation, not current
live bytes, RSS or physical memory. It does not cover every allocator or mmap.
Recursive initialization, symbol resolution, static musl and cross-thread semantics
need independent tests before adoption. We did not install or preload it.

SwiftOS's page allocator operates directly on caller-supplied physical-frame metadata.
That is useful algorithm research, but a user-space Swift process on Linux/macOS
cannot claim physical page ownership by copying the code. Its older `io.h` comment
about no Swift volatile support also needs context: our 6.4.1 `_Volatile` experiment
works. Volatile still does not implement cache maintenance, TLB operations, DMA
ownership or architecture/device barriers.

The [Gentoo page](https://wiki.gentoo.org/wiki/User:SwifT/Complete_Handbook/Building_the_Linux_kernel)
is an ordinary Linux kernel build handbook; `SwifT` is its author's username.
It is not evidence of the Swift language in Linux. The
[HN submission](https://news.ycombinator.com/item?id=49977351) links to Carette's
same article; it is discussion, not an independent kernel implementation.

## Direct instructions from Swift

The [swift-asm-macro](https://github.com/p-x9/swift-asm-macro/tree/f8182f4f9bb507e89157c755f8f9b51c9a5068ae)
implementation assembles at build time, stores instruction words in Mach-O text
with section-placement attributes, and calls them using the C calling convention.
Its inspected implementation supports ARM64 Apple images, not x86-64 or ELF.
It is a callable machine-code block, not compiler-integrated constrained inline
assembly with register clobbers and optimizer memory effects.

We independently compiled the small mechanism in Swift6.4.1 Embedded/noalloc:
a fixed ADD/RET instruction pair in a normal Mach-O text section, four unsigned
arithmetic edge cases, and disassembly verification. No C implementation, JIT,
executable-memory allocation, privileged instruction, system modification or macro
dependency was needed. This does not validate the upstream macro package,
arm64e/PAC, Linux support, device instructions or App Store acceptance.

Ordinary Swift wrapping addition already lowers to the same arithmetic instruction.
An extra indirect/call boundary does not improve it. Prefer supported native
atomics/intrinsics or `_Volatile` where their contracts match the operation. A real
missing instruction can justify a narrowly typed optional backend. Before any
such backend is public, record:

- ISA/ABI, privilege level, register/flags/memory effects and calling convention;
- stack alignment, callee-save preservation, unwind/CFI/PAC requirements;
- whether an effect is a compiler fence, CPU fence or device barrier;
- architecture-specific codegen checks and disposable-guest execution for privileged work.

An arbitrary public assembly-string API is not necessary for this library. A true
inline-assembly capability with constraints/effects belongs in Swift compiler
work when a normal library cannot express the contract. A syntax macro alone
cannot grant missing optimizer semantics or hardware privileges.

## Next memory and kernel milestones

1. Keep fallible bounded byte loans and actual anonymous-page reclaim independently
   reusable, with pinned compiler-negative and native-platform proof.
2. Add typed fallible placement only with tracked partial initialization/destruction;
   distinguish address-stable storage from safe registration/Pin semantics.
3. Reuse the official EmbeddedPlatform PAL for backing/context adapters. GFP-style
   sleep/reclaim policy and interrupt-context effects must be explicit, not inferred.
4. Use a disposable pinned-kernel/VM fixture for final-link, module ABI, stack,
   hardening, init/exit and cleanup tests before calling anything kernel-ready.
5. Implement ballooning as a separate host/guest protocol over the appropriate
   hypervisor/guest device. Measure guest pages reported, backing released and
   application pressure together; freeing host process pages is not ballooning.

This source branch extends validated v0.2.1 and preserves the parallel Windows
main. Combining the two needs a separate Mac/Linux/Windows acceptance run.
