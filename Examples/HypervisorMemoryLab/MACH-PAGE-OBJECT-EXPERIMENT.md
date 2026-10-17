## Parent qualification: retained-address and late-alias controls (2026-10-17)

Built with Swift6.4.1 release/warnings-as-errors (zero warnings), frozen with matching dSYM
and an ad-hoc Hypervisor signature, and run on MacStudio/macOS27.0.1. All four fresh one-vCPU/
zero-NIC synthetic64MiB profiles passed their native contracts. Collection1.887908s; individual
single .784448s, pages .454603s, preflight-alias .084336s, late-alias .413691s. Original15s limits.

Independent raw audit accepted:
- Every recorded kernel walk covers all64MiB with ZERO holes. After retirement2048 owned
  objects have tag240/RW and2048 placeholders tag241/PROT_NONE, matching max protections.
- A non-overwriting placeholder claim returns KERN_NO_SPACE (3); the placeholder is unchanged.
  Live neighbours and zero/regrowth canaries stay correct.
- Preflight and late-alias negative profiles retain/drop exactly one alias, destroy the actual
  vCPU/VM, and free every owned arena page. Intended-guard refusal, zero bytes retired, no skips
  or native cleanup error.
- Causal BEFORE retains every harness control but omits ONLY the immediate retirement guard.
  It retires2048 pages with the alias held; negative harness returns exit1/determinate=false.
  Restoring that guard refuses ownership-proof(retire) before the first replacement.

Immutable G24 receipts: results/mach-page-safety-before-v1-independent.json and
mach-page-safety-after-v1-independent.json, plus hvf-mach-page-safety-{before,after}-v1 freezes.
No RSS/footprint delta is credited as physical return. Separate owned named-entry controls
prove an ordinary held64MiB object remains fully physically resident despite a32MiB drop in
both task counters after removing half its views.

Private synchronous synthetic mechanism only: no SMP/Linux/ClickHouse/fault-injected native
cleanup or hostile same-task adversary qualification, no public PageMemory/NativeLinuxVMM
adoption. All five product gates OPEN. Historical source-only instructions and predictions
below describe the worker handoff before this parent proof.

# Mach page-object retirement experiment (macOS27 private research)

## Status

This is a private research executable, not a library or production backend. The source-only
worker completed first; the parent then reviewed, compiled with Swift 6.4.1/macOS 27 SDK,
ad-hoc signed, froze the source and matching symbols, and ran both profiles on an M2 Max.
The independent v3 audit accepts the bounded synthetic mechanism only. All five product
gates remain open, and this is not Linux, ClickHouse or autonomous-balloon qualification.

The v3 frozen executable UUID is `F6813D82-2047-38AC-B9D3-9ACB70FD3072`. Both fresh processes
completed with all native cleanup codes zero: single-object 0.429708 s, per-page objects
0.449457 s. Each checked all 4096 initial page reads, 2048 candidate faults before/after
retirement, surviving neighbours and zero-filled regrowth. The per-page alias control refused
reference-count 2 and accepted after the alias was dropped to reference-count 1.

Both profiles lost exactly 32 MiB of task RSS and footprint in the deallocation window
(3.092 ms single, 2.235 ms pages). This does **not** establish physical free-list return or
superior reclamation by per-page objects. A surviving shared object alone does not prove its
unmapped offsets retain physical pages. Only the per-page profile established that every
retired object had no remaining mapping in this task. Object identifiers were recycled on
1937 new allocations: identity comparisons must never span a deallocated object's lifetime.

The invalid v1 and v2 runs remain failures. The parent repaired an inappropriate guest X0
data register by keeping the existing fixed HVC selector in X0 and reading payload in X2;
then repaired an accidentally altered translation-fault mask, preserving the original mask
and every canary. No guard, content or deadline was weakened to obtain v3.

**Safety candidate (this source revision): UNBUILT and UNEXECUTED, PENDING parent proof.** After
the v3 audit the worker added the prerequisite safety mechanisms described under "Safety
candidate" below and two negative modes, `pages-aliased` and `pages-pre-free-aliased`. Nothing
in it has been compiled, signed or run. The v3 observations above were made with the older
retirement (deallocate, leaving an unclaimed hole); they are immutable schema-1 evidence, and
this revision neither reproduces nor supersedes them. Everything concerns one host: no other
Mac was used and no public-framework adoption is proposed.

- Framework adoption and the physical-return hypothesis are **PENDING** further proof and review.
- It is not an optimization, an adoption decision or a qualification. All five product gates
  remain **OPEN**.
- Nothing is adopted into `NativeLinuxVMM` or `PageMemory`, and the production CPUGroup keeps
  its 2ms cadence.
- A synthetic 64MiB pass would be no Linux, ClickHouse or balloon result and would not justify
  general partial-live-object reclaim.

## Safety candidate (UNBUILT, UNEXECUTED, PENDING parent proof)

Why. v3 left every retired slot as an unclaimed hole and proved ownership once, in bulk, before
4096 vCPU runs and 2048 frees. A multi-threaded VMM could have an allocator take a hole, or have
an alias appear between the check and the free. v3 was single-threaded and observed neither;
these are prerequisites for any reuse of the mechanism, not results.

Changes in dependency order. **G** is a guard: it changes what the experiment does to memory or
what it refuses. **H** is harness: it adds a control, a bound or evidence and leaves the
mechanism under test as it was. A BEFORE regression keeps every H and reverts the named G.

