# Native Linux backing-memory lab

SMP/private-NIC Swift HVF backend for Apple Containerization, plus the earlier
standalone Linux experiment. Requires an Apple-silicon Mac, macOS27 deployment
target/SDK and Swift6.4.1. This is optional research code; the root package's
PageMemory/BoundedMemory products have no Containerization dependency.

See [G19 measured qualification](QUALIFICATION.md) for the completed SMP/NIC,
RAM-return controls and real process-crash recovery results and limitations.

See [G21 continuous qualification](CONTINUOUS-QUALIFICATION.md) and
[full-byte canary measurements](CANARY-PERFORMANCE.md) for the newer finite observer,
guest-online completion fence and measured native Swift optimization.

See [G22 persistent-governance qualification](PERSISTENT-QUALIFICATION.md) for
bounded lifetime-independent telemetry, real pending-stop/lifetime controls,
history wrap under ClickHouse and a new process-crash recovery qualification.
Shared bounded telemetry now lives in the dependency-free root BoundedMemory
product. The optional backend no longer depends on the unpublished UI package,
so a native application can depend on this backend without a package cycle.

G23 adds explicit sustained execution and validated larger memory layouts.
The default qualification profile remains finite; additional hardware acceptance
is recorded separately and does not imply product adoption.
See [G23 managed qualification](MANAGED-QUALIFICATION.md) for the final fourteen
profiles, independent telemetry, disk-reserve test and real SIGKILL recovery.

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

The adapter admits one VM with1...4vCPUs, up to two private NICs,1GiB boot RAM plus128MiB
virtio-mem RAM. It preserves standard OCI guest-only mounts and their options,
masked/readonly paths, no-new-privileges and normal upstream setup. Extra block
devices, virtiofs/host shares, shared-pod volumes, arbitrary host network interfaces, nested
virtualization and VM extensions fail admission. The readonly init disk is vda;
the disposable writable ClickHouse disk is vdb. The trusted hash-retained kernel
is Linux6.18.35 with virtio-mem, hotplug/hotremove, GICv3, PL011, ext4, virtio-MMIO,
block, vsock and virtio-net built in; this is not a stock Apple default-kernel claim.

Guest API transport is standard virtio-vsock over bounded native AF_UNIX
socketpairs. There are no host listening ports or NICs. One affine pthread per vCPU owns its native create/run/register/destroy calls.
The coordinator receives exit/register values and can resolve RAM or emulate
any device only after every scheduled vCPU is parked. Native exit cancellation
is sent only to unparked workers; wake priority rotates to avoid starving a
peer that has not entered the guest yet. Register snapshots include only values
consumed by the actual exit. Cancellation and native execution-time counters
make scheduling costs visible. PSCI CPU_ON and per-CPU FDT/MPIDR boot real SMP.
The coordinator owns RAM mappings, device state and native teardown.
The Swift concurrency bridge transfers only bounded commands/FD ownership through
Mutex; it never lends guest RAM across an await. Start failure joins its worker
before returning an error. Concurrent stop waits for the one actual pthread_join.
Console files are created exclusively with O_EXCL/O_NOFOLLOW and0600; failed
start cannot truncate an existing log. A process-wide lease refuses a second
native VM and is released only after clean native destruction. The upstream vminitd warning log level avoids one stop-all epoch per character
of routine serial INFO output. Warning/error and kernel panic diagnostics plus
structured CPU/NIC/memory/process evidence remain enabled. No query deadline or
integrity check is removed. The2ms watchdog may only request CPU exit; its serial queue
is drained before CPU destruction.

## Owned backing and revocation

The dynamic GPA region0x100000000 is not boot RAM. Sixty-four independently owned
2MiB HVF allocations back standard virtio-mem. PLUG zeroes and maps before ACK.
The guest must negotiate VERSION_1 and UNPLUGGED_INACCESSIBLE. Only the kernel's
UNPLUG request authorizes revocation; API calls request policy, not physical free.
Every vCPU is stopped throughout request execution.

UNPLUG first removes every stage2 mapping in the request and preflights every
exact native anonymous entry size/offset, exclusive reference count and absence
of shadows/external pager/wiring. Ownership refusal restores all original
mappings before BUSY; no object has been freed. Once irreversible retirement
starts, native failure is fatal. Success deallocates every owned object before ACK. The old virtual range must be absent afterwards.
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
`isolated-container-managed-G23`. The marker is experiment-scoped, not a public
provisioning format. Never reuse a modified image or write to accepted ancestors.

