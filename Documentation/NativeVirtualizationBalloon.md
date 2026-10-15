# Native Swift Virtualization balloon lab

This optional macOS27 example boots a disposable Linux VM using Apple's
Virtualization.framework. Both the host controller and the two guest executables
are Swift6.4.1. The VM has one CPU,256MiB, entropy, serial and a traditional balloon;
no NIC, storage, directory share or socket device. It does not use an existing
container service, change a host kernel, or install anything on a VPS.

## Ownership and native boundary

`Examples/VirtualizationBalloonLab` is separate from the library products. The host
uses VZ's default main queue, checked at runtime, with a monotonic120s experiment
limit, shorter boot/response/operation limits and a5s stop limit. Stop is explicitly
awaited through an owned task which survives caller cancellation. The cancelled
experiment does not count as a completed inflate/deflate cycle. A late/missing stop
is an error, not permission to kill a helper belonging to another application.

`Bootstrap.swift` is compiled as allocation-free Embedded Swift for the AArch64
ELF ABI, then linked with the official musl SDK's startup objects/libc. Its Swift
object imports only execve/getpid/memset/mount/pause/write. The13KiB executable
mounts proc/sys/dev and execs the hosted Swift probe as PID1. Hosted Swift runtime
initialization needs proc before `main`; trying to mount it in hosted Swift main
was too late and produced a real init crash. This bootstrap is native Swift;
header files supply Linux ABI declarations without a C implementation shim.
It is a laboratory init, not a general service supervisor or kernel implementation.

The guest owns a64MiB PageRegion and an8MiB live canary. Commands have a strictly
increasing sequence,64-byte input bound and a1000-command cap. Every command checks
the canary. Touch and reuse verify all64MiB; erase verifies every byte before
MADV_DONTNEED. Residency is checked independently with mincore. Guest allocation
and host balloon requests retain explicit headroom. The protocol is bounded at
8192bytes/line,16384buffered/1MiB total; any framing/timeout error retires the VM.

Linux continues to own the virtio driver. The probe reads only the modern PCI
balloon configuration: unique1af4:1045 identity, bounded capability traversal,
validated BAR/offset/length and read-only resource mapping. It never writes a PCI
register, changes a queue, reads an ISR, unbinds a driver or takes over a live device.
The prototype is limited to the fixed single-vCPU, no-hotplug disposable VM.
It is not a portable PCI/DMA framework or an arbitrary-device observer.

## Completion is separate from physical reclamation

The VZ target setter is only a request. In this actual VM, MemTotal stayed constant
while the balloon worked. Linux's managed-page adjustment is conditional on the
negotiated DEFLATE_ON_OOM feature; MemTotal is therefore not a general completion
oracle. The actual128-bit negotiated bitmap has DEFLATE_ON_OOM enabled and free-page
hint/reporting disabled on this VM. The bounded negotiated feature bitmap and actual driver binding are recorded at boot;
Linux6.18.35 exposes128 feature bits, so a64-bit-only parser was rejected and corrected.

Instead the guest reports both little-endian device fields: requested PFN count
and actual PFN count. Linux updates `actual` after its used-ring acknowledgement
wait. The host accepts a phase only when a fresh sequenced observation matches
both fields. Requests for128MiB reached32768 actual4KiB PFNs, then returned to0.
The ignored-driver control requires an explicitly unbound guest driver and leaves a real configured device with32768 requested
and0 actual; the test must time out despite the successful setter, and then obtain
a fresh post-window heartbeat. A silent console is a failure, not a passed negative.

Self TASK_VM_INFO is deliberately named **controller** RSS/footprint. VZ uses a
separate VM service; those self counters do not establish its backing residency.
Every result preserves `physicalReleasedBytes: null`. This slice proves actual
balloon protocol completion and Linux page reclamation, not physical return of
128MiB to the Mac, memory sanitization in VZ, or superiority over another language.
The64MiB touched donor is also smaller than the128MiB balloon request: cold free
pages may be donated. A physical-release experiment must first attribute the exact
owned VM helper, calibrate touch/rebound, bound untouched free pages, and use
matched no-request controls. No name-only helper termination is acceptable.

## Reproduce without touching working infrastructure

Use a new owned scratch directory, Swift6.4.1, SDK27, a matching static Linux SDK
and an ARM64 raw Linux Image with builtin virtio-console/balloon/initramfs support.
Do not run these VM tests on a bridge/exit VPS or attach an existing disk/share.

The tested kernel is the normal ARM64 Image from the official Kata3.32.0 asset:

- archive `kata-static-3.32.0-arm64.tar.zst`,696573576bytes,
  SHA256 `8736c054d9223974735394f822000823baef509e1c33405ec798240fa9b6e4b5`;
- member `./opt/kata/share/kata-containers/vmlinux-6.18.35-197`,
  SHA256 `f437320bab94f19105d12b932aa29735f0d54d2588218872254367f312c1027c`;
- corresponding config SHA256
  `a89f63bff1c636b70b580ab6bf86f4f6eb5cc296673b22a404461d6fc027d5e3`,
  builtin balloon/console,4KiB guest pages. This is not a signed custom Swift kernel.