1. H. Profiles `pages-aliased` and `pages-pre-free-aliased`: per-page layouts with one fixed
   alias of slot 1; no address or size input; `MachPageProfile.perPage`. The `single` and
   `pages` command lines and behaviour are unchanged.
2. H. Alias ledger. An alias is tracked the moment `mach_vm_remap` succeeds and forgotten only
   when `mach_vm_deallocate` confirms the drop, so a failed drop is never lost.
3. H. `alias-refusal-control` can keep its alias (`pages-aliased`, through the bulk preflight).
   A new `alias-before-first-free` stage (`pages-pre-free-aliased`) creates the alias after the
   bulk proof and the guest probes, immediately before the first retirement.
4. H. Expected-refusal self-check. A negative mode is determinate only if it is refused at its
   expected operation and stage with nothing retired. A negative run that completes is
   indeterminate (exit 1), never a pass, so the control can fail.
5. H. Deadline checks every 128 slots in install, host fill and readback, retirement, refill and
   the verification loops. The one absolute 15 s deadline is never renewed.
6. G. User tags (240 for the reservation and live object maps, 241 for placeholders) and native
   verification of tag and protection on the reservation, installed objects, refilled objects
   and placeholders.
7. G. `retire` repeats the whole per-slot ownership proof immediately before the free:
   identity, offset, exclusive reference for per-page layouts, no shadow, pager or wiring, tag
   and protection. A refusal is `ownership-proof(retire)` and retires nothing further.
8. G. Retirement is one `mach_vm_map(MACH_PORT_NULL, FIXED|OVERWRITE, PROT_NONE, PROT_NONE,
   VM_INHERIT_NONE)` over the 16KiB slot, not a deallocate. The address is never free, so no
   other allocation can take it, and no deallocate-then-reserve window exists.
9. G. The live object identifier is cleared at retirement and kept only in a bounded evidence
   ledger (one entry per slot, never consulted by an ownership decision). The refilled object
   records its own identifier as a new lifetime.
10. G. Placeholder state (object identifier, references, share mode) is recorded from the
    post-retirement walk and must be reproduced before refill (bulk and per slot) and before
    teardown frees it. Refill overwrites only a placeholder the kernel reports unchanged.
11. H. `placeholder-claim-control`: a native claim of an owned placeholder's range with the same
    parameters but without OVERWRITE must fail while it is owned. Nothing is replaced or freed.
12. G. After a confirmed vCPU destroy, teardown tries every retained alias, then guest
    mappings, then the arena (placeholders included) and reports each failure. After an
    unconfirmed destroy it touches nothing and the process retires.

Invariants this revision is meant to establish, all PENDING proof:

- No retired slot is a hole. Every kernel walk of the reservation reports `holeBytes == 0`; after
  retirement `entriesByTag` shows 2048 tag-241 entries, all with protection `0/0`.
- A slot is retired only after a proof taken immediately before; one refusal stops the loop.
- A placeholder is overwritten only while the kernel reports it unchanged. A foreign mapping is
  never overwritten or freed, only left in place and reported.
- A tracked alias is never forgotten without a confirmed drop.
- `physicalReleasedBytes` and `hostFreeListDelta` stay null. Nothing here is a physical release,
  performance or free-list claim, and `single` never proves last-reference retirement: its proof
  cannot enforce a reference count (`referenceExclusivityEnforced` is false there).

What it still does not do. Tags, identifiers and protections detect accidents; they are not
security against hostile code in this task. The proof and the overwrite are separate native
calls, so the check-then-overwrite gap is closed here only because the process is single
threaded. A threaded VMM still needs the owner thread, a quiescent vCPU and one lock shared with
every host accessor of the range. Concurrency, `pages-held`, `single-held`, a larger geometry,
SMP and Linux are future discriminating experiments, not part of this slice.

Expected negative-mode results (predictions to be checked by the parent, not observations):

- `pages-aliased`: `outcome` is `refused: ownership-proof (1 of 2048 candidates: slot 1 is not
  an exclusive 16KiB object (references 2)) at ownership-preflight`;
  `counters.aliasRefusalControl.aliasKeptUntilTeardown` is true; `ownershipPreflight.refusedPages`
  is 1; `retiredBytes` and `ownedRetiredBytes` are null; `cleanup.arenaRelease` shows one alias
  retained and one dropped; `negativeControl.held` and `determinate` are true; exit 0.
- `pages-pre-free-aliased`: the bulk preflight passes with 0 refusals, then `outcome` is
  `refused: ownership-proof(retire) (slot 1 is not an exclusive 16KiB object (references 2)) at
  retire`; `counters.pointOfFreeAlias` shows the alias seen by the proof; `counters.retirement`
  shows 0 retired pages; `kernelEntries.afterRetireFailure.entriesByTag` shows only tag 240 and
  no placeholder; one alias retained and dropped; `negativeControl.held` and `determinate` true;
  exit 0.
- BEFORE regression for `pages-pre-free-aliased`: with the item 7 proof removed from
  `MachPageArena.retire` and every H kept, the first retirement is expected to proceed over the
  aliased object, the run to reach `completed`, `negativeControl.held` to be false and the exit
  status to be 1. For `pages-aliased` the corresponding BEFORE is the v3 harness (`keep: false`).

## Question and hypothesis

The native Linux VM currently reclaims whole 2MiB cold Mach objects after the Linux classic
balloon owns every guest PFN in that object. A prior actual Linux/ClickHouse run returned only 403488768 resident bytes within the
unchanged 8 s interval, below its 1 GiB requirement. Compression and incomplete object
ownership are distinct possible limits; the present synthetic test does not resolve them.