The ClickHouse workload is26.9.19.9, loopback-only inside the guest,896MiB cgroup
limit,640MiB server bound,192MiB/8s/one-thread query limits and bounded scans/output.
The two-NIC guest control plane uses memory.high112MiB and a hard memory.max128MiB
(the observed96.1MiBworking set thrashed below96MiBhigh). No installed image
is modified; only the isolated guest cgroup is configured through native RPC.
Four100K-row batches have independent fixed count/id-sum/payload-hash/byte oracles.
The current sustained-load query uses a bounded100K-row/100K-build hash join
with two-key String storage retained during probing, a4s intentional dwell and
an independent expected SUM(number)=4999950000. Full-table fixed integrity
oracles still cover all400K rows before and after every cycle. This replaces the
transient group-by peak, which does not guarantee a live allocation throughout
revocation. Earlier query/window/native failures remain retained and unwaived.
The existing Swift guest canary observes only the fixed load query IDs through
bounded HTTP/1.0 on guest loopback8123. It checks status, framing and numeric
results, uses finite socket deadlines and never exposes a host listener. This
avoids starting a heavy clickhouse-client process inside the critical window.
Two shrink/regrow cycles require a real identified query with at least16MiB live
memory before and after UNPLUG, unchanged SQL aggregates and the intact canary.
Guest capacity must decrease128MiB and return. Cgroup usage/limit, anon/cache,
CPU, reclaim events, OOM and OOM-kill are retained. Successful file-cache reclaim
at memory.max is an observation, not an OOM: the first strict-zero-max diagnostic
failed and is retained separately. Hard limit and zero-OOM checks remain enabled.

Held mode performs the same guest UNPLUG but retains host objects and reuses them
on PLUG. Alias mode deliberately adds a second native mapping at extent32. Reference
count2 must produce pre-commit BUSY and full remapping, with unchanged canary
and SQL integrity. That complete refusal-integrity scan precedes the timed load;
explicit diagnostic-alias retirement during the load allows the standard
Linux driver's retry to finish; the VM then completes normal shrink/regrow.
A process exit alone does not qualify either control; inspect native status, object
observations, pthread join and VM destruction. All trials have original finite
deadlines, one VM maximum, resource admission and nice19. No working-network
configuration or primary Macray task is involved.


## Private Ethernet and crash recovery

`IsolatedNetwork(index:0...1)` owns a nonblocking bounded AF_UNIX datagram pair,
not vmnet, a host interface, default route, NAT or PF rules. Only these attachments
are admitted. Each standard virtio-net device has independent RX/TX rings, MAC
and IRQ; checksums/GSO are not offered. Payloads are copied from freshly resolved
bounded guest spans while all CPUs are parked. No asynchronous NIC retains a
GPA pointer. Backpressure preserves the descriptor for retry. A partial factory
failure closes every previously claimed device endpoint before error return.

The finite host peer implements only checked ARP and UDP echo for RFC5737
192.0.2.0/30 and198.51.100.0/30. It has no IP socket or external forwarding.
The static Swift/Musl canary pins one native worker to each actual online Linux
CPU, checks a256KiB private mapping per worker and retains the main64MiB canary.
The final worker verifies sequence/payload echoes through both real guest NICs.
Every shrink/regrow sample requires increasing per-CPU and packet counters.

Crash recovery refuses a root filesystem without an internal ext4 journal.
`container-journal-lab` uses upstream native Swift EXT4Reader/archive/Formatter
APIs to create a fresh8GiB image with a64MiB ordered JBD2 journal. It never repairs
or reformats a source image or any production storage. The unjournalled default
image remains usable for graceful-only trials, but an actual crash corrupted its
inode metadata despite ClickHouse fsync; that failed image is retained.

