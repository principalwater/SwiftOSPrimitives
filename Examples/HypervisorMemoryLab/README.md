# Owned HVF guest RAM reclamation (macOS27 research)

This optional synchronous Swift6.4.1 lab executes an Embedded Swift function on
one real EL1 vCPU using public Hypervisor.framework. It owns its guest RAM via
`hv_vm_allocate`, controls the stage-2 mapping, and explicitly retires its backing
with `hv_vm_deallocate`. No Linux, devices, network, disks or Apple Container are
involved. It is not a drop-in Containerization memory backend or a reusable VMM.
There is no older-macOS/iOS/Linux fallback; this package declares macOS27.

## Safety and actual test boundary

All vCPU operations occur synchronously on the creating pthread. `hv_vcpu_run`
has returned before any extent is unmapped or released; the lab has no second
vCPU, DMA device, worker or exported pointer. An unmap-only control proves the
64MiB owned object remains PRESENT even though RSS falls. A real guest access
then must produce a stage-2 translation fault at each of the 4096 native 16KiB
pages in the removed GPA extent (permission faults cannot pass this check). Only then is the host
allocation deallocated. The old host address must no longer overlap a VM region,
and the native physical-footprint ledger must fall by at least 64MiB. The next
allocation is checked for zeroes throughout all 64MiB by the guest before writing
and verifying a new per-word pattern. A separate 64KiB canary is written and checked
by the guest itself after each release; it stays resident.
The SDK27 V3 region query also requires a single anonymous, unshadowed, unwired
object with no compressed pages and exactly one reference before deallocation.
A live GPA mapping has two references in the observed kernel; unmap leaves one.
The `alias` control creates a real `mach_vm_remap(copy: false)` reference: release
must refuse with two references, then succeed only after the alias is dropped.
The reference counter is a kernel observation in this finite no-concurrency lab;
it is not a replacement for lifetime/alias control in a concurrent VMM.
Code is initially guest RW, then RX before a vCPU exists, with a read-only host
alias. A real guest store to the code GPA must produce a permission fault.
RAM/stack remain RW and non-executable.

`held` retains the dirty allocation across four unmap/remap rounds. It verifies
the previous pattern, and must keep all 64MiB PRESENT. `corrupt` changes one word
between guest write and verify: it must fail with `guestResult(3)`, still destroy
the VM and report no cleanup error. Freeing a mapped extent is refused. Native
geometry and complete page-query counts are checked without changing sysctls.
Failures remain failures, and cleanup errors are separate from the primary error.

These facts establish retirement of the exclusively owned backing and its
physical accounting charge. They do **not** identify physical frame numbers or
promise a simultaneous 64MiB global free-list delta. The JSON therefore keeps
`physicalReleasedBytes` and `hostFreeListDelta` null and separately records successful
deallocation counts and observed footprint reductions. Credits are bounded to the
extent plus 64KiB, and later cycles must return to their start footprint within 64KiB. RSS alone is misleading.
Page observations are sequential, and the kernel may allocate/block. Do not use
these scans or full-memory checks on a packet-processing executor.

The finite lab needs an external wall deadline (180s used in validation): malformed
guest code could otherwise never return from `hv_vcpu_run`. This is not yet a
long-running service owner, multi-vCPU quiescence protocol, hotplug allocator,
Linux guest balloon integration or a solution for Apple-owned VZ DRAM. Cleanup
failures cause a nonzero exit; process exit is the final research containment.

## Reproduce with disposable storage

Use an empty owned test directory on a disk with sufficient space. Keep all build
paths there; do not clean global caches or use production container state. Set
`SWIFT_BIN` to the verified Swift6.4.1 `usr/bin`, `LLVM_BIN` to compatible LLVM22
`bin`, and `LAB_OUT` to that disposable directory. Commands are run from repo root.

```sh
"$SWIFT_BIN/swiftc" -swift-version 6 -O -wmo -parse-as-library \
  -enable-experimental-feature Embedded -no-allocations \
  -target aarch64-none-none-elf -emit-ir Examples/HypervisorMemoryLab/Guest.swift \
  -o "$LAB_OUT/guest.ll"
"$LLVM_BIN/opt" -verify-each '-passes=internalize<preserve-gv=swift_guest>,globaldce' \
  -S "$LAB_OUT/guest.ll" -o "$LAB_OUT/live.ll"
"$LLVM_BIN/llc" -filetype=obj -code-model=small "$LAB_OUT/live.ll" -o "$LAB_OUT/guest.o"
"$SWIFT_BIN/clang" --target=aarch64-none-elf -c Examples/HypervisorMemoryLab/boot.S \
  -o "$LAB_OUT/boot.o"
"$SWIFT_BIN/ld.lld" --no-undefined --gc-sections -z noexecstack \
  -T Examples/HypervisorMemoryLab/link.ld "$LAB_OUT/boot.o" "$LAB_OUT/guest.o" \
  -o "$LAB_OUT/guest.elf"
"$LLVM_BIN/llvm-nm" --undefined-only "$LAB_OUT/guest.elf" # Must produce no imports.
"$LLVM_BIN/llvm-objcopy" -O binary "$LAB_OUT/guest.elf" "$LAB_OUT/guest.bin"
"$SWIFT_BIN/swift" build --package-path Examples/HypervisorMemoryLab \
  --scratch-path "$LAB_OUT/build" --cache-path "$LAB_OUT/cache" -c release --jobs 2 \
  -Xswiftc -warnings-as-errors
```

Reachability-based LLVM internalization is also used by the repository's existing
freestanding tests. Without it an unreachable Embedded runtime helper imports
`memset`; do not add a fake memset or waive undefined symbols. Keep the linked
ELF and disassembly, and check the input hash before executing trusted guest code.
The tiny `boot.S` handles the architectural entry/return-to-host only; the memory
workload is compiled Swift machine code with no runtime allocation or libc import.

Locate the actual built product, copy it to the owned artifact directory, sign
that copy using `codesign --sign - --entitlements
Examples/HypervisorMemoryLab/hypervisor.entitlements`, then strict-verify it.
Under an external 180s watchdog, run it with `guest.bin result.json release` (or
`held`/`alias`/`corrupt`). Result paths must be absent; no output overwrite is allowed.
Expected native exit is0 for release/held/alias,1 for corruption. No permanent service
is installed. CI builds the optional host package; VM execution is a separately
signed, opt-in real-host acceptance gate.
