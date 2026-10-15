# Apple Container balloon policy: a bounded Swift controller

Research snapshot: 2026-10-15, Swift 6.4.1, macOS 27.0.1 / SDK 27, Apple M2 Max.
This follows the separate Apple Container feasibility research without changing
an installed container service, Macray, a production network or a VPS.

## What exists and what this adds

Apple Container already creates one lightweight Linux VM per container through
Containerization/Virtualization.framework. A balloon is an existing native device,
not a missing Swift syscall wrapper. The current [technical overview](https://github.com/apple/container/blob/22029b06867e46baf77b3404b849f4491739da3b/docs/technical-overview.md)
explicitly documents partial balloon support: freed guest pages are not returned
to the host. The maintainer also identifies a macOS-side change in
[Containerization issue 65](https://github.com/apple/containerization/issues/65#issuecomment-3293475472).
A policy can manage guest allowance today; it cannot remove that platform limit.

`BoundedMemory.BalloonController` adds the portable planning part. It reuses
`BalloonBudget` and has no imports, allocation-owning collection, background task,
timer or IO. It is noncopyable and uses typed errors. An actual Embedded Swift
consumer compiles with `-no-allocations` and runs 1000 shrink/grow cycles plus
silence/retirement controls. Hosted tests exercise additional refusal paths.
This is not an allocation or RSS guarantee for a whole hosted Swift application.

The controller emits one request at a time from authenticated guest observations:

- preserve a guest reserve and a hysteresis band, with a bounded step and cooldown;
- grow urgently within an absolute, already reserved per-VM host allowance cap;
- validate geometry, epoch, sequence, observation age and monotonic clock;
- recognize partial 4KiB device progress under coarser request granules;
- fence completion after the matching setter has returned and after every query
  sent before that return, including replies queued but not yet parsed;
- require BOTH requested and actual device counts to reach the exact target;
- restore the previous reserved allowance once if an applied shrink endangers the
  guest; quarantine unknown delivery, cap revocation or conflicting pressure;
- expire an operation even when no observation arrives, and keep its request and
  first terminal reason for diagnosis after retirement.

There is no lock, actor or internal scheduler. One serial owner supplies a common
host-monotonic time domain including sleep, owns transport, and joins cleanup.
`retire()` does not cancel IO, stop a VM or prove DMA/transport quiescence. Drain
and retire the epoch before pausing a VM or changing its backing/transport.

## Logical allowance is not resident host RAM

For this traditional balloon, the adapter converts both device counts as:
`allowance = installedBytes - PFNs * 4096`. Fields named `actualResidentBytes`
and `requestedResidentBytes` use this logical allowance convention; they are
neither host RSS nor Linux MemTotal. Linux MemAvailable is an estimate, not a
memory reservation or an OOM guarantee.

`hostResidentLimitBytes` is an absolute per-VM grant held by the owner. Supplying
raw host free memory or replenishing the grant from a completed shrink would
spend unproven savings. The controller never issues physical-release credit.
Host-pressure and guest-pressure signals are caller inputs, not a fleet allocator.

The SDK 27 public traditional balloon setter is request-only, 1MiB-granular and
bounded by the native minimum and boot-time memory size. A guest may ignore it.
No inspected public VZ header exposes an exact helper PID/audit identity,
backing-residency counter or physical-release completion callback. Consequently,
this lab records `physicalReleasedBytes: null` and labels TASK_VM_INFO counters
as the controller process only. Native Mach operations on our own PageRegion
remain a separate, valid ownership boundary; they do not authorize access to a
VZ helper's pages. An assembly instruction cannot manufacture that authority.

## Actual native policy experiment

One disposable VM: 1vCPU, 256MiB, no NIC, disk, share or vsock. Its current static
Swift guest owns a 64MiB touched/erased/reused region and an 8MiB canary. The host
uses a 192MiB floor, 32MiB maximum step, 96MiB reserve and 16MiB hysteresis. A fixed
256MiB cap is held for the entire experiment; no host pressure is induced.

On the observed free/load/free sequence the six confirmed requests were:

| Initial allowance MiB | Target MiB | Guest available bytes at decision |
|---:|---:|---:|
|256|224|186200064|
|224|192|152608768|
|192|224|79917056|
|224|251|88764416|
|251|219|183439360|
|219|192|173670400|

The process returned 0 in 2.160203875s; the experiment itself took 2.082607708s,
with 22 fresh observations, verified 64MiB data reuse, a final restore and an awaited
clean stop. The native control loop observes on 100ms intervals in this fixture;
these elapsed times are not a controller latency benchmark or a Rust comparison.
The legacy `reductionRequestedBytes` result field describes the fixed-cycle lab
parameter; `policyRequests` records the actual policy targets.

Inputs: Linux 6.18.35 ARM64 Image SHA256
`f437320bab94f19105d12b932aa29735f0d54d2588218872254367f312c1027c`,
fresh current-protocol initramfs SHA256
`f392063274961f0264a13833597785ea3644409c06c52fc49d19746f3f4ac614`.
The existing Embedded Swift bootstrap was retained; the hosted guest was freshly
built with the official Swift 6.4.1 static Linux SDK. Both inputs stay immutable
through the run. Raw console, result JSON, invocation outcomes and hashes are
retained outside Git.

An initial run selected a historical four-field handshake fixture. The current
host refused framing BEFORE any balloon request, awaited stop and returned 1.
The fixture and failure are retained; the handshake was not weakened. This is
an input-selection failure, not a passing negative or policy acceptance.

## Validation of this slice

- Root Release and AddressSanitizer: 60 tests in 7 suites passed in each run;
  raw Swift Testing output is authoritative. axbuild collection was partial
  because Swift 6.4.1 events are not mapped by that installed collector.
- 38 compiler contracts passed, including a valid controller consumer and the
  compiler's refusal to copy the noncopyable state.
- Full low-level/native/QEMU suite passed in 131.853s, including the Embedded
  controller consumer. Its optimized LLVM IR is retained for inspection.
- Static Linux x86_64 package build and iOS 18 BoundedMemory module compilation
  passed; these cross-builds alone do not establish device/runtime behavior.
- The same signed VZ host and fresh guest passed four fixed cycles, device-absent,
  ignored-driver and cancel-while-inflated controls. Each VM stopped. The ignored
  driver had requested PFNs with zero actual PFNs and a fresh post-window
  heartbeat; cancellation remained distinct from completed cycles.

## Integration points and upstream proposals

Pinned source review, not an installed-service change:

- [apple/container 22029b0](https://github.com/apple/container/tree/22029b06867e46baf77b3404b849f4491739da3b)
- [apple/containerization fcc92dd](https://github.com/apple/containerization/tree/fcc92dd69716dee17407acc015e53854d45e9d1b)
- [Arcbox memory-ratchet 35b28f3](https://github.com/arcboxlabs/macos-vm-memory-ratchet/tree/35b28f379daac60bb8af099ace5d41ba52a17453)

Containerization exposes `VZVirtualMachineInstance.vzVirtualMachine`, `vmQueue`
and `VZInstanceExtension.configureVZ/didCreate/willStop`; the manager passes
extensions through VM creation. These are plausible narrow adapter hooks. A
correct adapter would need to retire/join before native lifecycle changes,
correlate every sent guest query and setter completion, and stop/recover its own
VM on terminal ambiguity. Do not call its queue.sync-backed `state` accessor
from inside `vmQueue`. Current stop shuts down the owned event-loop group before
calling `willStop` and swallows that hook's errors: guest IO cannot rely on this
hook alone. Pause/resume are additional lifecycle gaps to resolve upstream.

Apple's pinned package uses Swift 6.2 / macOS 15; this experimental package requires
Swift 6.4 / macOS 27 and enables Lifetimes for other BoundedMemory components. The
small two-file controller/budget subset has no such dependency, but an actual
Swift 6.2 build has not been verified. Importing the entire experimental package
into upstream would be an unjustified requirement bump. First propose the small
policy subset, explicit lifecycle/observation contracts and a reproducible VZ
physical-reclaim test. No Apple issue, PR or message has been submitted.

Arcbox is useful as a comparison harness, not as an authority provider. Its Rust
helper discovers a new `Virtualization.VirtualMachine` PID by a before/after set
difference and takes one candidate. Concurrent VM startup/PID reuse makes that
insufficient to bind the exact owned VM; availability of proc_pid_rusage does
not prove ownership. We did not execute its host-pressure scripts or adopt PID
inference, private KVC, cross-process reclamation or helper termination.

## Explicitly open

Unsolicited DEFLATE_ON_OOM state drift currently causes conservative retirement
and owned-VM stop. Automatic reconciliation needs negotiated-feature-aware native
positive controls; it is not production OOM recovery. Fleet grant arbitration,
real host-pressure sampling, suspend/resume recovery, exact helper/backing
attribution, host physical-return proof and a host-owned sparse HVF backend remain
separate work. No whole VMM, kernel module, production rollout or unconditional
language-performance claim follows from this experiment.