`container-recovery-lab` uses native posix_spawn/waitpid for at most two owned
child generations, not a shell. It waits for an fsynced, atomically published
point after acknowledged durable400K-row inserts and an observed active query,
then sends SIGKILL to its exact unreaped child's process group. It waits for
actual leader death and group disappearance before
starting a fresh VM on the same disposable ext4 disk. The replacement validates
fixed persisted SQL oracles and repeats SMP/NIC/shrink/regrow checks. Table
fsync settings are verified against the actual engine; virtio-blk FLUSH uses
F_FULLFSYNC. This is process-crash recovery, not a power-loss/snapshot guarantee.
The optional `--boot-directory` pair selects the descriptor-admitted path for
both generations. The supervisor validates private directory/file authority and
the journal before starting either child; each VM then performs its own pinned
boot admission. Real SIGKILL/reopen on the same private image has passed this
path as well as the original legacy-path research control. Symlinked directory
admission is refused before creating the recovery output.
Descriptor mode also requires the exact `rootfs.ext4` child name, directory mode
0700, disk mode0600, enabled filesystem ownership and no extended ACL. Actual
wrong-file/mode/ACL/FIFO refusals precede output creation; the repaired supervisor
also passed a fresh SIGKILL/reopen workload. These research path checks do not
replace a product helper's pinned workspace/storage authority.
No in-flight query or volatile RAM is promised to survive. A private inherited pipe ties VM authority to the supervisor: parent death,
including SIGKILL, closes the only writer and causes the native owner to exit.
Paths are canonical, marker reads use O_NOFOLLOW/fstat, and inherited environment
is explicitly bounded. Native memory pressure is checked before each generation; all native outcomes and cleanup failures
are retained. The installed Apple container service is never used or restarted.

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
Hardware DMA/LPI, arbitrary disks/host-network attachment, migration/suspend,
PSCI CPU offlining and full stock CLI/service selection remain unsupported.
The stop-all design prioritizes explicit revocation safety; it is not a qualified
production throughput or idle-CPU design. Native run/watchdog deadlines and
ClickHouse query limits are never raised to turn a failed trial into success. Native Mach region reference observations are empirical on the tested
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

## Adaptive native backing RAM

`container-native-lab <kernel> <initfs> <private-ext4> <fresh-output> adaptive <probe>`
uses the existing portable `BoundedMemory.BalloonController` with this native HVF
backend. It does not start the stock container service or any host-network listener.
Only this finite trusted workload is admitted, with 1GiB boot RAM, 128MiB dynamic
capacity, a 512MiB guest reserve and 32MiB hysteresis. No second policy is introduced.

Every sample combines a single mutex observation of requested/plugged device bytes
with a fresh, sequenced guest MemAvailable reply. Captures use ContinuousClock;
setter delivery is fenced separately from later device convergence. The owner
quarantines late/invalid operations and the workload stops on critical/unknown host
pressure, stale samples, guest silence or failed convergence. Native sysctl pressure
levels restrict growth; admission still belongs to the external one-VM test harness.
The policy is driven at workload observation points, not an always-running service.

Two cycles check reclaim during an actual live ClickHouse query, followed by a real
320MiB guest allocation with an independent byte pattern. Low guest headroom must
cause bounded growth; the exact amount may be less than the dynamic capacity. The
allocation remains intact until growth completes, then Linux munmap releases it.
Both vCPU canaries, both private NICs, cgroup limits and the independent persisted
400K-row data oracle remain required. Each cycle validates its own capacity delta;
partial regrowth must not be mistaken for a failed full restore.

Logical capacity, anonymous mapping deallocation, observed resident/compressed pages
and the macOS task footprint ledger are different measurements. Global physical
free-list causality is unmeasured and remains null. This example has not qualified
production idle CPU/SLOs, arbitrary untrusted guests, multiple concurrent VMs,
cross-version configuration migration or host power-loss recovery.

`adaptive-busy` retains the diagnostic alias instead of releasing it. The expected
negative outcome is `completionTimedOut`, zero successful UNPLUG frees and clean
vCPU/coordinator join and VM destruction. It is not a successful workload run.

See [G24 native API qualification](NATIVE-API-QUALIFICATION.md) for the public
memory-control API, native quarantine repair, 17 profiles and crash recovery.

## Capacity contracts and large workload qualification

`NativeMemoryGovernor` retains full installed capacity unless the owner explicitly
provides `minimumResidentBytes`. That floor must include validated workload budgets
and guest overhead; geometry validation does not discover or certify cgroup budgets.
The earlier lab modes deliberately opt into their boot-only research floor.
Unsettled or below-floor admission preserves the VM's authority for a fresh
governor; a failure after admission still quarantines memory changes.
The stable-capacity `continuous-pressure-protected` control retains the original
application limits and observer interval. It has passed two large ClickHouse cycles
with no capacity changes or backing retirement; it is not a reclamation result.

See [pressure compatibility](PRESSURE-COMPATIBILITY.md) for the rejected large
autonomous-pressure attempts, protected control and separate physical backing
experiments. Neither a successful advice call nor a lower RSS establishes safe,
transparent physical RAM return for arbitrary workloads.
