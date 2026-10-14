# Bounded split-ring progress

`BoundedMemory.SplitRingSequence` is standard-library-only arithmetic for serialized,
one-at-a-time split-ring submissions. Queue size must be a nonzero power of two at most
32768; the full UInt64 completion count remains separate from the wrapping UInt16 wire
index. Available/used slots and a rotating descriptor head remain bounded across wire
wrap. `advance()` refuses UInt64 exhaustion without changing progress. The caller must
check exhaustion before publishing and validate actual completion before advancing.

```swift
guard var sequence = SplitRingSequence(queueSize: 8) else { return }
guard !sequence.isExhausted else { return }
let expectedUsedIndex = sequence.wireIndex &+ 1
let usedSlot = sequence.ringSlot
let descriptorHead = sequence.descriptorHead
// Publish with the platform's required device barriers; validate the actual used entry.
// Only after the actual completion: guard sequence.advance() else { ... }
```

These values are copyable arithmetic, not unique leases, DMA provenance, safe driver
completion receipts or authority to reclaim memory. Finite wire/head identities repeat;
this cannot prevent arbitrary malicious device replay. Live queue recovery needs its own
verified device state and quiescence. No resetting method invents that proof.

## Real guest integration

The optional unsafe FreestandingGuest uses the same sequence in virtio-rng and both
balloon queues. It checks the actual pre-publication available/used indices, publishes
with native device barriers, reads the used index before the acquire/device barrier,
then validates exact next index, descriptor identity and length. An unchanged index at
deadline is a timeout; any changed index other than the expected next value is a distinct
`VIRTIO_USED_INDEX_FAIL`. Unused used-ring entries start with invalid ID/length sentinels
before QueueReady; the device must overwrite them. Only after those checks
does it advance progress. The existing per-operation deadline remains. Exhaustion is
refused before publication; failed operations keep frame tickets reserved until the
disposable VM exits. Native reset precedes successful ticket release.

The new positive case executes 65,540 real 32-byte virtio-rng submissions with device-written
used-ring completions, including 65,535 ->0 ->4 wire-index progress. It starts the device at zero, not a fabricated
near-wrap baseline. A bounded 60-second guest deadline and 75-second host execution
deadline protect the experiment. The maximum actual written extent across all requests
is retained for post-reset bounds checking, because a legal later partial write does not
erase earlier writes. The native driver, IRQ and balloon checks continue afterward.

Four separate negative ELFs reach count 65,536 before deliberately corrupting an actual
used descriptor ID, an actual used length, the completion index, or the pre-publication
used index. Each emits its exact count 65,536 injection marker before corrupting memory,
then its exact refusal marker, never the positive wrap marker. A separate unpublished-index
control injects an unexpected index without publication; it must refuse as an index
violation rather than masquerade as an expected timeout. These are real-device
completion-path fault controls with deliberate RAM corruption, not proof that QEMU
spontaneously produces those failures. None reads or releases donated balloon pages
after a terminal failure.

This experiment is single CPU, pinned QEMU 10.2, MMU-off identity mapped coherent RAM.
It does not establish fresh payload data on each RNG request: it verifies used-ring progress
and the maximum observed written extent, not byte-by-byte payload freshness. It does not
prove cache maintenance, multicore concurrency, live driver reset recovery,
general physical pinning, safe DMA API, LinuxKbuild, CFI/ORC or kernel module readiness.
The split-ring geometry and ordered publication rules follow the
[Virtio1.3 specification](https://docs.oasis-open.org/virtio/virtio/v1.3/virtio-v1.3.html).
QEMU's [pinned implementation](https://github.com/qemu/qemu/tree/v10.2.0/hw/virtio) is the
device under test. Balloon physical reclaim remains qualified on a 16 KiB backing host.

## Reproduction

Use Swift 6.4.1, LLVM22.1 and QEMU 10.2. With `KERNEL_LLVM_BIN` and `GUEST_QEMU_BIN` set
to verified executables, run `Tools/CheckLowLevel.swift` with compiler, repository and
an owned scratch directory. This runs 20 audited guest cases, including the new six.
Set `GUEST_HOST_BIN` to an independently validated BalloonHostLab executable to retain
its four actual host-control gates. Never run QEMU/install kernels on a live VPS merely
because its home-gateway role is standby.

The small native MemoryContracts consumer also executes 131,080 sequence steps with an
independent checksum 4,294,901,788, plus existing mapped-value destruction, frames and
page discard/reset checks. This is suitable for strict 32 MiB/10% CPU native admission.
It is arithmetic/mapping evidence, not remote virtio device or guest reclaim evidence.
