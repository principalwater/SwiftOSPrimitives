# Native Linux backing-memory lab

Finite, NIC-free Swift HVF backend for Apple Containerization, plus the earlier
standalone Linux experiment. Requires an Apple-silicon Mac, macOS27 deployment
target/SDK and Swift6.4.1. This is optional research code; the root package's
PageMemory/BoundedMemory products have no Containerization dependency.

## Current Apple container integration

Apple container1.5.0 (`d265d669ecae041bf338cb3b39c4118316d138f0`) selects
Containerization0.47.0 (`bc994b88df46207fad7775b0eabc51947e315881`).
`NativeVirtualMachineManager` implements its real `VirtualMachineManager` and
`VirtualMachineInstance` interfaces. `container-native-lab` uses the upstream
`LinuxContainer`, unmodified vminit0.47.0, vmexec, cgroups, exec/I/O and Vminitd
gRPC lifecycle. No custom guest PID1 substitutes for these components.

The current external-backend API needs three access adjustments: public
VsockListener construction/yield and public, Sendable WriteFileFlags. Apply the
reviewable [minimal patch](Patches/containerization-0.47.0-public-backend.patch)
to an isolated checkout of the pinned dependency, then set its explicit path:

```text
export SWIFTOS_CONTAINERIZATION_PATH=/absolute/disposable/path/containerization
```

Use the checked-in Package.resolved. Keep SwiftPM scratch, dependency, module
cache and temporary paths inside the disposable test root. Build with `swift test
-c release -j 1 -Xswiftc -warnings-as-errors`, retaining raw logs. Copy the host
executable to a fresh artifact path, sign with `hypervisor.entitlements`, and
verify with `codesign --verify --strict`. Never replace an installed container CLI
or start its global service for these tests. This integrates the library backend
used by the current release, not a complete fork of its installed CLI/service.

The adapter deliberately admits one1vCPU VM with1GiB boot RAM plus128MiB
virtio-mem RAM. It preserves standard OCI guest-only mounts and their options,
masked/readonly paths, no-new-privileges and normal upstream setup. Extra block
devices, virtiofs/host shares, shared-pod volumes, network interfaces, nested
virtualization and VM extensions fail admission. The readonly init disk is vda;
the disposable writable ClickHouse disk is vdb. The trusted hash-retained kernel
is Linux6.18.35 with virtio-mem, hotplug/hotremove, GICv3, PL011, ext4, virtio-MMIO,
block and vsock built in; this is not a stock Apple default-kernel claim.

Guest API transport is standard virtio-vsock over bounded native AF_UNIX
socketpairs. There are no host listening ports or NICs. One synchronous pthread
owns CPU execution, registers, RAM mappings, device state and native teardown.
The Swift concurrency bridge transfers only bounded commands/FD ownership through
Mutex; it never lends guest RAM across an await. Start failure joins its worker
before returning an error. Concurrent stop waits for the one actual pthread_join.
Console files are created exclusively with O_EXCL/O_NOFOLLOW and0600; failed
start cannot truncate an existing log. A process-wide lease refuses a second
native VM and is released only after clean native destruction. The2ms watchdog may only request CPU exit; its serial queue
is drained before CPU destruction.

## Owned backing and revocation

The dynamic GPA region0x100000000 is not boot RAM. Sixty-four independently owned
2MiB HVF allocations back standard virtio-mem. PLUG zeroes and maps before ACK.
The guest must negotiate VERSION_1 and UNPLUGGED_INACCESSIBLE. Only the kernel's
UNPLUG request authorizes revocation; API calls request policy, not physical free.
The sole CPU is stopped throughout request execution.

UNPLUG removes stage2 mappings, checks exact native anonymous entry size/offset,
exclusive reference count, no shadows/external pager/wiring, then deallocates the
owned object before ACK. The old virtual range must be absent afterwards.
Unplugged GPA access fails the run, including instruction aborts and ISV=0. RAM
payload pointers are resolved anew and split at allocation boundaries; queue
metadata stays in boot RAM. Disk writes are bounded and F_NOCACHE avoids host
file-cache pollution. No pointer survives CPU execution. Unexpected mutation
failure destroys the research VM; it is never converted into a false ACK/BUSY.

Native VM-object deallocation, resident pages before retirement and task physical
footprint deltas are separate observations. Resident counts include security
zeroing by the host; they are not all attributable to ClickHouse. Paged-out pages
are reported separately. Exact arrival on the host physical free list is unknown
and remains null. No private API, guessed PFN, purge, foreign-task mutation,
borrowed VZ RAM or assembly bypass is used.