**Hypothesis (not fact):** independent 16KiB named Mach objects in one contiguous host
virtual range let one host page be physically retired without retaining the unmapped page
inside a larger, still-live VM object.

The experiment must prove or falsify, with raw kernel evidence:

- kernel object identity (distinct objects, reference counts) after install, unmap, retire and
  refill;
- HVF support for one contiguous mapping over many Mach objects, for unmapping a 16KiB
  sub-range of it, and for mapping a fresh 16KiB object at the same guest address;
- exclusive-ownership and alias limits (what the ownership proof can and cannot establish);
- resident bytes, task footprint, page dispositions and return timing around the retirement;
- neighbour canary integrity, and a guest fault (not a stale translation) on retired pages.

It must **not** claim physical return or a global free list from lower RSS or unmapped
virtual addresses alone. `physicalReleasedBytes` and `hostFreeListDelta` are always `null`.

## Command

```sh
hvf-memory-lab mach-page-objects <new-result.json> <single|pages|pages-aliased|pages-pre-free-aliased>
```

Exactly three arguments after the program name. The parent runs each profile in a **fresh
process**. No address, size, guest image, Linux kernel, initramfs, disk or NIC is accepted or
read. An unknown profile fails with `Failure.arguments` before the result path is reserved.
`single` and `pages` keep their original command lines.

| Profile                  | Host objects behind the 64MiB range                   | Role                  |
| ------------------------ | ----------------------------------------------------- | --------------------- |
| `single`                 | one 64MiB named Mach object                           | shared-object control |
| `pages`                  | 4096 independent 16KiB named Mach objects, contiguous | hypothesis under test |
| `pages-aliased`          | as `pages`; alias kept through the preflight          | negative mode         |
| `pages-pre-free-aliased` | as `pages`; alias made just before the first free     | negative mode         |

Both negative modes are per-page layouts with a fixed alias of slot 1 (the first candidate).
Each expects one refusal and zero retired backing (see "Safety candidate"); a run that completes
or stops anywhere else is indeterminate and exits 1.

The binary is built, signed with `hypervisor.entitlements` and strict-verified exactly as in
`README.md`; the Embedded guest image is not needed.

Result path: it must not exist in any form. It is created before any native effect with
`O_WRONLY|O_CREAT|O_EXCL|O_NOFOLLOW|O_CLOEXEC`, mode `0600`, by the reviewed `EvidenceFile`.
The JSON is bounded to 64KiB, written once at the end, and the descriptor close is checked.
A process killed earlier leaves an empty file, which means no evidence.

Exit status and stdout:

- `0`: determinate. The outcome is `completed`, or a recorded native or ownership `refused`
  (for a negative mode only its expected refusal), and every cleanup step is verified. stdout is
  `HVF_MACH_PAGE_OBJECTS_COMPLETE profile=<profile> <outcome>`.
- `1`: a refused result path (nothing is written), or an `invalid` outcome, an expired
  deadline, a cleanup failure, or a negative mode whose control did not hold (it completed or
  was refused elsewhere). stdout is `HVF_LAB_FAIL ...`; the evidence is written first when the
  path was reserved.
- `2`: the vCPU destroy was not confirmed. Evidence is written first, nothing is unmapped,
  stdout is `HVF_MACH_PAGE_RETIRE ...` (and `HVF_MACH_PAGE_EVIDENCE_FAIL ...` if the write
  failed), then `_exit(2)`.

An external parent watchdog is required. `hv_vm_create`, `mach_vm_*`, `hv_vcpu_run`,
`hv_vm_destroy` and friends are kernel calls that cannot be interrupted from inside the
process. The internal deadline is one absolute 15s instant computed before the experiment
starts; it is checked at stage starts and, every 128 slots, in the object install, host fill and
readback, guest unmap and map, retirement, refill and verification loops, and is never renewed.
Each native call inside those loops still relies on the parent watchdog. Kernel walks
(`entries`) are bounded by the fixed geometry rather than checked mid-walk. Teardown is not
gated by the deadline.

## Source layout

All of it lives in the executable target `Sources/hvf-memory-lab/`; nothing is exported by a
library product.

- `MachPageArena.swift`: the profiles, fixed geometry and tags, the canary, every raw Mach call
  (`MachPageKernel`, including the placeholder primitive) and the arena that owns the
  reservation, the objects, the placeholders, the retained aliases and the guest mapping.
- `MachPageGuest.swift`: the two-instruction EL1 reader and its exit classification (unchanged
  by the safety candidate: fixed X0 `0x41`, X2 payload and the `0x04` translation mask stay).
- `MachPageObjects.swift`: the stage driver (including the negative-mode harness and its
  expected-refusal check), measurements, teardown, evidence and the `mach-page-objects` entry
  point.
- `main.swift`: the early dispatch above, and file-private to internal promotions for
  `Failure`, `check`, `Region`, `Machine` and `EvidenceFile`, so the reviewed VM, code-page and
  evidence-file ownership is reused rather than copied. Existing modes and the pre-entry
  experiment are unchanged.

## Fixed geometry

