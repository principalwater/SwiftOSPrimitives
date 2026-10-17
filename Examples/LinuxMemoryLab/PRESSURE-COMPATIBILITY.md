# Autonomous capacity and application compatibility

Status: research in progress. All five product gates remain open. No production
deployment, installed Apple container change or transparent-compatibility claim.

## Reproduced boundary

The descriptor-backed two/four-vCPU and two-private-NIC controls pass the original
400,000-row durable-data oracle and two load/retirement cycles. Manual wide cycles
also demonstrated native backing retirement and host task footprint falling from
approximately 3 GiB to 1 GiB, then regrowing. This does not measure global physical
free-list bytes or qualify all applications under autonomous pressure.

The larger autonomous pressure profile uses a ClickHouse uncompressed Memory
table: seventeen 128 MiB batches, 2,176 MiB total. The workload retains its 8-second,
192 MiB per-query limits, one query thread, original data/NIC/CPU checks, 2,816 MiB
cgroup limit and 2,560 MiB explicit server ceiling. The control-plane cgroup keeps
its separate 112 MiB high/128 MiB maximum. Governor wire/completion/capacity/drain
fences and guest reserve are unchanged.

Attempts v3, v4 and v5 rejected an INSERT at ClickHouse's effective server memory
limit, not a demonstrated OOM kill. Kernel high-order vmemmap allocation warnings
are retained separately; they are not evidence of an OOM kill. Every failed
attempt and native teardown receipt remains retained in the private lab.

V4's native guest launcher observed 3,182,297,088 bytes online before exec, while
the controller starts only after initial SQL/data verification. The partial-online
startup hypothesis therefore does not explain the reproduced refusal. A launcher
receipt is still not a sample taken inside the ClickHouse initialization code.

V5 read-only failure diagnostics reported:

| Observation | Bytes/value |
|---|---:|
| Requested server ceiling | 2,684,354,560 |
| Effective server ceiling | 1,172,924,006 |
| Server memory-to-RAM ratio | 0.9 |
| Cgroup limit | 2,952,790,016 |
| Guest total at diagnostic | 1,760,428,032 |
| Guest available at diagnostic | 560,746,496 |

The effective ceiling corresponds to an earlier smaller capacity. Current upstream
ClickHouse source samples available memory every 15 seconds, reloads configuration
when it changes, and clamps the configured maximum using the physical-memory ratio.
This supports a delayed-capacity-refresh explanation; source inspection alone
does not prove the behavior of the exact guest binary.

## Controlled diagnostic

Candidate v6 changes only the pressure profile's application capacity observer
interval from 15 seconds to 1 second, and reads back the actual server setting.
It does not raise or disable any memory guard. Existing modes retain 15 seconds.
The same frozen v5 guest, original workload and independent validation remain.

V6 failed in the second cycle. Its first complete cycle held 2,176 MiB, preserved
the original data oracle and retired 2 GiB while SQL was independently active.
The second cycle encountered another transient server ceiling. Its peak RSS also
exceeded the unchanged 5 GiB experiment budget. No full pressure acceptance follows
from the first cycle, and no retry removes that failed record.

## Pending default policy

Virtio-mem hotplug changes guest MemTotal. Applications may cache capacity or size
their own pools, so fast native hotplug alone does not establish compatibility.
Potential alternatives remain pending, not shipped backends: application budget-change
integration; a traditional virtio-balloon device with negotiated DEFLATE_ON_OOM;
or free-page reporting with a proved host retirement/remap contract.

Linux's current balloon driver conditionally enables managed-page adjustment when
DEFLATE_ON_OOM is absent. That is relevant to stable visible capacity, not proof
that every kernel or balloon mode preserves it. OOM rescue cannot recover an
application that refuses allocation first at a cached user-space limit.

A 16 KiB host page can contain several 4 KiB guest pages. No new backend may
discard an unrelated subpage, live host alias, descriptor ring or device buffer.
Reporting ownership lasts only until host acknowledgement. Advice on a live
Hypervisor mapping is not presumed to release pinned RAM; actual residency,
native map results, failure recovery and workload integrity must be measured.

## Protected capacity contract

`NativeMemoryGovernor` now retains full installed capacity by default. An owner
may pass `minimumResidentBytes` only after accounting for workload budgets and
guest overhead. The API validates geometry; it does not discover or certify all
workload budgets. Unknown budgets therefore require retaining full capacity.
Admission atomically refuses an unsettled device or actual capacity below that
floor before consuming VM authority. The owner may restore capacity and create
a new governor; the refused governor itself remains a single-use object.
The earlier below-budget lab modes opt into their boot-only research floor
explicitly and do not establish a safe production policy.

`continuous-pressure-protected` is a stable-capacity control of the same large
workload, with the original 15-second application observer and unchanged memory,
query and deadline guards. Both full data/load cycles passed on frozen v7 with
zero capacity-change requests and zero backing retirement. This distinguishes
workload feasibility at full capacity from transparent reclamation. It is not
an autonomous-return qualification or an aggregate cgroup-budget implementation.

The actual below-floor regression consumed generation one and quarantined the VM
before this admission check. The repaired hardware control refused at generation
zero, restored capacity, admitted generation one, preserved the 400,000-row data
oracle and joined both vCPUs and both private NIC paths without quarantine.

A separate two-vCPU `continuous` replay failed with a foreground wire timeout.
Control-plane soft-limit events correlate with that failure; causation is not
established. The independent observer remained responsive, and no complete
workload cycle was accepted. Four-vCPU replay did not execute. Existing earlier
accepted controls do not waive this counterexample; all original limits remain.

## Physical backing experiments

The existing HypervisorMemoryLab now has mapped-advice and cold-remap controls.
Dirty mapped pages stayed resident after successful DONTNEED, FREE and REUSABLE
advice. In the same experiment fresh HVF mappings had zero resident pages before
guest touch. Cold replacement retired the exclusive old backing, mapped fresh
backing at the same GPA before vCPU resumption and then verified zeroes and fresh
patterns. The old translation-fault, alias and corruption controls remain separate.

This supports further investigation of free-page reporting with cold replacement.
It does not qualify Linux reporting ownership, arbitrary 4 KiB/16 KiB subpages,
multi-vCPU/device concurrency, poison handling or allocation-failure recovery.

## Primary references reviewed on 2026-10-17

- [ClickHouse capacity observer](https://github.com/ClickHouse/ClickHouse/blob/master/src/Common/CgroupsMemoryUsageObserver.cpp)
- [ClickHouse server settings](https://github.com/ClickHouse/ClickHouse/blob/master/src/Core/ServerSettings.cpp)
- [ClickHouse physical-memory discovery](https://github.com/ClickHouse/ClickHouse/blob/master/base/base/getMemoryAmount.cpp)
- [ClickHouse server limit installation](https://github.com/ClickHouse/ClickHouse/blob/master/programs/server/Server.cpp)
- [Linux virtio balloon driver](https://github.com/torvalds/linux/blob/master/drivers/virtio/virtio_balloon.c)
- [Virtio 1.3, traditional memory balloon device](https://docs.oasis-open.org/virtio/virtio/v1.3/virtio-v1.3.html)
