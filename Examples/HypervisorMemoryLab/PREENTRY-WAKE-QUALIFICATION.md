# Pre-entry cancellation latching experiment (macOS27 research)

This is a bounded research experiment. It is not an optimization, an adoption decision or a
qualification. The production CPUGroup keeps its 2ms forced-exit cadence until hardware wake
semantics and complete IO/control wake registration are qualified, and all five product gates
remain OPEN. The protocol below was proposed before execution; the actual parent qualification
and its narrow result are recorded next.

## Executed parent qualification

On the Mac Studio/M2Max, macOS27.0.1/Swift6.4.1, the exact signed candidate passed
the two-trial experiment and independent raw-result validator in0.669537s. The
control executed the HVC marker. With a successful pre-entry kick, the first run
returned CANCELED with the entry PC/X0 unchanged; the follow-on reached the HVC.
Both vCPU destroys, pthread joins and VM destroys succeeded. Reusing the output
path was refused without changing its bytes; the child was actually reaped.

The result is **pre-entry cancellation latched on this one tested instance**.
It does not prove between-run/WFI/SMP/device wake semantics or idle CPU savings.
The main CPUGroup remains unchanged. No Linux kernel or disk was used.

Frozen host UUID: `419DC6FB-FCE9-380C-B9CA-76A15265C27F`; SHA-256:
`8c1ac6b58679a4b85de5e5076beec22cb40f8a650cdf785a8cd49d3da1742548`.
Private artifacts retain `hvf-preentry-v1-{freeze,native,independent}.json` and
an exact source/symbol snapshot. The qualified source was built in an isolated
worktree; root Package.swift/all Sources were independently byte-equal before
import into the main research checkout.

The initial manifest resolution failed because a worktree folder had a different
package identity; naming the local dependency explicitly fixed it. A subsequent
strict compile exposed optional-native-result comparisons; explicit unwrapping
fixed those without changing the test's acceptance criteria. Both failed builds
were retained; the final warnings-as-errors build passed4.472008s.

## Question

Does `hv_vcpus_exit`, completed on a vCPU that exists but is not inside `hv_vcpu_run`, cancel
the **first** `hv_vcpu_run` before the guest executes any instruction (a latched pre-entry
cancellation)? Or does the first entry run the guest to its HVC (no latching)? Both outcomes
are valid findings and are reported as observed; neither is a pass or a failure of the
experiment. Only a first run that is cancelled with PC and X0 unchanged counts as latching.

## Invocation

```sh
hvf-memory-lab preentry-wake <new-output.json>
```

Exactly two arguments. No guest image, Linux kernel, initramfs or root disk is read and no
Linux VM starts; the existing four-argument modes are unchanged. The binary is built, signed
with `hypervisor.entitlements` and strict-verified exactly as in `README.md`; the Embedded
guest image from that README is not needed for this mode. Keep an external watchdog: the
internal 5s host deadline covers every wait, but `hv_vm_create`, `hv_vm_destroy` and
`pthread_join` are kernel calls that cannot be bounded from inside the process.

The output path must not exist in any form (file, directory, symlink, dangling symlink). It is
created before any Hypervisor call with `O_CREAT|O_EXCL|O_NOFOLLOW`, mode 0600, so a refused
path touches no VM. The JSON is written once at the end and is limited to 64KiB. A process
killed before that point leaves an empty file, which means no evidence.

Exit status: `0` means a determinate finding (latched or not latched) with both controls and
all cleanup valid; stdout is `HVF_PREENTRY_WAKE_COMPLETE latched=<bool>`. `1` means a refused
output path (nothing is written) or an invalid trial or indeterminate finding
(`HVF_LAB_FAIL ...`, evidence written). `2` means native process retirement
(`HVF_PREENTRY_RETIRE ...`); evidence is written first, and a failed write is reported as
`HVF_PREENTRY_EVIDENCE_FAIL` before the retirement.

## Protocol

Two independent trials run in one process. Each has its own `Machine`, `hv_vm_create`,
worker thread, vCPU and `Machine.close()` (unmap, deallocate, `hv_vm_destroy`); trial 2 starts
only after trial 1 left no VM and no unverified thread.

1. `no-pre-entry-kick-control`: the worker publishes its vCPU identifier and waits on a host
   gate. The parent releases the gate without calling `hv_vcpus_exit`. The first run must
   reach the guest HVC with the expected marker and PC. This is the positive control.
2. `pre-entry-kick`: identical, except that the parent calls `hv_vcpus_exit(id, 1)` with the
   published identifier, records its return code, and only then releases the gate.

Guest fixture (two ARM64 words at guest address `0x100000`, one 16KiB page, remainder zero):
`movz x0, #0x5ea7` (`0xd28bd4e0`), `hvc #0` (`0xd4000002`). The page follows the reviewed
lab sequence: RW while loading, `sys_icache_invalidate`, `hv_vm_protect` R+X before any vCPU
exists, host alias read-only, instruction-word read-back. Entry state is PC=`0x100000`,
CPSR=`0x3c5`, X0=`0xa5a50000_00000001`, each read back from the vCPU and compared. The
virtual timer is masked as in the existing lab. After an HVC exit HVF reports the PC after the
HVC (`LinuxMachine.swift` already relies on this), so the expected exit PC is `0x100008`.

No vCPU call separates the parent's kick from the first `hv_vcpu_run`. The worker only waits
on a semaphore, records host-side events and then runs.

## Synchronization and lifetime contract

- One worker thread created with `pthread_create` owns `hv_vcpu_create`, register access,
  `hv_vcpu_run`, `hv_vcpu_destroy` and exit-record reads. The parent crosses only
  `hv_vcpus_exit` with the identifier the worker published, and only in trial 2 before the gate.