| Item                     | Value                                                         |
| ------------------------ | ------------------------------------------------------------- |
| Host page size           | must be 16384 (checked first; `Failure.geometry` otherwise)   |
| Data range               | 64MiB = 4096 slots of 16KiB, guest address `0x40000000`       |
| Code page                | one 16KiB page at guest address `0x100000`                    |
| Retirement pattern       | odd slots: 2048 pages = 33554432 bytes. Even slots stay live  |
| vCPU / NIC               | 1 / 0. No Linux kernel, initramfs or disk                     |
| Canary                   | deterministic 64-bit word per (slot, word index), recomputable |

The 64MiB first touch is **workload preparation**, not a result. The host writes every word
of every page through the Mach mapping before the guest sees it, and the experiment records
that. No extra host RAM is allocated to obtain a green return: no warming, purge, sysctl write
or allocator change is made (the sysctls are only read, as in the reviewed lab).

Guest program: `ldr x2, [x1]` (`0xf9400022`) then `hvc #0` (`0xd4000002`) at `0x100000`. Per
read the host sets PC, CPSR `0x3c5` (EL1h, DAIF masked, as in the pre-entry qualification),
X0 to the fixed return selector0x41, X2 to a sentinel and X1 to the address, then calls `hv_vcpu_run` once and reads PC and X2 back.

- Value read: exception class `0x16`, immediate 0, PC `0x100008` (HVF reports the PC after the
  HVC, as established by the pre-entry qualification). X2 is the loaded word.
- Fault: exception class `0x24` (data abort from a lower level), `syndrome & 0x3c == 0x04`
  (translation), WnR 0 (read), the same 4KiB frame, PC and X2 unchanged. Whether HVF reported
  the exact address is recorded, not required.
- Anything else is `unexpected` and fails the pass with the raw syndrome, PC, X2 and address.
- `SCTLR_EL1` and `VBAR_EL1` are not written, so the guest runs in the reset state, as in the
  reviewed lab; host canary visibility therefore relies on the coherency that lab already
  observed.

## Protocol

All calls are sequential on the thread that created the VM and its only vCPU. Stage names
are the `phases` entries of the evidence.

1. `geometry`: the host page size is 16KiB.
2. `vm-and-code-page`: `hv_vm_create`; the code page through `Machine.allocate` (RW load,
   `sys_icache_invalidate`, `hv_vm_protect` R+X before any vCPU exists, host alias read-only,
   instruction-word read-back).
3. `vcpu`: `hv_vcpu_create` on the owner thread, virtual timer masked.
4. `arena-install`: reserve 64MiB with `mach_vm_allocate(ANYWHERE)` and user tag 240, and
   require the kernel to report it as one read/write entry with that tag (otherwise the range is
   returned and the run is `invalid`). Then overlay the named objects
   (`mach_make_memory_entry_64` with `MAP_MEM_NAMED_CREATE`, `mach_vm_map` with
   `FIXED|OVERWRITE` and tag 240) strictly inside that reservation. Each temporary port is
   released right after its map call.
5. `identity-after-install`: a `mach_vm_region_recurse` walk. `single` must be one entry, one
   object, one reference. Per-page profiles must be 4096 entries, 4096 distinct object ids, one
   reference each, which also shows that the ports were released. Every entry must carry tag 240
   and read/write protection. Dispositions before first touch.
6. `first-touch`: the host fills and reads back the canary (workload preparation).
7. `guest-map`: one `hv_vm_map` of the whole 64MiB. HVF may refuse; that is a finding.
8. `guest-baseline`: the vCPU reads word 0 of all 4096 slots.
9. `pre-retire-observation`: task counters, dispositions and a kernel walk.
10. `guest-unmap-candidates`: `hv_vm_unmap` of each odd 16KiB sub-range, before any host free.
    HVF may refuse a partial unmap; that is a finding.
11. `alias-refusal-control` (per-page profiles): see the alias contract. `pages-aliased` keeps
    the alias.
12. `ownership-preflight`: every candidate must pass the ownership proof before any is retired.
    It records `referenceExclusivityEnforced` (false for `single`).
13. `guest-probe-unmapped`: every candidate read faults (no stale translation) and every
    neighbour reads its canary.
14. `alias-before-first-free` (`pages-pre-free-aliased` only): the alias of slot 1 is made now,
    after the bulk proof and the probes, and must change what the proof reports.
15. `retire`: for each candidate, in one pass, the whole ownership proof is repeated and then
    the slot is replaced by a placeholder with one `mach_vm_map(MACH_PORT_NULL,
    FIXED|OVERWRITE, VM_PROT_NONE, VM_PROT_NONE, VM_INHERIT_NONE)` carrying tag 241. This is
    measured between two task samples (its loop time includes the per-slot proofs and is not
    comparable with v3's bare deallocation loop), then 21 timeline samples 10ms apart. A refusal
    ends the loop, and a kernel walk (`afterRetireFailure`) shows what was and was not replaced.
    Afterwards, in this stage: the walk must show every candidate as one exact 16KiB entry with
    tag 241, no access and no pages, whose first observation is recorded (the placeholder
    state); no candidate may be a hole; neighbours must keep their object ids; and the host
    compares every neighbour word to its canary.
16. `guest-probe-retired`: candidates fault again and neighbours read their canary.
17. `placeholder-claim-control`: a non-overwriting `mach_vm_map` of slot 1's range with the
    placeholder's own parameters must fail (`KERN_NO_SPACE` expected, any failure accepted and
    recorded) and the placeholder must be unchanged. Only when this passes is `ownedRetiredBytes`
    set.