## Native scenarios

```text
container-native-lab <Image> <initfs.ext4> <fresh-root.ext4> <fresh-output> smoke
container-native-lab <empty-kernel> <initfs.ext4> <fresh-root.ext4> <fresh-output> start-refusal
container-native-lab <Image> <initfs.ext4> <fresh-root.ext4> <fresh-output> memory <canary>
container-native-lab <Image> <initfs.ext4> <fresh-root.ext4> <fresh-output> held <canary>
container-native-lab <Image> <initfs.ext4> <fresh-root.ext4> <fresh-output> alias <canary>
```

Cross-compile `container-memory-probe` with the matching static ARM64 Musl SDK.
It owns a64MiB PageMemory canary, verifies every byte on each request, reports
MemTotal/MemAvailable, and explicitly releases its mapping. Retain original
symbols when stripping a separate guest artifact.

Disk admission requires a fresh COW copy named `artifacts/clickhouse-run-*.ext4`,
8GiB logical capacity, single link, current uid, exclusive lock and an enclosing
private root OWNER.json containing its canonical root, uid and research purpose
`isolated-container-native-G18`. The marker is experiment-scoped, not a public
provisioning format. Never reuse a modified image or write to accepted ancestors.

The ClickHouse workload is26.9.19.9, loopback-only inside the guest,896MiB cgroup
limit,640MiB server bound,192MiB/8s/one-thread query limits and bounded scans/output.
Four100K-row batches have independent fixed count/id-sum/payload-hash/byte oracles.
Two shrink/regrow cycles require a real identified query with at least16MiB live
memory before and after UNPLUG, unchanged SQL aggregates and the intact canary.
Guest capacity must decrease128MiB and return. Cgroup usage/limit, anon/cache,
CPU, reclaim events, OOM and OOM-kill are retained. Successful file-cache reclaim
at memory.max is an observation, not an OOM: the first strict-zero-max diagnostic
failed and is retained separately. Hard limit and zero-OOM checks remain enabled.

Held mode performs the same guest UNPLUG but retains host objects and reuses them
on PLUG. Alias mode deliberately adds a second native mapping; reference count2
must refuse backing retirement and fail the run, followed by explicit teardown.
A process exit alone does not qualify either control; inspect native error, object
observations, pthread join and VM destruction. All trials have original finite
deadlines, one VM maximum, resource admission and nice19. No working-network
configuration or primary Macray task is involved.

## Wire and lifecycle verification

Release Swift Testing covers split-ring wrap/cycles/geometry, block status,
vsock golden headers, real socket I/O, monotonic credit ACK, small-RX fragmentation,
multi-peer demultiplexing, reset despite obsolete credit and lossless shutdown
under actual local socket backpressure. Manager tests preserve OCI mount options
and reject unsupported host attachments. Actual failed-start before/after trials
qualify self-join. An actual manager/start regression also preserves an existing
console sentinel and verifies self-join before error return. Preserve raw native outcomes separately from diagnostic
collector completeness; unsupported Swift Testing event mapping is not a reason
to invent test counts or rerun completed tests.

## Limits

This is a finite research backend, not production adoption or App Store API.
Recoverable multi-object rollback/BUSY, multiple vCPUs, DMA/LPI, arbitrary disks,
network adapters, migration/suspend and full stock CLI/service selection remain
pending. Native Mach region reference observations are empirical on the tested
OS; they are not a general HVF ownership contract for arbitrary foreign memory.

The earlier `linux-memory-lab`/`linux-memory-guest` standalone PID1 scenarios remain
separate. They cannot substitute for actual LinuxContainer/Vminitd qualification.

## Primary contracts

- [Current Apple container release](https://github.com/apple/container/releases/tag/1.5.0)
- [Containerization0.47.0](https://github.com/apple/containerization/tree/0.47.0)
- [ARM64 Linux boot](https://www.kernel.org/doc/html/latest/arch/arm64/booting.html)
- [Virtio memory/MMIO/vsock](https://docs.oasis-open.org/virtio/virtio/v1.3/virtio-v1.3.html)
- [Linux memory hotplug](https://docs.kernel.org/admin-guide/mm/memory-hotplug.html)
- [Cgroup memory events](https://docs.kernel.org/admin-guide/cgroup-v2.html#memory-interface-files)
- [Hypervisor](https://developer.apple.com/documentation/hypervisor)
- [XNU VM ownership](https://github.com/apple-oss-distributions/xnu/tree/main/osfmk/vm)
