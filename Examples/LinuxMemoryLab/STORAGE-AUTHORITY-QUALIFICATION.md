# Descriptor admission and retirement followup (G24)

Research qualification only. All five product gates remain open. No production
service, physical-volume setting, installed runtime or client network changed.

## Implementation

`PageMemory.DarwinFileAuthority` checks a borrowed native descriptor using
`fstatfs` and the extended-ACL APIs. It refuses ignored volume ownership, any
extended ACL entry (including restrictive entries), and unknown ACL errors.
Darwin's no-ACL ENOENT and valid empty ACLs are handled separately. The caller
retains responsibility for type, uid, mode, links and descriptor lifetime.
The API changes no permissions. It is macOS-only; Linux memory code is unaffected.

NativeBootResources checks the admitted directory, each opened input, console
and later descriptor duplications. A single Mutex serializes duplication,
one-shot kernel transfer and retirement. Successful native teardown, failed
pre-boot setup and stop-before-start release the kernel snapshot and original
file descriptors even when manager/resources objects are retained. Independent
disk attachments retain their own descriptors until closed. Failed native
teardown keeps authority quarantined; a close failure remains an error.
A retired admission is not reusable: reopen the directory for a new generation.

The legacy lab path now opens disk/OWNER/kernel inputs with O_NONBLOCK and
O_NOFOLLOW, checks regular files and size bounds before reads, and checks
metadata before/after bounded snapshots. Kernel images are limited to64MiB;
OWNER metadata to4096bytes. The legacy marker is research admission, not a
private production storage policy.

ContainerWorkspace uses the same shared authority check for workspace creation,
directories, manifests, lock files, inherited helper authority and executable
admission. A non-owning parent volume is refused before creating a workspace.
Existing data/ACLs are never rewritten to make an input pass.

## Actual differential tests

Opus5.5/max returned a three-file review after877.907seconds with tools disabled.
It is a scoped review, not security signoff. Before-v1 unit attempts failed to
compile because of ACL interop/test-macro mistakes and are not regression proof.
After correcting only the tests, native-storage-security-before-v2 executed:

- Four real ACL cases (directory/kernel/initfs/rootfs) admitted expanded access
  and created a console: eight failed expectations.
- An actual ignored-owner volume was admitted and created a console: two failures.
- Stop-before-start retained the kernel/console and disk lock: three failures.

Product-acl-before-v2 independently failed the two new lock/manifest ACL cases.
The same parameterized owner-boundary tests pass after the shared repair.

Native release49 declarations reported passing, including all explicit mount/ACL
cases (117.660seconds outer,18.576seconds native). The optional small-volume
space-reserve fixture was not supplied. Root release42 tests passed;38 compiler
ownership cases passed in10.769seconds. Product releaseCore21/App6 passed with
fresh signed helper-process-v4 fixtures in9.199seconds. Tool collection is
partial for Swift6.4.1; saved native logs are authoritative.

Actual old-host FIFO disk admission took35.107seconds and reported start/stop
deadlines without a native worker join. The repaired frozen host refused the
same FIFO class in0.249seconds, joined its worker and created no hypervisor VM.
Both processes were natively reaped by the finite harness; no timeout was waived.
Frozen native-pressure-v3 UUID E3BBCA31-6BB5-3F91-A9E3-2121B72F4726 has matching
symbols and217-source snapshot. Both normal descriptor-backed2/4CPU profiles passed independently in36.788/36.109
seconds: two private NICs,400000-row oracle, two fresh SQL/load cycles,384MiB
cumulative backing retirement per run, and actual native CPU/VM teardown.

## Limits still requiring work

The physical T7 mount has ignored ownership. Only an isolated synthetic APFS
disk-image fixture was mounted with ownership enabled; T7 settings were not
changed. This proves the descriptor checks, not protection against an attacker
who can modify the disk image's backing file. Production storage must have a
trusted backing chain; cross-user/security qualification remains open.

A failed directory fsync during console admission can still leave a new empty
UUID diagnostic file. Crash-atomic workspace creation and interrupted-admission
reconciliation remain open; no arbitrary data cleanup is performed. Kernel
snapshots remain bounded Foundation Data allocations, not fallible page owners.
Regular storage I/O can still stall; outer VM-aware helper retirement is required.
The standalone low-level research executable is not a product input boundary.

The new large ClickHouse pressure profile is NOT accepted. Attemptv1 exposed
a lab aggregate phase deadline; attemptv2 failed additional process startup near
the vminitd memory.high threshold; attemptv3 returned ClickHouse26.9.19 code241
with effective limit1.12GiB while the native governor was growing memory. There
was no demonstrated OOM kill: the kernel log was a vmemmap high-order allocation
warning. Explicit application budgeting, initial online-capacity readiness and
compatibility with memory-aware applications need further evidence. Do not
represent application-configuration changes as transparent balloon compatibility.
