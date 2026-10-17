## Original pinned-dependency result: diagnostics accepted, RAM gate still failed

The original swift-protobuf1.38.1 set passed all137 strictrelease tests (169.558720s including
compile,17.270s test execution). Frozen v2 then ran ONE fresh same2CPU ClickHouse profile:
33.252169s native,53.310539s collector. It FAILED the unchanged >=1GiB resident-return gate
(`autonomous resident return timed out`). Do not retry it to obtain green or credit the prior
1.39 run as original-dependency RAM qualification. No causal dependency attribution is made.

The new diagnostic DID reach its real consumer: one completed positive->zero sample,
25,084ns/0drops/0recordfailures. Complete aligned ownership units16KiB123342,64KiB30073,
128KiB14706,512KiB3393,2MiB662. Metadata pins and residency remain unfiltered. Current
2MiB retirement removed1324MiB logical backing; kernel pre-retirement observations were
671.609375MiB resident and651.390625MiB compressed/paged-out logical backing, with304 of662
objects already showing0resident. The compressed logical count is NOT physical RAM credit.
The strict threshold failure is therefore retained while the observation feature is useful.

All actual2vCPUs joined/destroyed, VM cleanup succeeded, no OOM/swap/lease/quarantine or native
cleanup error, finalowned/actual/target/pending0; originalbase8GiBSHA+metadata and bootinputs
unchanged. No post-failure workload-integrity or idle-success claim. All five gates OPEN.
Read-only diagnostic source may be committed independently; no named-purgable backend or
production adoption follows. Historical earlier pin-hold/status below are retained as history.

## Dependency provenance hold

The first passing137-test and actual2CPU v1 receipts below used an unintended private resolver
refresh from swift-protobuf1.38.1 to1.39.0, found before main import. Only that pin changed;
its actual1.39 lock is retained in the v1 frozen source. Parent restored1.38.1 and is rerunning
with --force-resolved-versions before promotion. These v1 observations remain real evidence,
but are not qualified as the original pinned dependency set. No production/main change.

## Parent qualification (2026-10-17)

The exact source passed the full unfiltered137-test release suite, warnings-as-errors with
zero compiler warnings, including independent Set-oracle and maximum3GiB geometry cases.
Cold private-worktree build499.791500s, actual test execution18.117s; no concurrent VM.
Parent also named the local SwiftOSPrimitives package explicitly, matching the Hypervisorlab
pattern, to avoid SPM deriving identity from arbitrary worktree directory names. The original
manifest-resolution failure is retained; it occurred before compilation, not a test failure.

Frozen source/binary/dSYM/signature then ran the original TWO-vCPU autonomous random-string
ClickHouse profile with unchanged8s pulse,2GiBtarget,512MiBreserve,>=1GiB resident-return and
idle/resource/integrity gates. Actual VM74.887218s, complete collector97.392653s, both cycles
accepted (1300MiB/1136MiB reported retired resident backing), SQL/canary/integrity/network checks,
all actual vCPU joins/native destruction/VM cleanup, zero finalPFNs/target/pendingrecycling,
no OOM/swap/quarantine/lease failure. IdleCPU1.881054s,29samples,no pulse/request. Original8GiB
base contentSHA+metadata and boot inputs unchanged. All effects stayed in the private fixture.

Two actual positive->zero samples, no drops/failures,25,458ns and29,708ns scan times:

| Complete ownership upper bound | Pulse1 MiB | Pulse2 MiB |
|---|---:|---:|
| 16KiB units | 1871.484375 | 2012.609375 |
| 64KiB units | 1827.8125 | 1928 |
| 128KiB units | 1786 | 1862.25 |
| 512KiB units | 1643 | 1663.5 |
| 2MiB units | 1300 | 1136 |

These are aligned PFN ownership upper bounds at zero publication, not per-unit resident or
pin-filtered memory, and not pulse peaks. They justify comparing intermediate granularities;
they do not choose a production geometry or measure kernel-object/port overhead. The counters
never cause a reclaim decision. This run used the ORIGINAL anonymous/hv_vm_deallocate backend,
not the separately pending named-purgable backend. The new journal does not prove that latter
backend's SMP/Linux behavior. Global physical free-list attribution remainsNULL.

Immutable G24 receipts: native-balloon-coverage-full-v2.json, frozen-native-balloon-coverage-v1-
source-and-symbols.json, balloon-coverage-two-v1-independent.json and granule-analysis.json.
All five product gates stay OPEN; no production or installed-runtime adoption. Historical
source-only status and pending instructions below describe the initial worker handoff.

# Balloon granule coverage diagnostic

**Status: source-only. Nothing here has been built, tested or executed.** All five
product gates remain open. There is no Linux workload, physical RAM, product GO or
Rust claim in this document, and no anotherMac evidence.

## Question

