# Experimental stock balloon ownership

This default-off Swift backend uses the stock Linux virtio-balloon driver without
a kernel patch. It is separate from free-page reporting and virtio-mem capacity
changes. The finite controls below are qualified research, not an autonomous
production governor or a complete container application.

## Authority and recovery

- Require VERSION_1, MUST_TELL_HOST and DEFLATE_ON_OOM negotiation.
- Decode at most 256 little-endian 4 KiB PFNs before changing inflate ownership.
  Reject duplicates, foreign/unmapped pages and payload aliases atomically.
- Track boot and dynamic ownership in a compact bitmap across packets. Boot PFNs
  are valid transfers, but immutable boot backing is never reclaimed here.
- Only a completely owned dynamic 2 MiB object may be replaced. All CPUs remain
  parked. The owner rejects aliases/shadows/wiring, unmaps, deallocates, verifies
  the old virtual range is absent, creates cold anonymous zero backing and maps
  the same GPA before acknowledgement. Partial native failures stop the VM.
- A benign pinned-object refusal retires nothing. An alias refusal restores the
  original mapping before acknowledgement; neither is a post-retirement success.
- Deflate never remaps. A fully decoded mixed packet releases every known owned
  PFN before ACK and quarantines the invalid remainder. An undecodable deflate
  propagates to the VM owner before ACK, because the released PFNs are unknown.
- Guest `actual` telemetry may veto admission but never grants ownership.
- Reset clears ownership and advances its epoch. Metadata pins survive until VM
  destruction. No asynchronous DMA or pending native remap crosses reset.
- Each pulse has an eight-second lease. The coordinator polls independently and
  before MMIO; expired authorization cannot replace backing. Unsolicited deflate
  requests target zero and sticks quarantine, with no automatic reinflation.
- Revocation precedes fallible refusal telemetry. Quarantine preserves deflation;
  an owned-VM fatal error is never silently converted into a dropped notify.

The ledger differs from BoundedMemory's FrameLedger: the latter issues contiguous
allocation tickets, while the stock driver transfers arbitrary persistent PFN
sets. The new ledger remains internal to this optional backend.

## Normal RAM and native metadata

The measured Kata kernel lacks BALLOON_COMPACTION. Its stock allocator cannot use
online_movable virtio-mem RAM for classic ballooning. This mode therefore maps
cold owned objects before boot and advertises them as additional ordinary RAM.
It does not expose a competing virtio-mem device or permit its control setters.
Every descriptor/avail/used ring resolves through a native pin-before-pointer
boundary. Pinned objects cannot be retired, even after device reset.

The closed device model uses synchronous CPU copies, without physical DMA,
PCI/USB passthrough, an IOMMU, ACCESS_PLATFORM, packed/indirect rings or extensions.
Only this model requests `swiotlb=noforce`, before init arguments; any offered
ACCESS_PLATFORM feature fails admission. This is not a general DMA optimization.

## Independent qualification, 2026-10-17

Host: M2 Max / 32 GiB, macOS 27.0.1, Swift 6.4.1 release builds. Guest: Linux
6.18.35, 4 KiB pages, 512 MiB immutable boot plus 2560 MiB ordinary dynamic RAM.
The backend uses Apple Containerization 0.47.0 selected by Apple container 1.5.0.
All tests use private copy-on-write disks and two private synthetic NICs.

Frozen host UUID: `FD0A8532-8D8E-3F36-8C05-5AFD8F6E5ADA`.
Static guest BuildID: `030108cea0a2a9606157f928e1005349c0f12c2c`.
Both include retained source, SDK, signature and artifact hashes.

Actual cold/warm single-vCPU Hypervisor.framework owner controls passed 30 wire
packets each, three native replacements, alias restoration, metadata pin/reset,
expired-lease preservation, full-word canaries and payload-ownership fences.
Before/after release regressions independently reproduced and repaired mixed
and undecodable deflate handling. A separate CRLF response-framing regression
reproduced an accepted truncated body, then passed after byte-oriented parsing.

Two- and four-vCPU Linux small controls passed two 128 MiB pulses each, 512
packets, live SQL, 400,000 durable rows, full canaries and clean native teardown.
Live MemAvailable is a conservative admission/effect interlock, not exact PFN
attribution: workload churn, PCP lists and estimation affect it. `stat_refresh`
flushes VM counters but does not remove every source of noise.

Large controls hold 2176 MiB in a 557,056-row ClickHouse Memory table, twice. The
server/cgroup limits remain 2560/2816 MiB, with a 512 MiB observed guest reserve,
an eight-second SQL limit, eight-second return fence and five-GiB host RSS guard.
The pulse requests at most 2 GiB and explicitly drains to target/actual/owned zero.

| vCPUs | Final cold resident return per cycle | Time to at least 1024 MiB after purge |
|---|---|---|
| 2 | 1074 / 1038 MiB | 319 / 335 ms |
| 4 | 1114 / 1032 MiB | 748 / 422 ms |

These are separate return windows, not a lifetime counter reused across cycles.
SQL stayed active at the goal, produced 4999950000 and preserved the durable
hash. MemTotal was unchanged. Both runs observed zero OOM, OOM-kill or swap,
and all CPUs, native VM handles and worker threads were destroyed/joined.

The two-vCPU native process footprint fell from 3,229,388,688 to 2,105,249,704
bytes and 3,201,340,264 to 2,135,266,248 bytes. Four-vCPU values fell from
3,231,879,368 to 2,065,223,904 bytes and 3,205,764,112 to 2,130,351,264 bytes.
Exclusive resident backing retirement and process footprint are distinct from a
global free-list delta; `physicalReleasedBytes` remains null.

The lab's native Swift loopback HTTP client avoids repeatedly executing the
large C++ client image. It preserves query/profile limits, requires a real
SELECT 1 and Code 395 negative control, and rejects ambiguous/truncated framing.
It is a bounded lab-only HTTP/1.0 subset, not a general networking product.
Earlier CLI/FPR, capacity, wire and deadline failures remain failures. Changes in
host state and client path prevent a fair cross-client performance claim.

## Remaining acceptance

DEFLATE_ON_OOM preserves MemTotal visibility, not continuously allocatable
capacity. Its global notifier does not protect a memory-cgroup OOM. Autonomous
headroom management, actual global/memcg OOM, mid-pulse rescue, reset/reboot,
fault/soak and idle/sham accounting decomposition remain required. Metadata-pin
growth and general kernel/image compatibility are not yet qualified.

All five product gates remain open: persistent VM ownership, general memory,
multi-VM/resource/security, fair clean-host comparison, and native UI plus
images/network/shares/exec/volumes/update/rollback/Compose/copy-first migration.
Nothing here authorizes replacing installed services, tools or user data.

## Primary references

[Linux 6.18.35 virtio-balloon driver](https://github.com/gregkh/linux/blob/v6.18.35/drivers/virtio/virtio_balloon.c)
defines serialized PFN transfers and OOM rescue; its implementation was not copied.
[Linux VM statistics](https://docs.kernel.org/admin-guide/sysctl/vm.html#stat-refresh)
describes explicit per-CPU statistics flushing.
[Apple container 1.5.0](https://github.com/apple/container/releases/tag/1.5.0)
is the pinned integration release, independently checked on the qualification date.