Build the guest product with the explicit SDK bundle ID plus
`--triple aarch64-swift-linux-musl`; a triple-only SDK query was ambiguous with6.4.0
also installed. Strip debug information into a separate retained copy. Build the
bootstrap object with `-enable-experimental-feature Embedded -no-allocations`,
`-target aarch64-none-none-elf`, the official musl headers and this module map;
link that object for aarch64-linux-musl against the SDK crt1/crti/libc/crtn files.
Keep the hosted runtime resource path out of the Embedded compile.

Run `Tools/MakeGuestInitramfs.swift PROBE_ELF BOOTSTRAP_ELF NEW_OUTPUT`. It refuses
non-AArch64/nonstatic/truncated program-header tables and existing outputs. The
fixed newc archive contains only proc/sys/dev, dev/console, init and probe.
Build `vz-balloon-lab`, sign its owned copy with the included virtualization
entitlement and verify that signature before execution. No extra entitlement or
system-wide trust change is needed for this local ad-hoc research executable.

```text
vz-balloon-lab KERNEL_IMAGE INITRAMFS NEW_RESULT_DIR cycles
vz-balloon-lab KERNEL_IMAGE INITRAMFS NEW_RESULT_DIR absent
vz-balloon-lab KERNEL_IMAGE INITRAMFS NEW_RESULT_DIR ignored
vz-balloon-lab KERNEL_IMAGE INITRAMFS NEW_RESULT_DIR cancel-inflated
```

Preserve console.log, result.json, input hashes and original process outcomes.
`ignored` uses a pinned-kernel initcall blacklist, rather than pretending that a
setter failure occurred. A different kernel may name that initcall differently;
the negative then fails and must not be waived. Kernel panics use `panic=0` to
avoid an uncontrolled guest reboot loop. Input files must stay immutable inside
the operator-owned workspace; hash-then-open is not a hostile-writer proof.

## Evidence and open gates

Local macOS27.0.1/M2Max native validation passed four cycles, device absence,
ignored-driver and real Swift task cancellation while inflated. All successful
runs reported stopped=true and no cleanup error. The four native cycles observed about126–140ms from erase observation to inflated
observation and124–130ms to deflated observation. These include100ms polling,
serial sampling and host scheduling; they are not device-only or network latency.
Guest RSS ranged from about75.1MiB touched to11.1MiB after discard, including the
8MiB live canary. These values do not describe the VM helper footprint.

A private withheld serial reply fails within the3s response deadline and still
awaits stop; it is never classified as a successful ignored-driver control.
A private mutation accepting only
the requested field fails the ignored-driver test; a private mutation running
cleanup on the cancelled caller fails with CancellationError. Native archive
checks preserve existing bytes and reject truncated/dynamic headers.

Unchanged core library regressions:42 Release/42 ASan tests and36 compiler ownership
gates. CI also builds the Mac host and the Linux guest on their own platforms;
it does not pretend to boot VZ on a hosted runner. Native VM tests are the primary
real-device evidence. Public library APIs/dependencies/deployment targets unchanged.

Physical host backing attribution, no-request/pressure controls, live-driver
recovery, physical Pin, generic DMA/cache/SMP contracts, custom Linux Kbuild and
Applecontainer integration remain separate open work. No VM/package/module was
installed on a working VPS; previously capped native PageMemory VPS evidence does
not validate this ARM64 VZ path.

Sources: [Apple balloon API](https://developer.apple.com/documentation/virtualization/vzvirtiotraditionalmemoryballoondevice),
[Linux6.18.35 balloon driver](https://github.com/gregkh/linux/blob/v6.18.35/drivers/virtio/virtio_balloon.c),
[Kata release](https://github.com/kata-containers/kata-containers/releases/tag/3.32.0),
[Apple container overview](https://github.com/apple/container/blob/main/docs/technical-overview.md).

## SDK27 guest-memory view and owned HVF backing research

Optional `host-pages`, `host-held`, `host-ignored` and `host-late` modes add a public
custom Virtio diagnostic device. The fresh Swift PID1 probe reports actual System
RAM ranges from bounded `/proc/iomem`; the host requires one exact configured
range. It does not assume QEMU's GPA base. On the tested VZ machine it was
0x70000000 for256MiB. The custom transport can still be probed/reset by Linux;
unbound function-driver status does not establish a completely untouched VM.

`GuestBackingObserver` takes an ephemeral `guestMemoryMapping`, retains its
lifetime explicitly, queries native16KiB Mach dispositions without reading bytes,
and drops the mapping within an autorelease pool before returning. The main VM
and custom-device queues are both main. VM state brackets each synchronous query.
The package requires macOS27; no older-system fallback is advertised.

The early arm observes before/during inflation; `host-late` first creates a view
only after128MiB balloon acknowledgement and a separate1s settlement window.
Both real four-cycle arms still observed PRESENT|REUSABLE pages, not an observed
PRESENT reduction. Held/no-ack controls remain distinct. These are sequential,
unpaused mapped-view diagnostics: identity/shadow/coverage and absence of device
or mapping interference are unqualified. Aggregate flags never become a physical
release claim, and neither result transfers to Apple Container. No purge, advice,
unmap or deallocate is performed on Apple's memory.

The separate [owned HVF lab](../Examples/HypervisorMemoryLab/README.md) controls
allocation lifetime itself and demonstrates why guest unmap/RSS reduction and
backing deallocation are separate operations. A production backend decision is
still pending; no Containerization or VZ guest RAM ownership has been changed.
