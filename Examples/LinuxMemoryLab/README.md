# Native Linux backing-memory lab

Research-only, finite ARM64 Linux VMM written in Swift. Requires an Apple-silicon
Mac, macOS27 SDK/deployment target and Swift6.4.1. Linux guest control is hosted
Swift with Musl/POSIX and PageMemory, without Foundation. No package product,
service installation, production deployment or stock Apple container modification.

## Ownership and revocation

A single synchronous pthread creates/runs/destroys the sole HVF vCPU. All RAM
mapping and device mutations occur after native CPU return. A bounded watchdog
may request CPU exit, but cannot access RAM or change mappings. GICv3 uses the
physical EL1 timer; PL011 and virtio-MMIO use separate SPIs. There is no NIC,
vsock, firmware, ITS/MSI or asynchronous device/DMA worker. LPIs and hotplug
memmap-on-memory are disabled explicitly. The guest verifies online Movable RAM
and the corresponding virtio-mem device before starting ClickHouse.

Boot RAM is a separate native allocation. A dedicated region at GPA0x100000000
is omitted from the boot memory node and provided through standard virtio-mem,
with 64 independently owned 2MiB HVF allocations. PLUG zeroes/maps before ACK.
The guest must negotiate VERSION_1 and UNPLUGGED_INACCESSIBLE. Only the kernel's
UNPLUG request authorizes revocation: UART messages only request policy changes
or report telemetry. The sole CPU is stopped throughout request execution.

UNPLUG removes stage2 mappings, checks native anonymous object identity, exclusive
reference count, no shadows/external pager and no wiring, then deallocates the
owned object before ACK. Old virtual-range absence is checked immediately.
Unplugged GPA accesses fail the run, including instruction aborts and ISV=0.
Paged-out pages remain owned and can be deallocated safely; their count is
reported separately and never counted as observed resident RAM. Unknown physical
free-list arrival remains null. Ordinary Linux RAM permits guest execution under
Linux stage1 protections; host aliases remain non-executable.

The block device resolves every payload again while the CPU is stopped, splits
physical I/O across host allocation boundaries and retains no pointer across an
exit. Queue metadata and memory-control messages must remain in boot RAM. Ring
cycles, overflow, stale publication and metadata aliasing fail closed. Negotiated
segment bounds, an owned regular-file marker, exclusive file lock, bounded writes
and native full flush protect the disposable disk image.

## Finite scenarios

Build the two executables with independent scratch/cache/module-cache/temp paths
inside an operator-created private test root on disposable storage. Cross-compile
`linux-memory-guest` with the matching static ARM64 Musl Swift SDK. Strip only an
owned executable copy, retain its original for diagnostics, and use the existing
`Tools/MakeGuestInitramfs.swift` with the Embedded bootstrap. Its32MiB guest limit
is unchanged. Supply a trusted, hash-retained Linux Image with virtio-mem,
virtio-MMIO/block, hotplug/hotremove, GICv3, PL011 and ext4 enabled.

Ad-hoc sign a fresh host executable with `hypervisor.entitlements` and verify it
before each selected source generation. Do not use production/global container
state or network interfaces. Invocation:

```text
linux-memory-lab <Image> <initramfs.cpio> <fresh-result-directory>
linux-memory-lab <Image> <probe-initramfs.cpio> <fresh-result-directory> memory
linux-memory-lab <Image> <probe-initramfs.cpio> <fresh-result-directory> held
linux-memory-lab <Image> <probe-initramfs.cpio> <fresh-result-directory> alias
linux-memory-lab <Image> <clickhouse-initramfs.cpio> <fresh-result-directory> memory <disk>
linux-memory-lab <Image> <clickhouse-initramfs.cpio> <fresh-result-directory> held <disk>
```

The alias scenario is an intentional refusal control: an additional native host
mapping must prevent deallocation, fail the run and still permit explicit teardown.
The held scenario removes guest mappings identically but retains the owned host
objects; the same guest memory reduction must not be mistaken for host return.

Disk admission requires a fresh COW copy named `artifacts/clickhouse-run-*.ext4`,
8GiB logical capacity, single link, current uid and the enclosing private root's
`OWNER.json` containing its canonical `root`, `uid` and research purpose
`isolated-linux-backing-G17`. The pristine image must remain untouched. This
revision marker is deliberately scoped to the isolated experiment, not a public
provisioning format.

ClickHouse is loopback-only inside the NIC-free guest, with one query thread,
fixed memory/scan/time/output limits and four100K-row batches. Before each shrink,
`system.processes` must show the actual identified workload using at least16MiB;
process creation alone is insufficient. Two shrink/regrow cycles compare row
count, arithmetic id sum, payload hash/byte count, workload result and every byte
of a64MiB canary. Native waitpid ownership, bounded signal/join and an ECHILD check
precede the final success marker. All raw results and environment observations
belong outside version control.

## Limits and pending integration

PENDING: extraction into a reusable production backend and integration with the
Apple container VM owner. This example proves a narrow topology, not a general
hypervisor or an App Store API. Unexpected ownership/native/device failures stop
and destroy the disposable VM; no partial operation is falsely ACKed. It does
not yet implement recoverable multi-object rollback/BUSY or live multi-vCPU,
LPI/DMA, migration, suspend, remote control or production storage semantics.
Those require independent lifecycle/ownership review before adoption.

A task-footprint credit, resident page count and disappearance of an owned VM
object are distinct observations. None alone measures the host physical free
list. No foreign task, borrowed VZ RAM, guessed PFN, purge command, private API,
inline assembly or kernel security bypass is used.

## Primary contracts

- [ARM64 Linux boot](https://www.kernel.org/doc/html/latest/arch/arm64/booting.html)
- [Virtio memory and MMIO](https://docs.oasis-open.org/virtio/virtio/v1.3/virtio-v1.3.html)
- [Linux virtio-mem driver](https://github.com/torvalds/linux/blob/v6.18/drivers/virtio/virtio_mem.c)
- [Memory hotplug](https://docs.kernel.org/admin-guide/mm/memory-hotplug.html)
- [Hypervisor](https://developer.apple.com/documentation/hypervisor)
- [XNU VM/compressor ownership](https://github.com/apple-oss-distributions/xnu/tree/main/osfmk/vm)

Use the repository's Swift code conventions, release unit tests and the native
positive/held/refusal scenarios. Synthetic EL1 results from HypervisorMemoryLab
are separate evidence and cannot qualify the Linux/ClickHouse path.