18. `refill`: a bulk walk must show every candidate still exactly its recorded placeholder. Each
    slot is then proven again immediately before a fresh named 16KiB object replaces it with
    `FIXED|OVERWRITE` (tag 240). Every refilled object must be exclusive, at object offset 0,
    tagged and read/write, and unlike any live neighbour. Dispositions are recorded before any
    read.
19. `guest-map-refill`: `hv_vm_map` of each refilled 16KiB sub-range.
20. `guest-verify-refill`: the guest reads the first and last word of each refilled page (both
    must be zero) and one neighbour word; the host then compares all refilled pages to zero and
    all neighbours to their canary.
21. Teardown (not a stage): see the teardown order below.

The timeline interval is an observation cadence only; no acceptance depends on it and it is
bounded by the same deadline.

## Ownership, cleanup and alias contracts

- **One owner thread.** Every arena mutation and every guest read first calls the reviewed
  `Machine.confined()`, which refuses a foreign thread and refuses while `Machine.running` is
  set. `running` is set only around `hv_vcpu_run`, so Mach and HVF mappings change only while
  the vCPU is outside it. There is no second thread, timer or worker.
- **Allocator separation.** Arena memory (reservation, object maps and placeholders) is Mach
  memory and is released only with `mach_vm_deallocate`. `hv_vm_deallocate` is applied only to
  the code page that `Machine.allocate` obtained from `hv_vm_allocate`, and never to anything
  else. The code page, the data objects and the placeholders stay distinct mappings.
- **Reservation first.** The whole virtual range is owned (and verified as one tagged entry)
  before any overlay, and overlays land only inside it. `OVERWRITE` is used for the first
  install, for retirement over a slot whose per-slot proof has just passed, and for refill over
  a placeholder the kernel has just reported unchanged. It is never used on a mapping that was
  not proven to be this arena's.
- **Placeholders, not holes.** A retired slot is atomically replaced by an anonymous
  `PROT_NONE` mapping (tag 241, maximum protection `PROT_NONE`, inheritance none). The address
  is never free, so another allocation cannot take it, and the experiment never deallocates and
  then reserves. The kernel's first report of each placeholder (object identifier, references,
  share mode) is recorded and must be reproduced before refill and before teardown frees it. A
  placeholder that no longer verifies is left in place and reported; a foreign mapping is never
  overwritten or freed. This is unverified until the parent runs it: that the overwrite drops
  the old mapping's reference inside the same call is inferred from kernel behaviour.
- **Retirement order.** HVF unmap, guest fault proven, bulk ownership proof, guest probes, then
  for each slot the proof again and the atomic placeholder replacement, guest fault proven
  again, a kernel walk that records the placeholders, and the claim control. A page that is
  still guest-mapped is never retired.
- **Ownership proof (per candidate, bulk and again at the point of free).** One plain map entry
  covers it; it has the arena's tag and read/write protection; its object id equals the live
  one recorded for the slot; its object offset is the expected one; no shadow, pager or wiring.
  For per-page profiles it must also be an exclusive 16KiB entry with exactly one reference.
  The bulk proof is all-or-nothing: one refusal ends the run as `refused` with nothing retired.
  The point-of-free proof refuses with `ownership-proof(retire)` and retires nothing further.
  For `single` a reference count cannot prove exclusivity, because the object is shared by
  construction; its proof never implies that a retired offset held the last reference, and
  `single` stays an explicitly shared control.
- **Identifiers.** A slot's live object identifier is cleared when the slot is retired and the
  refilled object records its own. The retired identifiers sit in a bounded evidence ledger
  (one entry per slot) used only for evidence such as identifier reuse; no ownership decision
  reads it, because identifiers are recycled.
- **Alias contract.** No intentional alias exists except the bounded controls in the per-page
  profiles: a `mach_vm_remap(copy: false)` alias of slot 1 (not guest-mapped), at most one at a
  time. While it exists the ownership proof must refuse. In `pages` and `pages-pre-free-aliased`
  the first control drops it and the proof must then accept. In `pages-aliased` it is kept
  through the bulk preflight. In `pages-pre-free-aliased` a second one is made after the bulk
  proof and the guest probes, and the point-of-free proof must refuse it. An alias is recorded
  the moment its creation succeeds and leaves the ledger only when the kernel confirms its
  deallocation, so a failed drop is still known to teardown. The aliased page is never retired
  and no shared object is remapped. A control that does not behave this way ends the run as
  `invalid` before any retirement.
- **Teardown order.** `hv_vcpu_destroy` must return success first. If it does not, the process
  is retired: evidence is written, no alias, mapping or placeholder is touched under a possibly
  live CPU, and `_exit(2)`. Otherwise: every retained alias is tried, then guest unmaps, then
  deallocation of the arena (live slots and verified placeholders; guest-mapped slots and
  unverified placeholders are skipped and reported), then `Machine.close()` (code page, then
  `hv_vm_destroy`). No step stops the next, every failure is collected in `cleanupErrors`, and
  cleanup is claimed only when none occurred.
- **Independent failures.** The primary failure (`primaryError` or `refusal`) and the cleanup
  failures (`cleanupErrors`) are recorded separately. A VM whose creation failed is never
  destroyed.

## Evidence (schema 2)

