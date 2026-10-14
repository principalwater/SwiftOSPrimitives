# Balloon donor lifecycle and full split-ring wrap

The optional freestanding Swift guest now erases its entire exclusively reserved
16KiB donor extent before every inflate publication. The existing native Swift RAM
fill emits volatile stores, and a whole-extent volatile read verifies every aligned
word before donation. This covers the current donor bytes; it cannot remove earlier
copies, registers, host snapshots, swap, compressor contents or device buffers. It
is not a production secret-store guarantee. No new C or Rust implementation is used.

The two rings and PFN list live outside the donated frames. Their generation-bound
ledger reservations remain held through inflate and deflate. No donor read occurs
between inflate publication and real deflate completion. Every returned byte is
initialized before any donor read or reuse. Successful device reset precedes freeing
the reservations. Reset occurs before any frame write during setup, and final
status0 plus both QueueReady0 observations precede release. PFNs are verified before and after
inflate, immediately before deflate and after its acknowledgement; actual avail and
used indices on both queues are checked at the end. An adjacent-RAM canary checks
the remaining extent. One descriptor
is outstanding per queue, with rotating heads and bounded native timer deadlines.

## Actual guest boundary

The full-wrap gate completes65540 inflate and65540 deflate used-ring operations.
Both software counts end at65540 and both16-bit wire indices end at4. The injected
count65536 is the first post-wrap submission; the actual crossing is65535 to65536. A compiler-negative gate refuses combined
host/full-wrap modes, and the success marker itself requires65540 cycles.
Rotating heads detect the prior ring lap; they repeat every64 submissions and do
not provide arbitrary replay resistance. This extends
the separate RNG queue wrap proof to the actual balloon queues. Six device-boundary
controls fire at count65536:

| Control | Required native refusal |
|---|---|
| Wrong inflate completion head | `VIRTIO_IDENTITY_FAIL` |
| Wrong deflate completion head | `VIRTIO_IDENTITY_FAIL` |
| Nonzero device-written length on deflate PFN list | `VIRTIO_LENGTH_FAIL` |
| Stale inflate used index before publication | `VIRTIO_STALE_COMPLETION` |
| Withheld deflate publication | `BALLOON_DEFLATE_TIMEOUT` |
| Dirty final donor word after erase | `BALLOON_ERASE_FAIL` |

Two additional one-cycle native controls corrupt the deflate PFN list and report
QueueReady1 after reset. They must terminate at `BALLOON_LIST_FAIL` and
`BALLOON_RESET_QUEUE_FAIL`, respectively, before donor initialization/ticket release.

These are guest-injected corruptions around real device operations; they do not
claim QEMU naturally produces such faults. Identity controls snapshot the actual
previous-lap used ID before publication and replay it only AFTER a new matching
used-index completion. This independently detects loss of head rotation; the test
does not manufacture a mismatching ID from the formula under test. Length corruption
is also injected only after real completion. Withheld completion remains a real timeout, never a fabricated reply.
Terminal failures retain all tickets until the whole disposable VM exits. They do
not license live-driver reuse, cache maintenance, multicore/DMA quiescence or reset
recovery. The experiments remain outside library products and have no host device
passthrough, network interface or persistent guest disk.

A private negative snapshot omitting the whole erase call produces the exact first
cycle output `IRQ_PASS`, `DMA_PASS`, `BALLOON_ERASE_FAIL`, before any inflate. The
aggregate checker first reports the absent expected backing-size warning, since no
inflate occurred. That aggregate diagnostic is retained separately; the actual
three-line guest output is the erasure negative evidence. This snapshot is a
deliberate mutation of the new guard, not an unchanged historical release.

## Measurements and scope

On macOS27.0.1/M2Max with Swift6.4.1, the isolated QEMU10.2/TCG whole-wrap run
completed in6.206 seconds wall/7.507 seconds cumulative process CPU, with peak RSS
37,109,760 bytes. It erased and reinitialized1,073,807,360 donor bytes each across
the cycles. The measurement includes VM boot, IRQ/DMA and guest checks; it is not
a syscall/packet latency or a Swift-versus-Rust comparison. QEMU can have host
threads even with one guest CPU and single-thread TCG.

All30 actual guest gates passed, as did42 Release tests,42 ASan tests,36 compiler
ownership/lifetime cases and the four existing host-control modes (cycles, absent
device, cancellation while inflated, wrong target). The unchanged accepted host
controller artifact was reused read-only with the newly compiled guest. The root
PageMemory/BoundedMemory sources were unchanged; no new platform deployment target
or package runtime dependency was introduced.

On the admitted weak Linux standby, the source-identical accepted static native
consumer again observed512 to0 resident pages for its own2MiB mapping,256 value
destructions,1024 compact Atomic slots and the independent frame/target/sequence
checksums. CPU9.521ms, wall81.046ms, final RSS5,689,344 bytes were measured under
32MiB/no-swap/10%CPU/8-task/15-second/networkless caps. Sampled home choice, service
PIDs/restarts and configuration hashes were unchanged; exact owned remote files
were removed. This was a native foundation check, **not a VPS VM/balloon run**.

## Native VM integration boundary

[Virtualization.framework](https://developer.apple.com/documentation/virtualization/vzvirtiotraditionalmemoryballoondevice)
exposes a requested target, not a guest completion counter. SDK27 says the guest
may never handle it. Targets use1MiB geometry and the framework rounds down/clamps
invalid values; the conservative BalloonBudget rounds up before the request. Every
VM operation must occur on its designated serial queue, and creation requires the
virtualization entitlement. A linked native read-only capability probe on this Mac
reported support, a4MiB minimum and32GiB maximum VM memory size, and1..64 CPUs.
Those are observed platform limits, not a created VM or balloon-completion test. The
first interpreter attempt could not link the framework symbols; the separately
compiled machine-code probe passed. No VM, entitlement or persistent service was installed. An adapter must preserve those native constraints,
obtain guest pressure/actual acknowledgement independently, bound/cancel requests
and resynchronize live state before issuing another request. Never substitute a
request setter or process RSS delta for that acknowledgement.

QEMU's [pinned balloon implementation](https://github.com/qemu/qemu/blob/v10.2.0/hw/virtio/virtio-balloon.c)
still warns on16KiB backing. The current run reports `physicalReleasedBytes: null`.
This is distinct from the [actual PageRegion reclamation](MemoryReclamationReport.md)
experiment. A dedicated4KiB backing environment with larger exclusive donors and
independent host observations is still needed for physical VM reclamation.

Applecontainer integration, physical Pin, cache-coherent general DMA, LinuxKbuild
ABI/hardening and live driver recovery remain open. See the [virtio1.3 specification](https://docs.oasis-open.org/virtio/virtio/v1.3/virtio-v1.3.html)
for the wire contract; this experiment implements only its pinned, single-CPU subset.