The classic ledger owns 4 KiB PFNs, but only whole 2 MiB backing objects can be
retired today. A private 64 MiB Mach experiment (reported separately, not repeated
here) showed that 16 KiB objects can retire, yet both its control and page-backed
runs lost 32 MiB of RSS/footprint, so physical superiority is unknown. Splitting
the 2560 MiB (or 3 GiB) dynamic region into up to 196,608 kernel objects should wait
for real data: how often do the stock driver's PFN sets completely cover aligned
units? The guest page size is not rewritten on an assumption about that answer.

This slice measures **ownership distribution only**. It cannot know residency or
per-page pinning.

## What is counted

For the dynamic region only (boot PFNs are excluded), the number of naturally
aligned units whose every 4 KiB PFN is currently in the ledger bitmap:

| Unit | PFNs | Max at 2560 MiB | Max at 3 GiB |
|---|---|---|---|
| 16 KiB | 4 | 163,840 | 196,608 |
| 64 KiB | 16 | 40,960 | 49,152 |
| 128 KiB | 32 | 20,480 | 24,576 |
| 512 KiB | 128 | 5,120 | 6,144 |
| 2 MiB | 512 | 1,280 | 1,536 |

The dynamic base `0x1_0000_0000` and every geometry are 2 MiB aligned, so alignment
in the dynamic index and in the guest-physical address are identical. The 2 MiB
count must equal the existing cached `fullyOwnedDynamicExtents`.

The counts are an **upper bound**. They are not reclaimable RAM, not retired
objects and not RSS. Metadata pins are not filtered, residency is not read, and
`physicalReleasedBytes` stays null.

## Where and when it is taken

`ClassicBalloonDevice.setTarget` is the single path for an explicit rescue/drain
request, lease expiry, quarantine, a refusal and an unsolicited deflate. Its order:

1. The target is stored, pending recycling is cancelled, the existing generation
   advances and the config-change interrupt bit is set, exactly as before.
2. Only if the previous target was positive and the new target is zero, the ledger
   is scanned once and one reading is appended to a journal of at most 16.

Consequences:

- A zero request with no positive target (an idle rescue) records nothing.
- Nothing is sampled per packet, per tick or in the 2 ms sample publisher. There is
  no new switch, timer, background task or cross-thread read; the ledger, the scan
  and the final evidence read all run on the coordinator thread that owns them.
- The ledger changes only when the coordinator processes a queue notification, so
  the reading precedes any later deflate packet. It is **not the pulse peak**.
  A guest that deflated earlier (OOM, migration) lowers it; the existing
  `balloonPeakFullyOwnedDynamicExtents` remains the only 2 MiB peak.
- When a packet itself caused the transition (inflate beyond the target, a mixed
  or unsolicited deflate), whatever the ledger had already applied from it is
  included.
- The scan runs after the in-memory publication but before the caller asserts the
  interrupt line, so it can delay that assertion by at most one scan. The scan
  duration is recorded as `samplingNanoseconds`; the journal append is excluded.
- An explicit zero request is applied inside the existing admission lock
  (`applyBalloonRequest`), so the scan also runs under that lock. It is bounded CPU
  work over the bitmap with no I/O or waiting, like the other ledger work done
  there, and `samplingNanoseconds` records how long it held.

## Isolation from the rescue

`recordZeroTransition` is non-throwing. It receives the ledger as a read-only
value, so it cannot change ownership, renew or clear a deadline, alter a counter
or request a target. The only possible failure is the history counter overflowing;
it is counted in `recordFailures` and otherwise ignored. No diagnostic result can
prevent a zero target, delay cancellation of recycling or cause a reinflate.

## Algorithm and cost

The ledger bitmap has one bit per 4 KiB PFN, so a word is 64 PFNs (256 KiB) and
eight words are one 2 MiB object. The scan walks the dynamic words once:

- Zero words are skipped.
- Progressive AND-shifts (`w & w>>1`, `&= >>2`, `>>4`, `>>8`, `>>16`) leave the
  lowest bit of each aligned 4/16/32-page group set only if every page is owned.
  A fixed mask plus `nonzeroBitCount` counts the 16 KiB, 64 KiB and 128 KiB units.
- Fully owned words are recorded in a byte per object: two adjacent aligned words
  are 512 KiB and all eight are 2 MiB.

Cost is linear in the word count: 10,240 words (80 KiB) at 2560 MiB and 12,288
words (96 KiB) at 3 GiB, with constant extra memory and no per-PFN `Set`,
dictionary or unsafe pointer. A nonzero word costs about 20 integer operations and
three population counts. No timing has been measured; the first real figures are the
recorded `samplingNanoseconds` values from a release build.

## Bounds and assumptions

- The ledger geometry is already validated: boot and dynamic sizes are 2 MiB
  multiples, each at most 3 GiB, so the dynamic words start on an eight-word
  boundary and counters (at most 196,608) fit in `UInt32`.