Schema 2 replaces schema 1 because retirement no longer deallocates. The v3 files are schema 1
and are never rewritten or reinterpreted; a validator must key on `schema`. Renamed or replaced
fields: `deallocatedBytes` is now `retiredBytes`; in `counters.retirement`, `deallocatedPages`,
`deallocatedBytes` and `deallocationLoopNanos` are now `retiredPages`, `retiredBytes` and
`retirementLoopNanos`; in `counters.retirementChecks`, `candidatePagesAbsentFromKernelWalk` is
replaced by `candidatePlaceholdersVerified`, `candidatePlaceholdersRefused` and
`candidateHolesInKernelWalk` (must be 0), and `candidatePagesWhoseObjectIsStillMappedElsewhere`
is now `candidateOldObjectsStillMappedInArena` (the walk covers the arena only).

One JSON object, sorted keys, at most 64KiB. If it does not fit it is written compactly, then
without `kernelEntries` and `phases` (`evidenceReduced: true`), then as a stub
(`evidenceError: true`). Unknown values are `null`; no counter is replaced by zero. Native codes
are signed decimals.

Verdict fields: `outcome` (`completed`, `refused: <operation> (<code or detail>) at <stage>`
or `invalid: <stage>: <error>`), `determinate`, `negativeControl` (null for `single` and
`pages`; otherwise the expected operation and stage and whether the control `held`),
`stageAtEnd`, `phases`, `primaryError`,
`refusal` (`operation`, `nativeCode`, `detail`, `stage`), `vmCreateCode`, `cleanupErrors`,
`cleanup` (`vcpuDestroyCode`, `arenaRelease`, `aliasesKeptForProcessRetirement` on the
retirement path, `machineCloseErrors`, `vmRemains`),
`processRetired`, `processRetirementReason`, `hostDeadlineSeconds`, `hostDeadlineExpired`,
`elapsedNanos`. `determinate` is true only when there is no primary error, no expired
deadline, no retirement, no cleanup error, a negative mode held its control, the VM is
destroyed and the arena is released (no alias retained, no placeholder skipped).

Context: `status`, `confidence`, `scope`, `retirementMechanism`, `hypothesis`, `geometry`,
`fixture`, `interpretation`, `unknowns`, `notExecuted`.

Measurements:

- `kernelEntries.<label>` for `afterInstall`, `afterGuestMap`, `beforeRetire`,
  `afterGuestUnmap`, `afterRetire`, `afterRetireFailure` (only when a retirement was refused),
  `afterRefill`, `afterRefillGuestMap`, `afterRefillVerify`: entry count, mapped and hole bytes
  (zero in every walk), distinct non-zero object ids, entries without an object, entries per
  reference count (1, 2, other), entries per user tag (240 arena objects, 241 placeholders),
  per `protection/maximum` pair and per raw `share_mode` (recorded, not judged), resident,
  paged-out and wired pages as reported by the entries, and the first and last two entries
  (arena offset, length, object offset, object id, references).
- `pageDispositions.<label>` for `afterInstallBeforeFirstTouch`, `afterFirstTouch`,
  `beforeRetire`, `afterRetireLivePagesOnly`, `afterRefillBeforeGuestRead`, `afterRefillVerify`:
  pages queried, present, paged-out-or-compressed, reusable, fictitious/copied/external.
  Only live object slots are queried, so after retirement the query describes live pages only.
- `processMemory.<label>`: resident bytes and task footprint, plus an unattributed host-wide
  sample at `start` and `afterTeardown`.
- `guestChecks.<pass>` for `baselineAllPages`, `candidatesAfterGuestUnmap`,
  `neighboursAfterGuestUnmap`, `candidatesAfterRetire`, `neighboursAfterRetire`,
  `refilledFirstWord`, `refilledLastWord`, `neighboursAfterRefill`: reads, matched, mismatched,
  faults with exact address, elapsed, up to four mismatch examples.
- `counters`: `install`, `firstTouch`, `guestMap`, `guestUnmap`, `aliasRefusalControl`,
  `ownershipPreflight`, `pointOfFreeAlias` (`pages-pre-free-aliased` only), `retirement`,
  `retirementChecks`, `placeholderClaimControl`, `placeholdersBeforeRefill`, `refill`,
  `guestMapRefill`, `hostVerifyAfterRefill`, `totalVCPURuns`.
  `aliasRefusalControl` and `pointOfFreeAlias` hold whether the alias was kept, the references
  seen while it existed, whether the proof refused it and, if it was dropped, whether the proof
  then accepted. `ownershipPreflight` adds `referenceExclusivityEnforced`.
  `retirement` holds the mechanism, retired pages and bytes, the loop time (which includes the
  per-slot proofs), resident and footprint before, after and delta, host counters before and
  after, the unattributed free-page delta, the timeline and a few retired identifiers from the
  evidence ledger. `retirementChecks` holds verified and refused placeholders, candidates that
  are holes (must be 0), retired objects whose identifier is still mapped by a non-placeholder
  arena entry, neighbour identity mismatches and neighbour canary mismatches.
  `placeholderClaimControl` holds the native code of the refused claim (`KERN_NO_SPACE`
  expected) and whether the placeholder was unchanged afterwards.
- `retiredBytes`: successful atomic placeholder replacements, each after its own proof (null
  before retirement starts). `ownedRetiredBytes`: set only after every retirement post-condition
  held, including the claim control, otherwise `null`. Both are virtual-range ownership, not
  deallocation and not physical release. `physicalReleasedBytes` and `hostFreeListDelta`:
  `null`.

### Independent acceptance of a `completed` pages run (schema 2)

