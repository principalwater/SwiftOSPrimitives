# Dedicated guest memory monitor — experimental qualification

This slice separates memory observation from workload diagnostics. All five
product gates remain open. It does not enable product autonomy, install a
service, change an installed container engine or claim physical free-list credit.

## Native implementation

`NativeGuestMemory` has no Foundation, HTTP, canary, concurrency or Dispatch
requirement. It uses bounded native procfs reads, complete writes with EINTR
handling and printable ASCII requests capped at 64 bytes including the newline.
Exactly one MemTotal and MemAvailable field is required; malformed values,
duplicates, integer overflow and availability above total are refused. READY is
withheld until an initial `stat_refresh` read and snapshot succeed. OBS_REFRESH
refreshes before sampling. EOF between requests exits normally; partial EOF,
wrong sequence, unknown commands and malformed bytes fail closed.

Both the dedicated `container-memory-monitor` executable and the existing
`container-memory-probe --memory-monitor` use the same implementation. The latter
still owns its diagnostic features; none is linked into the standalone monitor.

The static aarch64 Musl build uses Swift 6.4.1. Its stripped ELF is 6,536,152 bytes,
SHA-256 `4767848922acf157a4edc738b01cfa098bde1d077f178f4e7f1db2ef3c7501f8`,
Build ID `84081fd11021b837771ae4124846d19f402f8817`. This is file size, not RSS.
The host parser/protocol tests run on macOS; Linux syscalls are qualified below.

The new consumer resolution pins swift-crypto 4.5.2 instead of the earlier 3.15.1.
These new lifecycle receipts do not transfer earlier workload/balloon measurements
across dependency versions. The complete lockfile is retained with each artifact.

## Why a service container

The pinned vminitd server explicitly refuses a missing containerID. The public
client signature accepting an optional value is not capability evidence. Actual
Linux RPCs confirmed the refusal on every fresh test VM. No guest-root execution
API or upstream root-process patch was added.

The finite `monitor-service` lab consumer creates a separate trusted OCI service,
with its own PID/mount/IPC/UTS namespaces and cgroup, no NIC, a private 16 MiB tmpfs
root, no application disk/share, read-only root and `/proc/sys`, uid/gid 0, empty
capability sets, no-new-privileges, NOFILE 64, CORE 0, memory.max 64 MiB and pids.max
8. These are the supplied policies. Individual enforcement, exact fd inventory,
OOM priority and peak cgroup accounting are not all independently qualified.
There is no network-namespace or seccomp claim: vmexec does not enforce them.

One reserved port block below the workload allocator is used once per VM boot.
The artifact is bounded to 16 MiB, opened without following a symlink, read once,
checked against the caller's explicit digest, and uploaded in 64 KiB chunks.
Normal flow validates READY, OBS, OBS_REFRESH and QUIT, then waits, deletes,
closes stdio/listeners, detaches the tmpfs and stops/joins the native VM and NIO.

This consumer is deliberately **not** the production process owner. A hung setup
RPC still relies on the unchanged 120-second native qualification fence and outer
process retirement. Product admission needs an independent bounded owner inside
its existing boot21, drain8, native-stop10/join4 and parent25 budgets.

## Executed evidence

The complete native release suite passed 111 declarations with parameter cases
and warnings as errors. After the SIGKILL expectation repair it passed again in
90.305 seconds; the final formatting-only build and five guest parser declarations
passed in 52.746 seconds. Earlier default-T7-TMPDIR ownership-test failures were
harness misconfiguration: OwnersDisabled is correctly refused. These tests require
`SWIFTOS_BOOT_TEST_ROOT` on the private OwnersOn APFS fixture. No guard was relaxed.

Two fresh 2-vCPU / 3-GiB / zero-NIC native VM boots independently passed normal
service setup, root-process refusal, READY/OBS/REFRESH/QUIT, exit 0, wait/delete,
stdio/listener retirement and all native vCPU/VM/NIO joins (53.409 seconds outer).
The monitor reports global MemTotal 3,140,882,432 bytes, not its 64 MiB cgroup limit.