- The journal reserves 16 fixed-size readings (about 1 KiB) when the device is
  created. The scan itself allocates nothing; this is unprofiled.
- Dictionaries exist only while rendering the final evidence.

## Saved evidence

`NativeVirtualMachine` adds one key, `balloonOwnershipCoverage`, to its existing
saved evidence. Existing keys are unchanged, so clients that ignore unknown
fields are unaffected. It is `{}` when classic ballooning is disabled.

| Field | Meaning |
|---|---|
| `scope` | Human-readable statement of the limits below |
| `samples` | At most 16 readings, oldest first |
| `samplesTotal`, `samplesDropped` | Completed transitions recorded, and how many fell out |
| `recordFailures` | Journal appends that failed, apart from every device error |
| `pulseActiveAtEvidence` | A positive target was still active at the end, so that pulse has no reading |
| `metadataPinsFiltered`, `residencyFiltered` | Always `false` |
| `physicalReleasedBytes` | Always null |

Each sample has `epoch`, `previousTargetPFNs`, `ownedPFNs` (boot and dynamic),
`ownedDynamicPFNs`, `fullyOwned16KiBUnits`, `fullyOwned64KiBUnits`,
`fullyOwned128KiBUnits`, `fullyOwned512KiBUnits`, `fullyOwned2MiBUnits` and
`samplingNanoseconds`.

## Missing samples

A reading exists only for a completed positive-to-zero transition.

- If the process is killed or crashes, the saved evidence is not written at all;
  there is no incremental journal, by design.
- If the VM stops on a fatal error during a pulse, the evidence is still written
  but that pulse has no reading and `pulseActiveAtEvidence` is `true`.
- No end-of-run scan is substituted: after deflate or reset it would be a zero that
  looks like success. An empty `samples` list with `samplesTotal` 0 means nothing
  was recorded, never zero coverage.

## Pending verification (not run)

Source tests, for the parent's build (`swift test -c release -j 1 -Xswiftc
-warnings-as-errors`, as in the README). New in `BalloonCoverageTests.swift`:

- `emptyAndFullLedgersCountNoUnitsOrEveryAlignedUnit`
- `oneMissingPFNRemovesExactlyOneUnitAtEveryGranule` (11 positions)
- `unalignedRunsCountOnlyTheUnitsEntirelyInsideThem` (11 hand-counted runs)
- `scatteredPatternsMatchTheReferenceAcrossInflateAndDeflateChurn` (3 seeds)
- `bootOwnershipNeverCountsAsDynamicCoverage`
- `deflateAndResetShrinkCoverageToTheCurrentLedgerOnly`
- `measuringCoverageNeverMutatesOwnershipOrQueuedRecycling`
- `maximumGeometryCountsFullOwnershipAndTheFinalPFNExactly`
- `scatteredPagesAtBothEndsOfMaximumGeometryMatchTheReference`
- `journalRecordsOnlyAPositiveToZeroTransitionAndLeavesTheLedgerUntouched`
- `journalKeepsTheNewestSixteenSamplesAndCountsWhatItDropped`
- `evidenceIsValidJSONAndNeverClaimsPhysicalReleaseOrFiltering`
- `samplingDurationRendersAsSaturatingNanoseconds`

New in `ClassicBalloonTests.swift`:
`zeroPathsWithoutAPositiveTargetRecordNothingAndKeepTheRescueUnchanged`. Existing
balloon, lease, recycling and publication tests are unchanged and must still pass.
Ledger tests use the real 256-PFN `transfer`, `releaseOwned` and `reset` paths; the
`Set` oracle and closed-form counts exist only in tests. The oracle's validity
depends on the hand-counted runs, not on the implementation.

A positive target needs plugged Hypervisor backing, so unit tests cannot reach the
device's own transition. That call site needs signed hardware:

1. The existing `--balloon-device-check` and `--balloon-device-check-cold` owner
   checks must still print `MEMORY_DEVICE_CHECK_PASS`. They exercise explicit
   zero, an expired lease, unsolicited-deflate rescue and quarantine. Their own
   result file does not carry the new field.
2. A real classic-balloon Native VM run, whose `native.json` should show one
   reading per explicit zero, lease expiry and quarantine, with
   `fullyOwned2MiBUnits` at most `balloonPeakFullyOwnedDynamicExtents`, unchanged
   accepted/refused packet and lease counters, and `samplingNanoseconds` from a
   release build at the 2560 MiB and 3 GiB geometries.
3. A run that ends fatally mid-pulse, to confirm `pulseActiveAtEvidence` is `true`
   with no fabricated reading.

No timing test was added: Swift Testing has no benchmark facility, and an absolute
time gate is brittle on a shared host. Release timings come from item 2.
