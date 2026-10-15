# Apple Container1.5.0: native memory-control integration

Research snapshot:2026-10-15, Swift6.4.1, macOS27.0.1/SDK27, Apple M2 Max.
This is the optional `Examples/AppleContainerMemoryLab` package. It follows
[the portable balloon controller](AppleContainerBallooning.md), preserving its
ownership, reserve, completion fences and no-host-credit rules.

## Actual release boundary

[Apple Container1.5.0](https://github.com/apple/container/releases/tag/1.5.0)
is the latest stable release checked at this snapshot, commit
`d265d669ecae041bf338cb3b39c4118316d138f0`. Its dependency is exactly
[Containerization0.47.0](https://github.com/apple/containerization/tree/bc994b88df46207fad7775b0eabc51947e315881).
The signed installer was signature/notarization checked, expanded into an owned
workspace and version queried; it was not installed.

The lab uses the actual release's `LinuxContainer`, `VZVirtualMachineManager`,
`vminitd`, OCI configuration, stock vmexec, cgroup and IO lifecycle. It does not
substitute a direct VZ-only VM for Container integration. It also does not patch
or start the stock Container CLI/API service. That service creates default vmnet
state and uses common Mach labels; starting it would violate this lab's isolation.
Opt-in runc/seccomp is not enabled, and no such security claim is made.

The official release's default ARM64 debug kernel is the Kata3.32.0 member
`opt/kata/share/kata-containers/vmlinux-6.18.35-197-debug`, SHA256
`fb2cfb79eb1ae19447a85d75682d7fa5cfec97e24beb2609a492b806e8072c8d`.
Resolved official image digests in the tested private ImageStore are:

| Input | Digest |
|---|---|
|vminit:0.47.0|sha256:4c1836052eafcbc944c403fb23ded06562962d2402c9dcc651495a32300614df|
|alpine:3.22.1|sha256:4bcff63911fcb4448bd4fdacec207030997caf25e9bea4045fa6c8c44de311d1|

These identify downloaded OCI content, not an independent reproducible-build
attestation for upstream binaries. Runtime rootfs copies, initfs, ImageStore,
kernel, probe share, logs and result directories belong only to the fresh lab.
`ImageStore.default`/`ContainerManager` default state is never used.

## Small native extension

`AppleContainerMemory.ContainerBalloonDevice` implements the release's public
`VZInstanceExtension`. It adds exactly one traditional balloon before native VM
validation, refuses an existing device or reused epoch, records the configured
ceiling and binds the resulting instance weakly. The manager decorator appends
this extension last without re-deriving storage, networking or workload mounts.

Requests execute on the instance's actual VZ queue, use raw queue-native state,
validate the explicit owner floor, ceiling and alignment, set the target and check exact getter readback.
The setter and retirement share a Mutex through the native write: when `retire()`
returns, an already admitted write has finished and later queued writes must
refuse. The queue callback resumes its continuation exactly once. No queue.sync
backed wrapper state is queried inside that queue. Cancellation closes only this
request's admission; the outer serial owner still retires and joins transport.

The adapter is a request channel, not a second policy controller or a physical
memory authority. One serial owner uses the noncopyable `BalloonController` and
one fresh device per VM epoch. Setter return alone never completes a request.
Completion requires a later query, captured after delivery, whose BOTH requested
and actual PFNs match. Native observations, delivery times and sequence fences
are retained in result JSON. There is no per-domain/fleet allocator or background
service in these products.

## Workload and diagnostic privileges

One VM has1vCPU,512MiB and zero NICs; the native configuration hook asserts this.
A stack-local strong VM reference verifies the actual stopped state; nil weak binding
cannot certify stop. The full512MiB logical grant remains held until an awaited stop. A single
128MiB-cgroup workload retains stock capabilities and `no_new_privs`. It verifies
memory.max, absence of RAWIO/SYS_ADMIN, absence of /dev/mem and refusal to open the
read-only probe share for writing. Its immutable static Swift ELF is mounted read-only.

The stock vminitd explicitly rejects root-VM `createProcess` calls. The lab uses
supported `LinuxContainer.exec` instead of bypassing that guard. Only this trusted
diagnostic exec adds SYS_RAWIO and SYS_ADMIN. Linux restricts PCI config reads
beyond64 bytes using SYS_ADMIN in
[pci_read_config](https://github.com/torvalds/linux/blob/v6.18/drivers/pci/pci-sysfs.c).
The diagnostic performs bounded, read-only volatile balloon config reads; it never
writes queues, ISR, driver ownership or arbitrary guest memory. Its scratch region
is one page and refuses workload touch/erase commands; an independent8MiB canary
remains checked. This avoids materializing an unnecessary64MiB region at cleanup.

This privileged diagnostic shares the container's namespaces/cgroup. Consequently
the test qualifies trusted synthetic workloads only. It does not prove hostile
workload isolation, AF_VSOCK access control or safe production deployment of this
diagnostic. A production design needs a narrowly privileged guest telemetry API;
granting these capabilities to ordinary client workloads is not the solution.

Runtime-owned exec/stdin/stdout listeners and port allocation are reused. New
custom raw-vsock/FD plumbing was deleted after the actual API limitation was found.
The serial host framing validates bounded ASCII lines, sequence, driver identity,
counts and observation age, and allows only one command queued. The total output
budget is1MiB, pending buffer16KiB, line8KiB and command count1000. A malformed
or timed-out response terminates the experiment; it is never resynchronized into
an accepted observation.

## Native cycle and controls

The current workload touches, verifies, erases, discards and reuses an88MiB mapping
(22528 guest4KiB pages). Its explicit allocation cap remains88MiB; the library's
default64MiB guard is unchanged. Both workload and diagnostic check independent
8MiB canaries. Policy uses a256MiB allowance floor,64MiB maximum step,128MiB guest
reserve,16MiB hysteresis,100ms cooldown and5s completion deadline. Observation
capture uses the earliest host ContinuousClock instant for the query. The input
scanner bounds regular-file reads, refuses symlinks/nonregular inputs and hashes
the ELF and pinned kernel before/after stop; these are trusted-workspace identity
checks, not a hostile-writer hash-then-open guarantee. Results cannot live inside
the shared directory. Marker/metadata reads are bounded; OCI digests are compared
and Containerization is pinned by commit, rather than relying on tag immutability.

One observed native free/load/free trace requested:
`512 → 448 → 384 → 320 → 279 → 313 → 256 MiB`.
The runtime process returned0 in2.27295s, both guest processes exited0 and VM stop
was awaited. The88MiB mapping changed22528→0 resident pages; workload RSS changed
102993920→10719232bytes on the final erase/discard. These are guest counters,
not host VZ backing counters or a controller latency/Rust benchmark.

Additional actual native controls passed: held target/no writes, absent device,
driver-init blacklisted/ignored request with sticky timeout, and cancellation
only after a completed shrink. Each stopped its VM and reported no cleanup error.
Passive before/after snapshots for those controls preserved interface names,
existing Container-related jobs and installed Container state-root metadata.

Early failed runs are retained separately: unsupported root-VM API, insufficient
diagnostic PCI capability, a64MiB workload that never crossed the reserve, and an
88MiB request initially refused by the library's unchanged default allocation cap.
None is counted as a pass. Phase acceptance now waits for its actual shrink/grow
reaction within the existing finite bound; two idle samples alone cannot certify
that Linux has published delayed MemAvailable changes.

The owner retires device admission before teardown, runs cleanup in an owned and
awaited task independent of caller cancellation, joins diagnostic IO/process state,
finishes the workload, stops LinuxContainer/VM, then shuts down its explicit
two-thread NIO group. It preserves primary and cleanup errors independently.
This finite lab always stops on failure; it does not rotate into a persistent
shrunken VM. Future persistent reuse requires restore/settle and a new epoch.

## Physical host memory remains a separate gate

The release [technical overview](https://github.com/apple/container/blob/d265d669ecae041bf338cb3b39c4118316d138f0/docs/technical-overview.md)
still documents that freed guest pages are not returned to the host. This adapter
does not claim to remove that platform limitation. `physicalReleasedBytes` stays
null; TASK_VM_INFO/RSS observations refer only to the controlling process.
The public VZ API supplies no verified exact helper/backing identity or physical
release completion authority in this lab. No grant is lent to another VM based on
guest counts, aggregate host free memory or a guessed helper PID.

Native Mach reclamation of exclusively owned PageRegion pages is independently
implemented and tested in [Native host reclamation](NativeHostReclamation.md).
Those rights do not extend to another service's VZ-owned mappings. Assembly cannot
create that ownership. No custom hypervisor/kernel backend, stock-service rollout,
host pressure test or production Macray adoption is included in this experiment.

## G14 baseline validation and remaining qualification

The final owner was strengthened after actual Opus5.5 and Sonnet5.5 reviews:
explicit native floor, strong local stop observation, mandatory executed cancel
control, no fallible host snapshot after NIO allocation, bounded input hashes/pins
and nested-output refusal. The extension's VM binding remains weak.

Local final evidence: seven release and seven AddressSanitizer host tests passed;
60 portable root release tests and38 ownership compiler consumers passed; the
fresh static Swift6.4.1 Linux guest also passed the previous four-cycle boot
protocol. Five argument-admission controls refused before creating output/VM:
nested output, wrong kernel, wrong image pins, oversized ELF and symlinked ELF.
Final reviewed policy/held/absent/ignored/cancel native runs all returned0 with
strong stopped-state observations and independent timestamp/PFN fence replay.
One reviewed trace was512→448→384→320→282→278→311→256MiB; its final workload RSS
was102981632→10711040bytes. Guest image data and canaries remained intact.

The optional CI gate builds/tests the host adapter on macOS; it never boots a VM
or starts the stock service. Native SwiftPM reports a backend deprecation warning;
compiler warnings remain errors. The local axbuild tool has no validated Swift6.4.1
Testing event mapping: raw native logs show the passes, while collection is labeled
partial rather than inventing complete test-event evidence.

The reviews were design/earlier-source opinions, reconciled against the actual
final source and native results; they are not final-binary author approvals. A
paused/dead guest can leave a graceful RPC waiting, so the external180s owned
process watchdog is mandatory. All selected normal/ignored/cancel paths joined;
all-await cancellation injection, kernel-wedge forced recovery, OOM auto-deflate,
host-pressure lending and hostile-container isolation remain unqualified. This
research lab is not an unattended production memory manager.

## G15 native recovery and real workload extension

The current [ClickHouse qualification](ClickHouseMemoryLab.md) adds the native
retireAndStop capability,10release host tests, real paused/paused+cancel teardown
and a pinned official ClickHouse server workload. The finite paused cases now
verify raw stopped state, wake response readers after stop, retain every cleanup
stage error and require successful NIO shutdown. Seven controller modes and both
held/adaptive database modes pass. This extends the G14 evidence above; its seven
ASan tests are historical, not a claim that the new source was ASan-tested.

Physical VZ host release, a real dead-kernel panic control, every-await faults and
persistent in-process reuse remain unqualified. The stock kernel has no SysRq;
the attempted panic injection refused and is retained as failure. Current upstream
VZInstance.stop checks running state before the only TimeSyncer.close, leaving a
public cleanup gap after raw stop. A separately reviewed upstream Swift lifecycle
patch or a supervised process-per-epoch boundary is needed before persistent use.
No production rollout or stock global service change is implied.