The same static ELF then passed these actual fault cases on a fresh VM each:

| Input or action | Observed contract |
| --- | --- |
| Normal transaction | Three exact replies, QUIT acknowledgement, exit 0 |
| Wrong sequence | No reply, framing diagnostic, exit 1 |
| stdin EOF after READY | No extra output, exit 0 |
| stdin EOF inside a command | No reply, framing diagnostic, exit 1 |
| uid/gid 65534, executable/searchable fixture | No READY, stat_refresh EACCES, exit 1 |
| Ancestor SIGKILL | Exit 137, actual wait followed by delete |
| 64 non-newline bytes | Bounded framing refusal, exit 1 |
| CR control byte | Bounded framing refusal, exit 1 |

Every accepted case completed native teardown and preserved the original whole
8 GiB disk SHA-256 and metadata plus kernel/initfs hashes. No OOM or host physical
RAM-return conclusion follows from these small lifecycle tests.

The first SIGKILL harness expected the raw signal number 9 and failed on 137.
`ContainerizationOS.Command.toExitStatus` intentionally reports 128 + signal;
that expectation alone was repaired. Its failed receipt is retained. Normal,
sequence and EOF cases passed on host artifact 2460BD48-FC53-36A6-AB00-AC9D71B13447;
nonroot passed there too. Kill, size and control-byte cases passed on corrected
host BD945377-BA22-39F2-8DE3-1C8619B60346. The guest ELF is identical throughout.

## Review and remaining acceptance

Exact Claude Opus 5.5 with max effort returned the tool-free correction review in
1204.077 seconds under the original 5400-second timeout. Its recommendation agrees
with the actual service-container result and withdraws the nil-container route.
Only its public answer and public outcome metadata were inspected.

Before product adoption, implement and qualify confinement self-checks before
READY, narrower read-only proc paths, measured cgroup/pid limits, no extra open fds
and runtime threads, non-dumpable operation where supported, and workload admission
only after a live monitor owns its established channels. Test lifecycle cancellation,
partial creation, unexpected EOF/exit, reader/wait races, no in-boot respawn or port
reuse, exact deadline/reap ownership, cgroup OOM accounting and longer fd/thread
soaks. Do not replace the parent's independent EOF exit 125 with RPC cleanup.

The review's blanket ban on owned Tasks or a source-grep test is not adopted:
real bounded ownership and joining are the contract. Noncooperative RPC cancellation
must be resolved by native VM stop and tracked through actual completion; a
structured group's cancellation alone is not evidence of bounded teardown.
Canonical-spec semantic tests must exercise the real policy, not copy a fixture
that supplies the answer. PhysicalReleasedBytes remains null.

Kernel source reference: [stat_refresh documentation](https://docs.kernel.org/admin-guide/sysctl/vm.html#stat-refresh).

## Host memory-session EOF and canonical framing repair

The host session now refuses already-closed transports for READY and live
observations, even if a syntactically valid line was buffered before EOF. Generic
stream consumers keep their normal final-frame draining; QUIT alone may accept
its exact final acknowledgement followed by EOF. This closes known-dead telemetry
without confusing orderly process exit with a fresh liveness observation.

READY and MEMORY_OK must match their canonical decimal rendering exactly: extra
spaces, trailing spaces and leading zeros are refused. Completion must still be
inside the original host deadline after parsing; cancellation and failure retire
the command stream rather than consuming a later reply.

The BEFORE release run failed on buffered EOF and three malformed forms in each
frame family (14 issues, retained raw log); its valid QUIT+EOF control passed.
After the shared repair the six selected declarations and parameter cases passed
in 99.711 seconds including compilation. The complete release suite then passed
114 declarations in 23.178 seconds (18.126 seconds actual tests), zero warnings
or errors. The collector has no validated Swift Testing event mapping for this
toolchain, so the retained raw log is the test evidence. No memory ownership or
RAM reclamation API changed. Actual service-owner integration remains open.
