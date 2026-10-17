# Native free-page reporting prototype

Status: experimental, default off, not production qualified. All five product
gates remain open. The existing protected-capacity baseline is unchanged.

The optional native manager now offers Linux virtio-balloon REPORTING while
keeping balloon target zero and guest-visible capacity stable. REPORTING grants
ownership of isolated free pages until used-ring acknowledgement. FREE_PAGE_HINT
does not grant the same contract and is not offered.

Only whole, individually owned 2 MiB dynamic extents are eligible. Boot RAM,
partial extents and unsupported nonzero page poisoning retain their contents.
Overlaps, non-writable descriptors, bad alignment, invalid GPA ranges and rings
aliasing their own metadata are refused. The reporting-specific 64 MiB buffer
bound does not change the ordinary queues' 1 MiB limit.

With all vCPUs parked, the coordinator unmaps eligible extents, checks exclusive
native object ownership, deallocates old backing, allocates fresh anonymous
zero backing and maps it at the same GPA before acknowledgement or resumption.
Fresh mappings must have zero resident pages under native `mincore`. An alias
refusal restores all old mappings before acknowledgement; a native failure after
retirement stops the VM instead of resuming a partial transaction. Sticky memory
quarantine prevents future recycling. All device payload lookups resolve the
current extent; no asynchronous DMA or escaped guest pointer is supported.

Recycling has its own bounded history and cumulative virtual/resident counters.
It does not increment logical virtio-mem unplug counters or change MemTotal.
Native object deallocation, cold replacement, task footprint and resident-page
observations are distinct from a global physical free-list measurement.
`physicalReleasedBytes` remains null.

## Cold initial provisioning

The experimental FPR mode also leaves freshly allocated dynamic objects cold on
their first plug. Anonymous zero-fill replaces the initial host-wide `memset`;
reused held pages still require clearing, and the default non-FPR behavior is
unchanged. An actual before control observed 2 MiB resident before guest access.
The repaired control observed zero, then verified all guest words as zero before
writing and checking its pattern. Initialization provenance follows the object.

Separate two- and four-vCPU Linux functional runs passed after this change. Their
free dynamic pages had never been touched, so reporting retired zero resident
bytes; that is avoided allocation, not a manufactured reclaim credit.

## Transport correction

The Linux balloon driver's logical REPORTING array index is four. Linux's
virtio-mmio transport compacts absent optional queue names. With statistics and
hinting absent, the actual queues are inflate zero, deflate one, reporting two.
The first hardware attempt failed during negotiation. A frozen diagnostic
confirmed notify value two with driver-ready status fifteen; the repaired device
and wire test use queue two. Those failed attempts remain retained.

## Current hardware evidence and unresolved latency

After the queue repair, a real two-vCPU/two-private-NIC ClickHouse run processed
39 reports and recycled 2,233,466,880 previously resident bytes in total. Old
objects had one reference, mappings were restored before acknowledgement and
fresh replacements had zero resident pages. Native VM destruction and worker
join completed. The workload nevertheless FAILED its required repeated return
of at least 1 GiB within eight seconds after release; no complete cycle was
accepted. Startup recycling does not satisfy that repeated-return requirement.

That early receipt included host-initialized backing; its old provenance flag
incorrectly depended on the operation type. Current receipts capture the old
extent's initialization history before retirement, separately from the fresh
replacement. The repeated-load contract counts only resident bytes retired from
previously cold backing. Earlier totals must not be presented as guest-only RAM
return. A later run failed its unchanged SQL deadline before the return check;
the same SQL failure also reproduced with reporting disabled. Its cause remains
unresolved, and a profiled successful control is not latency qualification.

Guest diagnostics after release showed over 2.4 GB free and over 2.8 GB available.
This does not establish that those pages were already reported and owned by the
host. The exact Linux driver schedules reporting in delayed, budgeted passes;
its source describes an idle scan of about thirty seconds. Bounded per-report
timing/size records and post-failure observation are being qualified to separate
that scheduling from fragmentation or ownership problems. The eight-second
failure remains a failure even if later memory returns. No guard is relaxed.

## Actual native owner controls

