# Descriptor-pinned boot resources — research qualification

NativeBootResources supplies a second, explicit admission boundary for the native
Containerization backend. It does not adopt external container stores, import
images or replace the product's workspace/global-resource policy. All five
ContainerWorkspace production gates remain OPEN.

## API and ownership

The caller supplies an already admitted private directory descriptor and retains
its user file-access grant. Fixed children are kernel, initfs.ext4 and rootfs.ext4.
Each run creates a distinct console-UUID.log exclusively. openat/O_NOFOLLOW,
O_NONBLOCK, owner/type/mode/link/size/alignment checks and native advisory locks
precede admission. Only regular private files are accepted. Root disks support
sector-aligned sizes through 1 TiB; initfs is bounded to 512 MiB and the AArch64
kernel snapshot to 64 MiB. These are explicit limits, not general image support.

The bounded kernel snapshot is transferred once into the consuming boot argument;
the resource owner does not keep a second permanent image. Independently duplicated
CLOEXEC descriptors pin disk and console identity across directory/file renames.
A disk attachment retains the root lock after the admission owner is released.
A resource set can be claimed by exactly one VM manager. The Containerization root
mount must use its exact opaque mountSource; arbitrary paths are refused.

```swift
let resources = try NativeBootResources(directoryDescriptor: admittedDirectory)
let manager = NativeVirtualMachineManager(resources: resources, group: eventLoops)
let root = Mount.block(format: "ext4", source: resources.mountSource, destination: "/")
```

The legacy research initializer remains available with its old path admission.
Its path metadata properties are now optional: descriptor mode has no reopenable
kernel/initfs/console path. This is a pre-production source API change; callers
reading those properties must handle nil. No installed consumer was changed.
The NativeLinuxVMM package still lives under Examples pending product extraction.

## Executed evidence

Release suite: 47 test declarations reported passing, with the optional separate
APFS reserve fixture skipped because it was not supplied. New boundary cases
cover actual path replacement with independent readback, immutable kernel snapshot
transfer, retained lock after owner release, ten malformed file/geometry cases,
exact mount identity and refused reuse. Existing devices, cancellation, wire and
execution-policy tests remained passing under warnings-as-errors.

Frozen host UUID A0A74E40-6B24-3A92-A918-FB6834DD1E2A has matching symbols and an
archived 216-source snapshot. Actual descriptor-backed ClickHouse qualification:

| Case | vCPUs / private NICs | Elapsed | Verified backing retirement |
|---|---|---|---|
| Continuous | 2 / 2 | 32.932 s | 384 MiB cumulative |
| Continuous | 4 / 2 | 30.123 s | 384 MiB cumulative |
| Wide geometry | 2 / 2 | 27.452 s | Two 2 GiB shrink/regrow cycles |

Each case preserved the independent 400,000-row oracle and completed two fresh
load/integrity cycles. Both NICs progressed; all native vCPUs were destroyed and
joined. The wide second cycle's retained 1,024 retirement records were fully
resident before removal. Host task footprint changed approximately
2,988.9 -> 1,002.7 -> 3,052.4 MiB across regrown-1/shrunk-2/regrown-2. Old virtual
ranges were absent, only the native owner reference remained before retirement,
and mappings/backing were retired only with every vCPU parked.

The first wide cycle's per-block records rotated out of bounded history. Its
2 GiB retirement/regrowth is supported by counters and integrity, not a retained
claim that every block was resident. Cumulative 4 GiB is across two cycles, never
simultaneously returned physical RAM. Global physicalReleasedBytes remains null.

## Retained failed measurement and recovery limits

All 17 legacy-path profiles completed their expected native outcomes and passed
functional/ownership/integrity checks. The original strict matrix validator
REJECTED wide residency: 436 of 1,024 retained blocks were already nonresident.
A single controlled same-artifact replay also failed that criterion (164 blocks).
Both original failures remain retained; no deadline, quota or residency assertion
was relaxed to declare the strict matrix accepted. A separate diagnostic projection
checks functional predicates and explicitly marks strictWarmMatrixAccepted=false.
Already nonresident blocks are not counted as resident physical RAM returned.

Actual SIGKILL/recovery on the same frozen host passed in 39.102 seconds: the old
child was natively reaped before replacement, 400,000 rows survived and two new
load/integrity cycles completed with two CPUs/two NICs and clean teardown.
That recovery used the legacy path frontend. Descriptor-mode crash/reopen remains
unqualified; unit file-lock lifetime tests and normal descriptor runs do not
substitute for that product recovery test.

## Upstream and remaining product gates

The latest Apple container release checked was 1.5.0, commit
d265d669ecae041bf338cb3b39c4118316d138f0. Its Package.swift pins Containerization
exactly to 0.47.0, matching this backend. Containerization's separate 0.52.0 tag
was observed but not promoted implicitly. The small existing upstream adapter
and exact dependency provenance remain separate from our memory implementation.

Missing product evidence includes real VM admission in the app helper, a combined
memory drain/process lifetime contract, global reservations and multi-VM fairness,
security/idle/host-sleep soaks, distribution signing, general networking/shares/
images/volumes, update/rollback and copy-first Docker/Compose migration. A fair
stock-container/OrbStack comparison still needs a clean host. This is not an
OrbStack-equivalent product release or production adoption authorization.
