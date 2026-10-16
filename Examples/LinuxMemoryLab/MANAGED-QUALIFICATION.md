# G23 managed native VMM qualification

This is a qualified research slice, not production acceptance. It uses native
Swift 6.4.1 on macOS 27.0.1, Apple M2 Max/32 GiB, Containerization 0.47.0 and the
Apple container 1.5.0 integration interfaces. Root PageMemory/BoundedMemory have
no dependency on the optional VMM or UI packages. Production services and data
were excluded. No push, installer or runtime cutover was performed.

## Implemented boundaries

- Explicit sustained execution has external lifetime ownership, bounded exit
  admission,64 KiB console retention/1 MiB file rotation and fixed owned-disk bounds.
  Default qualification still has120 s/3 million exits/512 MiB admitted-write limits.
- Validated boot256 MiB–3 GiB and dynamic128 MiB–2 GiB geometry reaches mappings,
  virtio configuration, manager, controller and workload. Unsupported layouts fail.
- Lightweight guest memory telemetry has an independent actor/process/wire.
  Foreground HOLD/full-byte diagnostics cannot occupy that wire. Both still share
  the guest kernel and vminitd control plane; the128 MiB hard cap was not raised.
- Shared bounded history moved unchanged into BoundedMemory, removing the
  backend-to-UI package edge. Native maps remain exclusively owned and inspected
  after all vCPUs park and HV mappings are removed, before backing deallocation.
- SQL load observation begins after native process.start returns a positivePID.
  Its owner retains and joins the result task before VM stop. The original query,
  wait and convergence limits remain unchanged.
- Unterminated UART diagnostics are retained; sink failures poison the journal.
  File locking precedes disk geometry inspection, and zero-byte I/O reports EIO.

## Executed proof

Final host UUID: `85AC772A-4B68-34E5-AD42-9B2C6A39D785`, matching dSYM and
ad-hoc signature. Host/static guest and195 source files were frozen. The
7,101,400-byte static guest SHA256 is
`fa2cf01b3daa74d3e64de80cc34753e51b173f3048e73dbe6b89eeaa8dc204e0`.

Release tests: root 41 and product 1 passed; final native suite had37 executed
general declarations and1 optional disk-fixture skip. The separate real APFS
fixture executed and passed that test. No new tests require production seams.

| Final profile | Seconds | Cumulative backing retired, MiB | Scope |
|---|---:|---:|---|
| continuous-two | 31.135 | 364 | Functional/lifecycle |
| continuous-four | 31.925 | 384 | Functional/lifecycle |
| adaptive | 33.647 | 212 | Functional/lifecycle |
| manual | 29.050 | 256 | Warm backing-return |
| busy | 23.817 | 0 | Functional/lifecycle |
| cancel | 18.004 | 0 | Functional/lifecycle |
| pending-stop | 20.168 | 128 | Functional/lifecycle |
| history-soak | 76.045 | 384 | Functional/lifecycle |
| history-churn | 58.023 | 2460 | Functional/lifecycle |
| lifetime-expire | 16.073 | 0 | Functional/lifecycle |
| sustained | 133.465 | 384 | Functional/lifecycle |
| dynamic-wide | 26.763 | 4096 | Warm backing-return |
| boot-wide | 26.653 | 512 | Warm backing-return |
| uart | 38.043 | 384 | Functional/lifecycle |

The independent validator accepted all14 profiles, including expected BUSY
refusal,2/4 vCPU and two private NICs, pending stop/cancellation, history wrap,
125 s sustained workload and two larger-memory layouts. Actual sampled guest
OOM/OOM-kill/swap counters were zero. Negative profiles are interpreted by their
specific refusal and clean teardown evidence, never by an exit code alone.

An additional real SIGKILL/recovery run passed39.270 s: the previous child was
reaped before restart, the same journaled ext4 image retained400,000 rows and
independent count/sum/payload oracles, and two new workload cycles passed.
All replacement vCPUs, VM and owning worker retired cleanly.

The small APFS-image test admitted396,427,264 bytes then refused a write with
1,073,766,400 bytes free. Independent reads verified the accepted payload and
untouched rejected extent. Both mount and raw image device were detached.
This is a conservative admission reserve, not a lock against unrelated writers.
ASIF mount timeout/format-refusal attempts were preserved before the successful
separate sparse-image fixture; global storage daemons were never restarted.

## Memory claims and counterexamples

In the1 GiB boot+2 GiB dynamic profile, host physical footprint at the second
shrink decreased from2995.0 MiB to964.7 MiB, then regrew to3022.7 MiB. FourGiB of
backing was cumulatively retired across two cycles. This does not mean four GiB
were simultaneously free. Strict warm profiles require fully resident inspected
backing and zero paged-out pages. Functional4 vCPU/UART profiles also encountered
pre-existing nonresident host pages; their actual residency is retained separately.
No virtual-byte, RSS or footprint counter is reported as attributed global
physical free-list bytes: `physicalReleasedBytes` remains null.

All failures remain in owning experiment evidence: v2 shared-wire observation
deadline; invalid large /dev/kmsg and disabled-SysRq controls; v3 native-pass but
insufficient history-wrap coverage (957 records); v4 query-start observation race;
and the overbroad warm-residency assumption in functional profiles. The final
churn scenario is bounded to46 extra cycles and must actually exceed both
journal boundaries. It does not repeat indefinitely until green.

Kernel high-order vmemmap allocation warnings remain visible. Linux can fall
back to base pages; successful controller/workload progress does not establish
elimination of that warning or all control-plane/kernel-pressure causes.

## Independent review and remaining product work

First-party Opus 5.5/max returned the focused UART proposal review in806.645 s
and monitor review in537.698 s, using original2700 s deadlines. The broad runtime
review timed out at1800 s without an answer. The UART scheduler proposal was not
implemented because its causal hypothesis was not demonstrated. Sonnet 5.5/max
returned IO review in1664.809 s and SQL-owner review in284.348 s. These were
static scoped reviews, not a VMM security certification or production GO.

All five product gates remain OPEN:

1. Persistent product helper/API, bounded abort of wedged RPCs, explicit stop/
   rescue admission and typed deadline attribution; long unattended lifecycle.
2. Autonomous multi-GiB pressure ramp with an explicit cgroup budget and measured
   startup/idle/peak behavior; continued kernel-zone/metadata investigation.
3. Global multi-VM reservation/fairness, fault/security fuzzing and deeper soaks.
4. Fair isolated stock-container/OrbStack baselines; current production OrbStack
   is excluded, and a clean comparison host is still needed.
5. Native runtime UI, signed helper identity/IPC, updater/rollback, image/network/
   shares/volumes support, Docker API/Compose matrix and copy-first migration.

ContainerWorkspace 0.0.1 currently inspects saved evidence only. It does not yet
control VM lifetimes or migrate workloads. Final branding/publication is pending.