The lab executable's `--memory-device-check <guest-image> <new-output-directory>`
entry runs a bounded Embedded Swift guest on one actual HVF vCPU, using the same
MemoryDevice owner as Linux. It does not add a product-manager diagnostic API.
The separate guest build uses the existing HypervisorMemoryLab boot assembly
and linker script, with a 512-page (2 MiB) data command.

On the measured host, all four control groups passed with native cleanup:

1. A second native object reference prevents recycling, restores the old mapping
   and preserves guest data. Releasing the alias permits retirement.
2. Reporting a replacement again without any guest access observes zero old
   resident bytes. Every replacement is mapped at the same GPA with zero resident
   bytes before acknowledgement.
3. Guest writes to sixteen 4 KiB pages produce exactly 64 KiB of observed resident
   backing; the next report retires it. Unplugging that untouched replacement
   observes zero resident bytes and no host initialization.
4. Guest zero/pattern verification, intentional host-side corruption detection
   and sticky quarantine all preserve their respective data/lifetime contracts.

The first and regrown extents are explicitly counted as host-initialized, not
guest-only memory. This is one-vCPU owner evidence, not a Linux/SMP workload or
global free-list measurement. A two-vCPU Linux replay completed its SQL/data/NIC
checks but failed the independent untouched-cold-unplug assertion because Linux
had retouched every unplugged extent. That failed qualification is retained.

A separate four-vCPU/two-private-NIC replay completed two SQL/integrity cycles
and 256 MiB of logical backing retirement in 28.812 seconds. Its ten reports
retired 94,371,840 observed resident bytes, all from host-initialized generations;
the guest-only cold-resident counter stayed zero. Four untouched cold replacements
were subsequently unplugged, with all four CPUs parked and native cleanup/join
verified. This qualifies that functional SMP case, not repeated multi-GiB return.

The latest owner controls now publish eight actual reporting virtqueue entries,
including used-ring and interrupt-status acknowledgements. Both warm and cold
initial modes passed: alias refusal restores the old mapping; a negotiated
nonzero poison value preserves the full guest pattern without recycling; clearing
poison permits replacement and a full guest zero check; quarantine acknowledges
the report without destructive work. This is one-vCPU wire/owner evidence, with
Linux SMP interrupt delivery qualified separately by the functional runs.

## Retained pressure failures and geometry candidate

Cold initial provisioning produced a real guest-only retirement of 605,896,704
resident bytes in the 1 GiB boot / 2 GiB dynamic case. The original 1 GiB within
eight seconds requirement still failed; an additional thirty-second observation
found no more retirement. Reports for immutable boot RAM cannot be reclaimed by
this backend, and fragmented dynamic ranges are also outside its current scope.

A separate 512 MiB boot / 2560 MiB dynamic experiment kept the same 3 GiB total,
2176 MiB table and all query, cgroup, RSS and deadline guards. It retired
1,035,993,088 resident bytes after the peak before the deadline, below the required
1,073,741,824. Another ten seconds raised that window's total to 1,300,234,240.
The SQL result and native teardown remained correct. Late return is not a pass.
This resource split remains experimental; independent wire-size/tail tests cover
the aligned dynamic bound through 3 GiB, not every hardware geometry combination.

Still required: successful repeated-load qualification and four-vCPU pressure runs,
native-failure cases at the reporting transport boundary, boot-RAM/fragmented-page
support, idle/CPU/tail-latency measurements, product VM ownership, global
reservations and the remaining compatibility, migration and security gates.

## Exact primary sources

- [Linux 6.18.35 balloon driver](https://github.com/gregkh/linux/blob/v6.18.35/drivers/virtio/virtio_balloon.c)
- [Linux 6.18.35 MMIO queue construction](https://github.com/gregkh/linux/blob/v6.18.35/drivers/virtio/virtio_mmio.c)
- [Linux 6.18.35 page-reporting scheduler](https://github.com/gregkh/linux/blob/v6.18.35/mm/page_reporting.c)
- [Virtio 1.3 specification](https://docs.oasis-open.org/virtio/virtio/v1.3/virtio-v1.3.html)