The parent validator should read only the raw JSON, not `determinate`. All must hold:
`schema == 2`, `outcome == "completed"`, `primaryError == ""`, `refusal == null`,
`cleanupErrors == []`, `hostDeadlineExpired == false`, `processRetired == false`,
`cleanup.vcpuDestroyCode == 0`, `cleanup.vmRemains == false`,
`cleanup.arenaRelease.errors == []`, `hostPagesSkipped == 0` and
`aliasesRetained == aliasesDropped`; `kernelEntries.afterInstall` has 4096 entries, 4096
distinct ids, 4096 single-reference entries, tag 240 on all and protection `3/3`;
`holeBytes == 0` in every walk; `counters.firstTouch.hostReadbackMismatchedWords == 0`; every
`guestChecks` pass has `mismatched == 0` and the expected read count (4096 for the baseline,
2048 for the others); `counters.ownershipPreflight.refusedPages == 0`;
`counters.retirement.retiredPages == 2048`; `kernelEntries.afterRetire` has 2048 tag-241 entries
with protection `0/0`; `retirementChecks` shows 2048 verified placeholders, 0 refused, 0 holes,
0 old objects still mapped in the arena and zero mismatches; `counters.placeholderClaimControl`
has `claimRefusedWhileOwned` and `placeholderUnchangedAfter` true;
`ownedRetiredBytes == 33554432`; `counters.refill` has 2048 pages and zero identity mismatches;
`counters.hostVerifyAfterRefill` has zero non-zero refilled words and zero neighbour canary
mismatches; `physicalReleasedBytes == null`. For `single` the install check is one entry and
one object, `referenceExclusivityEnforced` is false and
`candidateOldObjectsStillMappedInArena` is expected to equal 2048; no last-reference conclusion
may be drawn from it. (The protection value `3/3` is `VM_PROT_READ|VM_PROT_WRITE` for both
fields; the validator should derive it from the SDK values rather than trust this note.)

### Acceptance of a negative mode (schema 2)

Raw JSON again: `negativeControl.held == true`, `primaryError == ""`, `processRetired == false`,
`cleanupErrors == []`, `retiredBytes` null (`pages-aliased`) or 0 (`pages-pre-free-aliased`),
`ownedRetiredBytes == null`, `cleanup.arenaRelease` with one alias retained and one dropped,
and `refusal.operation` / `refusal.stage` equal to `ownership-proof` / `ownership-preflight`
(`pages-aliased`) or `ownership-proof(retire)` / `retire` (`pages-pre-free-aliased`). A negative
run whose `outcome` is `completed` fails its control even if it exited cleanly.

## Reading the result

- The hypothesis is supported only when a `pages` run is `completed`, every check above holds,
  and its accounting differs from `single` as predicted. It is falsified for this host by, for
  example, HVF refusing the multi-object mapping or the partial unmap, HVF keeping a reference
  after unmap (an `ownership-proof` refusal), or accounting no different from `single`.
- Resident bytes and task footprint are accounting views, and how XNU accounts footprint for
  unmapped pages of a live shared object is unknown. `single` may or may not show a smaller
  footprint while its object could still hold the pages; a kernel walk of mapped ranges cannot
  see such pages. Never read either profile alone, and never read the free-page counters as
  attribution.
- Compressed or paged-out pages are findings, not failures.
- A placeholder-based pass shows address-space ownership only. It says nothing about frames:
  a `retiredBytes` or `ownedRetiredBytes` value is never a physical release, and equal RSS or
  footprint drops in `single` and `pages` (as in v3) remain accounting, not attribution.
- A negative mode is evidence about the guard only when it is refused where expected. Do not
  read a clean exit of a negative run without `negativeControl.held`.
- Even a clean `pages` result is one synthetic 64MiB observation. It needs repetition by the
  parent, a Linux integration test, and review before anything is adopted.

## Limitations and unsupported cases

- Not executed: Linux kernel, initramfs, disks, NIC; the classic or free-page-reporting
  balloon; guest-driven PFN ownership; SMP, `hv_vcpus_exit`, timers or a second thread; DMA,
  virtio or any device access to the arena; host memory pressure or forced compression; repeated
  runs, soak, contention or power events; scale beyond 64MiB.
- Retired slots are claimed by placeholders, but the proof and the overwrite are separate native
  calls. Single-threaded here, nothing can intervene; a threaded VMM would still need one lock
  shared by this arena and every host accessor, and a vCPU rendezvous around unmap and free until
  a multi-vCPU stress shows it is unnecessary. Whether `hv_vm_unmap` returns only after every
  running vCPU's stage-2 translations are gone is undocumented and not tested here.
- Tags, identifiers and protections detect accidents; they do not stop hostile same-task code.
- The placeholder primitive is untested: whether the overwrite drops the old reference inside
  the same call, what a never-touched `PROT_NONE` entry reports (object, references, share
  mode), and whether entries stay one per slot are all unverified until the parent runs it.
- Kernel and stage-2 cost of one map entry per 16KiB is measured at 4096 entries only
  (131072 per 2GiB).
- Whether any retired page reached the global free list is not observable from this process.
- One host, one OS build, one run per profile is not a distribution.

## Compile assumptions and API uncertainty

The v3 sources compiled in the parent's build. The symbols introduced by the safety candidate
(listed first) were not compiled or run in the authoring session, which had no shell, so they
are unverified until the parent builds. The reviewed `MemoryDevice` and `Machine` already use
`mach_vm_remap`, `mach_vm_region_recurse` (with `object_id_full`, `ref_count`, `pages_resident`,
`pages_swapped_out`, `pages_wired`, `user_wired_count`, `shadow_depth`, `external_pager`,
`is_submap`, `offset`), `mach_vm_page_range_query`, `mach_vm_protect`, `hv_vm_*` and
`host_statistics64`.

