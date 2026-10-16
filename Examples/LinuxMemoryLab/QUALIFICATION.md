# G19 SMP, private NIC and recovery qualification

Measured 2026-10-16 on Apple M2 Max / 32 GiB, macOS 27.0.1 (26A434), SDK 27,
Swift 6.4.1 and matching ARM64 static Musl SDK. Apple container 1.5.0 and
Containerization 0.47.0 are pinned in the adjacent README. One disposable VM
ran at a time, nice 19, with fresh resource admission. No installed container
service, production network, VPS or main Macray worktree was changed.

## Final native matrix

Every row used two independent private NICs and completed two 128 MiB guest
shrink/regrow cycles. Each observed an identified ClickHouse hash join with
at least 16 MiB live memory both BEFORE and AFTER native UNPLUG. After UNPLUG,
actual memory remained 22,793,859...22,794,043B. Independent full 400K-row
count/id-sum/payload-hash/byte oracles, a 64 MiB canary, actual per-CPU work and
both UDP paths passed. Every resource sample had zero OOM and zero OOM-kill.

| Trial | vCPUs | Whole trial seconds | Owned backing bytes deallocated | Sum task-footprint credit bytes |
|---|---:|---:|---:|---:|
| memory | 2 | 29.625 | 268435456 | 268566720 |
| held | 2 | 30.025 | 0 | 0 |
| busy | 2 | 32.279 | 268435456 | 268566720 |
| four | 4 | 29.505 | 268435456 | 268533904 |

Backing totals are cumulative across two cycles; simultaneous dynamic capacity
is 128 MiB, in addition to 1 GiB fixed boot RAM. Native deallocation removes owned
objects; it does not just report less capacity to the guest. All CPUs were
parked for every mapping operation. Every positive retirement observed the old
virtual range absent, an exact 2 MiB native entry at offset0, reference count 1
and successful native deallocation. Every vCPU and coordinator joined, every
native vCPU was destroyed and VM destruction returned cleanly.

Held mode returned the same guest capacity but retained host objects: 0 frees and
0 credit, an independent negative control. The alias case observed reference
count 2 and replied BUSY only after restoring all 64 original mappings; it freed
0 bytes on refusal. Canary/data remained valid. Retiring the alias and issuing
config_changed let the standard Linux driver's retry complete both cycles.

Resident-before observations are separate from backing size and task ledger:
the2CPU memory run observed 181,403,648B resident and 5,312 pages_swapped_out;
the 4 CPU and BUSY runs observed all 268,435,456B resident and 0 pages_swapped_out.
Host pages are 16 KiB and observations include security zeroing. They are not
proof that every retired page previously contained ClickHouse data. Task-ledger
deltas can include adjacent accounting noise. Exact global physical free-list
arrival remains unknown and physicalReleasedBytes is null throughout.

## Actual crash and authority loss

Native Swift supervision completed SIGKILL/reap/process-group disappearance,
then restarted a new VM on the same journalled disposable disk in
43.257s total. The crash point followed acknowledged
fsynced 400K-row inserts and an observed 32,813,867B live query. Replacement
validated the persisted independent oracle, repeated both RAM cycles with CPU/
NIC canaries and retired another 256 MiB backing. Native cleanup returned clean.

A separate real SIGKILL of the supervisor, with its VM already running, closed
the sole pipe writer. The native owner emitted SUPERVISOR_LEASE_LOST and was
absent after 0.010897s in this trial. The injecting process
reaped its supervisor. The OS adopts the orphan; this is not a claim that the
injector reaped a non-child or measured every kernel cleanup phase in 11 ms.

An actual initial crash of an unjournalled image corrupted ext4 metadata.
Recovery now refuses such images before spawning. The native Swift upstream
EXT4 reader/formatter prepares a NEW 8 GiB image with a 64 MiB ordered JBD2 journal;
it never repairs an existing image. A second defect was reproduced at the real
upload boundary: createIfMissing does not truncate, so appending chunks to an
old probe yielded 16,873,392B for 7,093,208B source. Each generation now uses a
fresh UUID path and checks confined native stat size/type/uid/link count before
exec. Actual recovery passed after that owner repair. No deadline was increased.

## Tests and limits

Release Swift Testing passed 18 native test declarations and 39 root declarations
in 5 suites, warning-free. Golden malformed-wire, ICMP, actual socket backpressure
and partial factory cleanup cases accompany the real VM tests. Compiler logs
are primary evidence; axbuild's Swift Testing event collection was partial.
Earlier failures and original deadlines remain retained, not reclassified as
passes. The final 100K-build/100K-probe, 4 s hold fixture differs from earlier
transient / 200K fixtures; elapsed time across them is not a speedup comparison.

This qualifies the optional research backend on this host, not arbitrary VZ
memory, production throughput / idle CPU / SLO, hardware DMA, power-loss survival,
snapshot consistency, migration, suspend, CPU offlining or installed CLI
replacement. The explicit stop-all protocol prioritizes revocation correctness.
The tiny public upstream access patch is still required. No production adoption,
Linux-host HVF backend or Rust-performance claim follows from these trials.
