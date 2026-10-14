# Native host balloon control

The package adds `BalloonBudget`, a standard-library-only planner for logical guest
resident-memory targets. It validates aligned installed/floor/step geometry, rounds requests
upward conservatively and limits each change. It allocates no owned storage and performs
no syscall. The caller must serialize requests, supply fresh observations and enforce its
own guest/host pressure policy. A target is not a lease, driver acknowledgement or proof of
physical memory release. Never use it as permission to reuse donated frames.

The separate `Examples/BalloonHostLab` package demonstrates a native Swift QMP controller
over pipes to one disposable QEMU10.2 process. It does not connect to existing VMs or
install services. Its synchronous API belongs on a dedicated blocking control context,
never a UI actor or Swift cooperative executor. The lab validates the greeting/capability
exchange, correlates command IDs, separates events from replies, caps frames/total input
and uses a monotonic session deadline. It accepts only its small command set. It is not a
general QMP SDK or an authenticated remote management service.

`balloon value` specifies logical VM bytes, rather than the size of the donated balloon.
QMP command success only means the request was accepted. `query-balloon actual` reports
the guest-written logical size. Host RSS/physical-footprint counters are separate. These
contracts come from the [QMP reference](https://www.qemu.org/docs/master/interop/qemu-qmp-ref.html#command-balloon)
and [wire specification](https://www.qemu.org/docs/master/interop/qmp-spec.html).

The freestanding Swift guest holds a generation-bound FrameLedger reservation throughout
ten real host-requested inflate/deflate cycles. A single descriptor is outstanding per
queue. Each post checks the preexisting producer/consumer indices, publishes the next
available slot with a device barrier, then checks the next used index, descriptor identity
and used length. The read that licenses completion precedes its acquire/device barrier;
the descriptor head changes between laps to detect stale entries in reused slots. Ten
cycles reuse all eight ring slots; they do **not** exercise65536 index
wraparound. The guest never reads donated pages before deflate completion. It initializes
every returned byte before checking/reusing it. Device reset precedes ledger-ticket release.

After the guest's final checks, it keeps running under a five-second deadline so the host
can finish its final actual observation and issue QMP quit. This avoids a query racing VM
exit. Missing host targets time out; no device produces a real DeviceNotActive reply.
Unsupported host targets are refused by the real guest without inflation. Wrong sequence
and a deliberately poisoned real used-entry identity have separate negative gates.
Cancellation while inflated joins/terminates this entire disposable VM. It does not claim
deflate success, page reuse or recovery of a live production VM. Raw primary/cleanup errors
and guest/QEMU diagnostics remain experiment evidence. Terminal device failures keep every
ticket reserved until this entire disposable VM exits; they do not prove live-driver
quiescence or reset recovery. Reset success waits for status0 with a bounded deadline.

QEMU's [pinned balloon implementation](https://github.com/qemu/qemu/blob/v10.2.0/hw/virtio/virtio-balloon.c)
warns on backing pages larger than4KiB and ignores nonfatal discard failures. On this
16KiB Mac host, the warning is explicitly retained and qualified. Successful protocol
cycles cannot establish physical host reclaim: `physicalReleasedBytes` remains unknown.
The guest's raw device boundary remains unsafe and fixture-specific; it does not expose a
public safe DMA/balloon ownership API or prove LinuxKbuild, CFI/ORC/perCPU guard readiness.

## Reproduction

Use official Swift6.4.1, LLVM22.1 and pinned QEMU10.2. Build/test the package:

```text
swift test --package-path Examples/BalloonHostLab -c release --jobs 2
```

Set `KERNEL_LLVM_BIN`, `GUEST_QEMU_BIN` and `GUEST_HOST_BIN` to verified executables,
then run `Tools/CheckLowLevel.swift` with compiler, repository and owned scratch directory
arguments. `GUEST_HOST_BIN` points to the built `balloon-host-lab`. This adds the host cycle,
missing-device, unsupported-target and cancellation gates to the existing compiler/ELF/guest checks. Never run
QEMU or install a kernel/module on a live bridge/exit merely because its home role is standby.

The small `memory-contracts` native probe also exercises12288 bounded target steps and an
independent checksum503316480. That is suitable for a strictly capped standby probe; its
whole-process CPU/RSS numbers are not QMP VM costs or language-wide comparisons.

Actual physical reclaim needs a separate4KiB backing host and sufficiently large, owned
donor ranges, with host RSS/footprint/pressure observations and donor isolation. Adaptive
pressure selection, Virtualization.framework/Applecontainer integration, live-VM recovery
and Linux kernel ABI/hardening remain separate open work.