New in the safety candidate, and therefore the first things to compile-check:

- `vm_region_submap_info_data_64_t` fields `protection`, `max_protection`, `user_tag` and
  `share_mode` (expected `vm_prot_t`, `vm_prot_t`, `UInt32`, `UInt8`; converted with
  `truncatingIfNeeded`).
- `VM_MEMORY_APPLICATION_SPECIFIC_1` (240) and `_2` (241) imported as integer macros and passed
  through `UInt32(...)`; the flag value `Int32(bitPattern: tag << 24)` is the public
  `VM_MAKE_TAG` encoding under `VM_FLAGS_ALIAS_MASK` `0xFF000000`. `mach_vm_allocate` and
  `mach_vm_map` are expected to accept it in `flags`; `mach_vm_remap` is not given a tag.
- `mach_vm_map(task, &address, size, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE | tag,
  mach_port_t(MACH_PORT_NULL), 0, 0, VM_PROT_NONE, VM_PROT_NONE, VM_INHERIT_NONE)`: that
  `MACH_PORT_NULL` and `VM_PROT_NONE` import, that the object argument accepts a null port for
  anonymous memory, and that `FIXED|OVERWRITE` replaces a mapped slot atomically. The same
  call without `OVERWRITE` is expected to return `KERN_NO_SPACE` over a placeholder.
- `KERN_NO_SPACE` imports as an integer comparable to `kern_return_t`.
- The retained alias ledger uses only calls v3 already compiled (`mach_vm_remap`,
  `mach_vm_deallocate`).

Carried over from v3 (compiled there; kept for the record):

- `mach_make_memory_entry_64(task, &size, 0, MAP_MEM_NAMED_CREATE | VM_PROT_READ |
  VM_PROT_WRITE, &port, 0)`: the types of `size` (`memory_object_size_t`), the permission
  argument and the port, and whether the SDK marks it deprecated (the CI build uses
  `-warnings-as-errors`).
- `mach_vm_map(task, &address, size, 0, VM_FLAGS_FIXED | VM_FLAGS_OVERWRITE, port, 0, 0,
  VM_PROT_READ | VM_PROT_WRITE, VM_PROT_READ | VM_PROT_WRITE, VM_INHERIT_NONE)`: flag, protection
  and inheritance types, and the `FIXED|OVERWRITE` semantics over a mapped reservation. Every
  object map now uses `OVERWRITE` (install and refill), so the destination must be proven first.
- `mach_port_deallocate` of the returned send right releases the named entry at once (the
  `pages` reference-count check depends on it; a delayed release would show up as two
  references right after install, with no sleep added to hide it).
- `main.swift` promotes `Failure`, `check`, `Region`, `Machine` and `EvidenceFile` from
  file-private to internal so the new files reuse the reviewed VM and code-page ownership. This
  is confined to the executable target; no library product, `Package.swift`, `Tools`,
  `NativeVMM` or framework source changes.
- The executable target now has several source files while `main.swift` keeps its `@main`
  entry. The same shape (several files, `@main` inside `main.swift`) exists in
  `vz-balloon-lab`, which CI builds, and in `linux-memory-guest`; it was not compiled here.
  If this toolchain rejects it, the entry point must move, which is a decision for the parent.

Primary API references (parent-checked):
<https://developer.apple.com/documentation/kernel/1585405-mach_make_memory_entry_64> and
<https://developer.apple.com/library/archive/documentation/Darwin/Conceptual/KernelProgramming/vm/vm.html>.

## Parent qualification checklist

- Build in an isolated owned directory as CI does (`swift build --package-path
  Examples/HypervisorMemoryLab -c release --jobs 2 --product hvf-memory-lab
  -Xswiftc -warnings-as-errors`). Fix compile errors without weakening any acceptance check.
- Sign a copy with `hypervisor.entitlements` and strict-verify it.
- Run `single`, `pages`, `pages-aliased` and `pages-pre-free-aliased` each in a fresh process
  under an external watchdog, with an absent result path. Confirm a second run with the same
  path is refused without changing its bytes.
- Verify after exit codes `1` and `2` that no `hvf-memory-lab` process remains.
- Validate the raw JSON independently (see above) and keep negative evidence, including
  `refused` and `invalid` runs.
- Build the BEFORE regression for `pages-pre-free-aliased` by reverting only guard 7 (the
  per-slot proof in `MachPageArena.retire`) and keeping every harness change. The control must
  then fail visibly (`completed`, `negativeControl.held == false`, exit 1); if it still exits 0
  the control cannot discriminate. Keep both result files; v3 files stay untouched.
- Repeat on a quiet host, record memory pressure and compressor state, and compare `pages`
  against `single` before any conclusion.

## Retained first hardware failure

The first signed v1 experiment created the requested objects and HVF mappings in both profiles,
but failed20 of4096 baseline guest reads in each. All native cleanup succeeded. The first four
failed canary words have low32bits0xc1......; their HVC did not return the requested canary
and the subsequent exit showed X0=0xffffffff/PC0x200. Arbitrary data must not serve as the
hypercall selector. The candidate reader now loads X2 and keeps X0 fixed at0x41, as the earlier
qualified control does. No canary bits are masked or changed; every original page is still
checked. V1 failures remain failures. The corrected candidate still needs actual qualification.