- The vCPU exit record and vCPU never leave the worker; the parent reads plain values under one
  mutex. No native call is made while the mutex is held. No pthread cancellation, `defer`
  cleanup, sleeps or timing guesses are used.
- One absolute deadline (`DispatchTime.now() + 5s`) is computed once. Publication wait, the
  worker's gate wait and the finished wait all use that same instant; no wait renews it.
- Latching is derived from the first run's exit reason, PC and X0 plus recorded event order
  (`published < kick-begin < kick-returned < gate-release < gate-passed < run-begin`, by
  sequence number). No timestamps are recorded.
- `Machine.running` is set before the thread starts and cleared only after `pthread_join`
  returned 0. `Machine.close()` refuses to run while it is set, so guest mappings cannot be
  released under a CPU that may still run. The worker destroys its vCPU on its own thread
  and the parent proceeds only if that destroy returned success.
- If a wait times out, the vCPU destroy is unconfirmed or `pthread_join` fails, the process is
  retired: evidence is written, nothing is unmapped, and `_exit(2)` lets process exit retire the
  native objects. A VM whose creation failed is never destroyed.
- A cancellation seen before any guest instruction leads to at most two follow-on runs (three
  runs in total), recorded separately with `phase: "follow-on"`. Nothing else is re-run.

## Evidence (schema 1)

Top level: `mode`, `schema`, `scope`, `hostDeadlineSeconds`, `hostDeadlineExpired`, `fixture`
(`instructionWords`, `disassembly`, `guestCodeAddress`, `codeBytes`, `entryCPSR`,
`entrySentinelX0`, `markerX0`, `expectedExitPC`, `codeSetup`), `trials`,
`secondTrialSkippedReason`, `finding`, `processRetired`, `notExecuted`.

`finding`: `determinate`, `preEntryCancellationLatched` (`true`, `false` or `null`),
`firstRunAfterPreEntryKick` (run class or `null`), `summary`.

Each trial: `name`, `preEntryKickRequested`, `valid`, `invalidReasons`,
`processRetirementReason`, `parentError`, `vmCreateCode`, `vmDestroyedByApi`,
`vcpuCreateCode`, `vcpuIdentifier`, `setupFailure`, `entryReadbacks` (register, expected,
observed), `parentHvVcpusExitIssued`, `parentHvVcpusExitCode`, `workerGate`, `ordering`
(event sequence numbers and `kickReturnedBeforeGateRelease` / `kickReturnedBeforeFirstRunBegin`),
`runs`, `vcpuDestroyCode`, `pthreadJoinCode`, `cleanupErrors`, `events` (sequence, side, step,
native code). Native codes are signed 32-bit decimals (`0` is `HV_SUCCESS`); registers are
unpadded hex strings.

Each run: `index`, `phase`, `nativeRunCode`, `classification`, `beginSequence`,
`returnSequence`, `registerReadCodes`, `pc`, `x0`, and for successful runs `exitReason`,
`exitReasonRaw` plus, for exception exits, `syndrome`, `exceptionClass`, `hvcImmediate`.

| `classification` | Meaning |
| --- | --- |
| `guest-hvc-marker` | Exception exit, class `0x16`, immediate 0, X0 `0x5ea7`, PC `0x100008` |
| `canceled-before-guest-instruction` | `HV_EXIT_REASON_CANCELED`, PC `0x100000`, X0 unchanged |
| `canceled-after-guest-progress` | Cancelled, but PC or X0 changed |
| `unexpected-exit` | Any other exit |
| `register-observation-failed` | Run returned but a register read failed |
| `run-failed` | `hv_vcpu_run` returned an error |

| Control | Kick trial first run | `finding` |
| --- | --- | --- |
| valid, `guest-hvc-marker` | `canceled-before-guest-instruction`, follow-on reaches the guest | latched `true` |
| valid, `guest-hvc-marker` | `guest-hvc-marker` | latched `false` |
| anything else | anything else | `determinate: false`, latched `null`, exit 1 |

## Limits

One hardware and OS instance, one pair of single-vCPU trials: this is an observation, not a
distribution. Repeating the command is the parent's decision. Only a vCPU that was created and
never run is exercised; a kick issued between two runs, during a run, or while the guest is in
WFI is not. No SMP, concurrent teardown, device or IO wake, timer wake, 4-vCPU idle savings,
CPU-time measurement or production readiness is claimed or implied. A not-latched finding says
only that the first entry was not cancelled; it does not show whether the kick is retained for
a later entry. The experiment does not change or justify the CPUGroup cadence.

## Original assumptions and remaining scope

The worker's first draft was source-only. The parent's execution above now confirms
the proposed PC/CPSR readback, sequential VM creation/destruction and accepted
pre-entry kick on this tested instance. Any different native behavior still fails
visibly in `invalidReasons`. WFI/between-run wake, SMP, concurrent teardown, device
and timer wake, idle savings, Linux and production adoption were not exercised.

## Parent review checklist

- Build with `-Xswiftc -warnings-as-errors` and review any Swift 6 isolation diagnostics around
  `Mutex`, the `@convention(c)` thread entry and `Unmanaged`.
- Sign the frozen copy, strict-verify it and run under an external watchdog with an absent
  result path; confirm a second run with the same path is refused.
- Check `entryReadbacks`, `ordering`, every `runs` entry and both `pthreadJoinCode` /
  `vcpuDestroyCode` values before reading `finding`; keep negative evidence.
- Verify independently that no `hvf-memory-lab` process remains after exit codes `1` or `2`.
