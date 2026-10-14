# Native page reclamation and security report

Isolated Swift6.4.1 experiment; macOS27.0.1/M2Max and native Linux x86_64 musl.
No deployed service, network policy, main-branch integration, VM balloon controller or
kernel/module rollout is implied. Public products use native Swift owners and OS APIs;
standalone synthetic fault aliases never enter the library.

## Actual page observations

Eight controlled2MiB cycles per mode,16KiB Darwin pages, full logical initialization,
native erasure verification, mincore and self RSS/physicalFootprint, monotonic timings.

| Darwin mode | Resident pages before -> after | RSS drop | Footprint drop | Median discard |
|---|---:|---:|---:|---:|
| Held/no-discard |128 ->128|0|0|control|
| Anonymous/MADV_FREE |128 ->128|0|0|14.125us|
| Anonymous/reusable advice |128 ->128|0|2MiB|11.521us|
| Reclaimable/Mach EMPTY |128 ->0|2MiB|2MiB|91.771us|

The new path removes observed backing, while the old reusable hint only changes the
ledger in these samples. This is an intentional cost/benefit: eager purge is slower
than lazy advice and belongs at bounded pool retirement, not on each packet. These
are point measurements, not guaranteed completion latency, a global-free-RAM delta,
or a new Swift-vs-Rust comparison. Wired/busy pages can survive successful EMPTY.

On a resident standby Linux node, fresh inventory/home-primary admission and before/
after service/config observations guarded native tests. Sandboxes:32MiB RAM, no swap,
10%CPU/20ms period,8tasks,15s runtime, no network, read-only filesystem, no privilege
escalation and no writable executable mappings. Held/reclaimable each ran8cycles;
held512 ->512 pages, reclaimable512 ->0, with actual erasure/reset verification.
Native CPU29.139ms/53.937ms, wall299.275ms/559.213ms under CPU throttling; final RSS
about5.99MiB. SSH/systemd orchestration is separate. Linux statm is approximate.
These snapshots establish sampled invariants, not absence of every client's jitter.
Own uploaded file and empty directory were removed after exact checksum verification.
A separate final static-musl external consumer also passes:256destructions/1024Atomic
slots/8KiB backing, prior budget/frame/sequence checksums and RECLAIMABLE_PAGES5120;
native CPU10.147ms/wall99.716ms, final RSS5685248bytes. Its upload is also removed.

## Failure and ownership evidence

Actual standalone Mach linker-bound tests inject refused allocation, purge/reset,
partial erasure and unmap, forwarding all successful calls to real native libSystem.
Rounded padding is deliberately dirtied and verified erased. A real mlock/EMPTY/
munlock/EMPTY cycle keeps a wired page on first purge and removes it on retry.

Three independently retained negative controls fail for their intended reasons:
- Before correction, a discarded-state shortcut refuses with wiredRetry(1) after unlock.
- A private removal of preparation retirement refuses with unretired on partial erasure.
- Before unmap quarantine, the new failed-release byte-access check refuses unretired.
Corrected native fixture passes. These are private source snapshots/mutations, not
unmodified historical releases. Nonblocking refusal causes no allocation/erase/release
state change. Failed unmap permits release retry only; no safe byte access/reset/erase.

## Validation and independent review

Native42 release and42 ASan tests pass, including parameterized backing cases;
36 compiler/lifetime cases, real default-framework consumer execution, iOS18 module
compile using SDK27, static Linux builds/native capped probes, and full Embedded/
no-allocation/ARM64+x86 ELF/dependency/hardening profiles pass. Twenty-one networkless
real guest cases pass, retaining the prior >65536 RNG queue-wrap/balloon/trap/IRQ bounds.
Those guest successes do not establish physical VM backing release. CI run links and
final source revision are attached to the experimental release after actual completion.

Actual tool-free Sonnet5.5/maxrequested735.345s and Opus5.5/maxrequested1128.219s return
firstParty/end_turn/nonerror/native0,3600s deadline. Effective provider effort is not
reported. Public answers only were read. They reviewed the earlier snapshot; final
corrections are Root/native checks, not invented final-source model signoff.

Adopted findings: purgeRequested naming, accepted-advice versus measured accounting,
secure erase before reset/discard/release, sparse erasure recommit costs, no universal
Darwin-zero assertion, mutating closed purge-state API and explicit unmap quarantine.
The conditional alignment concern is resolved by the actual MappedValue aligned-slot
calculation inside padded backing, not by rejecting supported aligned values.
Writing despite a failed NONVOLATILE/REUSE transition is deliberately refused.

Original compiler failures are retained: unsupported Span allSatisfy/test macro capture,
missing iOS mach_vm imports (fixed with public vm_* fallback), missing unsafe fixture
annotations, and a missing fixture enum caption. One following run used the previous
binary after that caption build failed; it is explicitly NOT final-fixture acceptance.
Native saved logs are primary; axbuild event mapping for641 has partial collection.

## Scope and remaining work

See [the security contract](MemorySecurityAndReclamation.md) for exact limits. Advice,
residency, RSS, footprint and balloon acknowledgements remain separate observations.
No erase removes previous registers/copies/compressed snapshots/swap/dumps; erasing a
sparse/discarded mapping can recommit its whole extent. Explicit release is needed for
error reporting; destructor makes one final attempt and cannot promise erasure.

Physical VM-balloon proof needs a dedicated disposable Linux backing host or an owned
Virtualization.framework adapter, full guest/host ownership and fresh observations.
The standby admission is only for tiny native probes, not a VM/package/module install.
iOS device runtime/App Store, cached/multicore DMA, real physical Pin, kernel ABI/
Kbuild/CFI/ORC and live-driver recovery remain open. Working network/main work untouched.

The final map has867nodes/1513edges/no dangling endpoints. Nineteen Swift files are
partially parsed and new documentation has no semantic extraction; generated graph
artifacts are outside Git. No claim of exhaustive cross-file safety analysis follows.
