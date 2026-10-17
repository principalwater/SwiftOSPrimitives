# Native memory-service ownership qualification

Trusted isolated macOS27/Swift6.4.1 research only. All five product gates remain
open; this does not enable product autonomy or admit untrusted workloads.

`NativeMemoryService` owns one fixed monitor per native VM boot. The caller lends
a read-only executable descriptor and supplies the digest from an authenticated
manifest. The owner duplicates it, reads a bounded immutable `pread` snapshot,
checks identity/timestamps, ELF64/AArch64 and SHA-256, uploads it, then releases
the local image after bootstrap. Guest text cannot select an artifact or command.

The service retains the qualified read-only root/proc, empty five capability
sets, no-new-privileges, PID/mount/IPC/UTS namespaces, 64MiB memory, eight PID and
64-FD limits. Actual `containerStatistics` must confirm memory/PID limits, bounded
nonzero usage, one process and zero OOMs before admission. A cgroup charge is not
VM RSS, host footprint or physical free RAM. Netns/seccomp and AF_VSOCK/control-
plane isolation remain separate open gates.

## Lifetime and deadlines

One retained task owns the entire bootstrap and one owns graceful shutdown.
An expired/cancelled phase can return while its actual RPC task remains owned.
Timeout/cancellation never means join. Startup records late PIDs and explicitly
closes late accepted FileHandles, including connections buffered before listener
finish. It never cancels the accepting task: the listener's AsyncStream buffers
handles that do not close on deallocation.

The internal socket wire duplicates three exclusively borrowed SOCK_STREAM
endpoints. Bounded nonblocking transactions reuse the existing ASCII output
parser; a short descriptor mutex prevents close/reuse races. There is no permanent
IO pump or idle polling. Only active write backpressure retries at2ms; outstanding
replies poll at5ms. Separate stderr is capped at2KiB and close errors are retained.
The public legacy lab channel initializer remains compatible.

Handshake/QUIT clips its five-second wire limit to the supplied absolute phase
deadline. First shutdown consumes live admission even if already expired; a
subsequent call cannot renew the budget, revive the service or replace the monitor.
The caller must stop and actually join its governor before monitor shutdown.

Graceful shutdown proves QUIT, exit0, wait, delete and clean unmount. `abort()`
revokes admission and closes known IO without claiming guest reaping. After
native stop joined every vCPU, `joinAfterNativeStop` joins the actual operations.
Whole-VM retirement never fabricates successful wait/delete/unmount. Full peak
capacity remains reserved until the host helper is actually reaped.

## Actual evidence

The wire suite passed122 release test declarations. The complete candidate
passed123 with warnings treated as errors (88.225091s including compilation).
Physical socketpair tests cover partial frames, real full-send-buffer deadline/
cancellation, original/duplicate lifetime, EOF, final QUIT ACK and native close.

Initial four fresh2-vCPU/zero-NIC/3GiB guest cases passed66.499644s. An additional
expired-shutdown regression then failed on the pre-fix owner with `expired
shutdown left live admission` (30.242575s). The failed case and native joins were
retained; the fix consumes stop admission before checking its expired deadline.
A strict compile caught a weak-var warning; Swift6.4 `weak let` preserves the ARC
assertion without suppressing diagnostics.

The corrected five-case matrix passed71.572491s on fresh VMs:

| Case | Checked outcome |
| --- | --- |
| Normal | READY/OBS/refresh/QUIT, wait/delete/unmount; duplicate start and second owner in the same VM boot refused |
| Cancel during upload | CancellationError closes admission; actual work is retained and joins after native stop |
| Original deadline | LifetimeExpired closes admission; actual work joins after native retirement |
| Wrong digest | Refused before upload; no live session escapes |
| Expired shutdown | DrainTimedOut consumes admission; later fresh-budget shutdown refused |

Every case proved zero pending operations after retirement, weak ARC owner
release, native/vCPU/NIO joins and unchanged original8GiB source hash/timestamps.
The frozen223-source host UUID is `45E5DA7A-3B50-35D7-A676-B97802ACF6C4`, SHA-256
`ebbdb855afde3e596a6b331fdb398a8ef6058dcd25a97867a9ff068c868eafdb`.
Unchanged guest SHA-256:
`c2c0e6e83bd68cd7863ba40408e80d0dfa9714cd756069a0cb5fc0bd844b6b22`.
Private results: `monitor-owner-complete-v2-{freeze,independent}.json`. The initial
relative-path launcher failure occurred before VM creation and was retained.

Product signed-bundle/helper and governor integration, global cross-process peak
reservations, compromised guest controls, wedged service fault injection, long
resource/security soaks, durable DB shutdown, autonomous RAM return, idle4-vCPU
budgets, upstream updates and Docker/Compose migration remain unqualified.
No production service or installed container was changed.

## Observation authority and review regressions — 2026-10-17

The managed service now returns a concrete `NativeMemoryObserver` from `session`.
It admits observations only; it exposes no handshake, quit or close authority. The
legacy `NativeMemorySession` initializer and lifecycle remain public for their real
standalone owners. Both native governors consume the observation capability, and
all lab callers use it. An owned terminal observation revokes live admission; its
actual operation remains counted until completion and is joined after native stop.
Graceful shutdown waits for any admitted observation inside the original drain
budget. No idle IO pump or respawn was added.

An external compiler consumer proved the old getter accepted all three unwanted
lifecycle calls. The repaired getter rejects each with a no-member diagnostic;
positive observation and actual legacy-owner consumers still compile. These were
actual Swift6.4.1 typechecks, not source-string assertions.

The already-cancelled shutdown regression failed on the old owner in37.851135s:
its live admission remained available. The repair consumes the stopping phase
before checking cancellation and starts no shutdown RPC for an already-cancelled
caller. A later call cannot renew the cancelled stop. Reply sleeps are clipped to
the original deadline; phase errors remain distinct from expiration. Join failures
and truncated cleanup histories remain visible. Extra buffered stdio connections
are closed and cause bootstrap refusal rather than silently becoming live.

The final candidate passed123 release tests with warnings as errors (91.646783s
including compilation). Eight fresh2-vCPU/zero-NIC/3GiB VM cases passed107.489250s:
normal, cancel during upload, cancel after listener registration at create-requested,
original deadline, wrong digest, expired shutdown, already-cancelled shutdown, and
a stopped monitor. The last case uses `Signal.Linux.stop`, not Darwin's differently
numbered SIGSTOP, and proves wire timeout, revoked admission and forced VM retirement.
Signal acceptance and missed reply were observed; Linux process state was not read.

Every case retained actual VM/vCPU/NIO joins, zero pending operations, weak ARC
release and four final open descriptors. A count is supporting lifetime evidence,
not an exhaustive descriptor-identity proof. Original8GiB content and metadata were
unchanged. Frozen224-source host UUID `92114CAD-7CBE-3B1A-84AC-72E1AAC3EB7B`, SHA-256
`3f2a16894cb7bfdc84e13085d63a08c878390e85bf4bea79464dab51abff89cc`.
The monitor digest above is unchanged. Private receipts:
`monitor-owner-observer-v6-{freeze,independent}.json`.

Retained failed harness attempts are not acceptance: an invalid descriptor-census
bound after retirement, a freeze-receipt filename collision before VM admission,
and use of Darwin's signal number in the Linux fault case. They were corrected
without relaxing limits. These results do not qualify autonomous RAM return,
application integration, hostile guests or any complete production gate.
