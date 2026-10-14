# Stable mappings and real guest devices

This research adds memory ownership and isolated firmware experiments. It does not
install a Linux module, extend macOS's kernel or replace a production network service.
Package products remain entirely Swift. Native C declarations are ABI boundaries,
not alternate-language implementations. The optional assembly contains privileged
instructions and asynchronous register preservation; driver policy is Swift machine code.

## Typed mapping contract

`PageMapping` is the internal, byte-free anonymous-backing owner shared by PageRegion
and MappedValue. A live typed slot never coexists with a PageRegion byte-view promise.
It keeps release ownership even for a rejected null mapping, allowing destruction's
fallback after explicit cleanup failure. Page rounding, alignment padding, arithmetic
overflow and per-region budgets are checked before mapping.

`MappedValue<Element: ~Copyable>` holds one initialized value at a stable virtual address.
Moving the owner does not move its slot. `withValue` lends a single-element read-only
Span: no replacement, mutable projection or noncopyable move-out API is exposed.
Safe loans cannot escape or overlap release. Keep Swift exclusivity enforcement enabled;
unsafe pointer extraction and unchecked builds are outside this safe contract.

```swift
var value = try MappedValue.allocate { Atomic<UInt64>(73) }
try value.withValue { $0[0].store(91, ordering: .relaxed) }
let observed = try value.withValue { $0[0].load(ordering: .relaxed) }
try value.release()
```

Import PageMemory and Synchronization for this example. Atomic/Mutex are native stdlib
consumers, not new dependencies of PageMemory. The owner itself remains non-Sendable;
this example does not grant concurrent access or establish a multithread stress result.

For many fixed slots, map one `InlineArray<1024, Atomic<UInt64>>`, initialized with
its stdlib OutputSpan initializer. This packs1024 words into8192 bytes before OS
rounding, rather than1024 individual mappings. Native tests and the Linux contract
probe exercise this composition. MappedValue is for stable storage, not a replacement
for the general heap; mapping every tiny object wastes page geometry and syscalls.
InlineArray requires iOS26+; the library's single-value/Span owner still targets iOS18.
For an earlier target, use the existing scoped typed arena for batches and MappedValue
for the particular stable slot, rather than relying on unavailable InlineArray APIs.

| State | Element access | Destruction | Mapping |
|---|---|---|---|
| Live | Scoped read-only loan | Not attempted | Owned |
| Explicit unmap failed | Refused | Already performed once | Retained for caller retry |
| Fully released | Refused | Never repeated | Released |

`isDestroyed` and `isReleased` describe different facts. `mappedByteCount` is original
backing geometry, not a claim of currently live RSS. A successful mapping does not
guarantee future page faults cannot OOM. A factory builds a relocatable Swift value
before placement; arbitrary self-reference-safe in-place construction is not supplied.
This is post-placement virtual stability, not physical pinning or a general Rust Pin API.

Allocation errors retain `.memory(PageMemoryError)` or `.factory(Factory)` in a typed
MappedValueError, including Never factories. Nonblocking allocation/release admission
refuses before syscalls or destruction. This is caller-declared policy, not IRQ-state
detection or Linux GFP. Reading, user destructors, ordinary runtime work and owner drop
can fault/block. Use preallocated BoundedMemory for a reviewed nonblocking hot path.
Permanent unmap failure cannot be cured by retries alone; destructor cleanup is one
best-effort attempt and cannot report failure. Explicit release is required for reporting.

## Freestanding IRQ, DMA and balloon

The guest is pinned to QEMU10.2 virt-10.2/cortex-a72/GICv2, one CPU,64MiB, MMU off,
no network, disks, shared folders, monitor, semihosting or hardware passthrough.
The strict-align/no-FP profile, stack guard, whole-object imports, ELF extents and
assembly checks remain mandatory. Boot's linker-reserved frame extent is checked
exactly against exported symbols before every raw-memory driver experiment.

- A real EL1 physical timer/PPI30 interrupts Swift. The stub preserves GPRs, ELR/SPSR
  and16-byte stack alignment; FPEN must be disabled. A linker-owned counter avoids
  escaping a Swift inout pointer. Spurious acknowledgements are tolerated; timeout
  and duplicate delivery are distinct. The test owns the GIC for its whole run.
- Modern virtio-mmio entropy DMA writes an owned guest-RAM buffer. Descriptor/avail/
  used rings are bounded and naturally aligned; publication/completion use barriers.
  Only acknowledged device-written bytes are treated as received. The device is reset
  and read back before reservations return to the existing FrameLedger.
- A real traditional virtio-balloon device consumes four4KiB PFNs. Voluntary supply
  is allowed with requested==actual==0. Donated memory remains reserved and untouched
  from publication through deflate acknowledgement. Deflated bytes are reinitialized
  before reading/reuse; rings are reset before releasing reservations.
- Negative guests with masked IRQ, absent entropy/balloon devices, unpublished DMA
  or unacknowledged deflate must produce exact distinct failure sequences. They
  terminate the disposable guest without handing unacknowledged memory back.

The balloon fixture is a guest-initiated round trip, not an adaptive host target
controller. QEMU on this Mac emits its exact warning about backing pages larger than
4KiB. The harness retains and explicitly qualifies that diagnostic; every other
unexpected byte still fails the output gate. Acknowledgement and config.actual updates
are not measurements of physical host RAM released. Raw driver access is an unsafe
fixture boundary, not a published safe DMA/balloon typestate API.

## Evidence and remaining work

See the accompanying experimental release report for native/compiler/ASan/staticLinux
and standby-cgroup results. These checks support their finite contracts only. Kernel
Kbuild/CFI/per-CPU guard ABI, real IOMMU/DMA registration, safe pin initialization,
adaptive hypervisor balloon targets and Apple container adoption remain separate work.
Do not load this firmware or its PAL into a hosted process or Linux/macOS kernel.

Primary references: [virtio specification](https://docs.oasis-open.org/virtio/virtio/v1.3/virtio-v1.3.html),
[QEMU virt implementation](https://github.com/qemu/qemu/blob/v10.2.0/hw/arm/virt.c),
[QEMU balloon implementation](https://github.com/qemu/qemu/blob/v10.2.0/hw/virtio/virtio-balloon.c),
[Linux DMA guide](https://www.kernel.org/doc/html/latest/core-api/dma-api-howto.html).
