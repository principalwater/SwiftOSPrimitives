# G22 bounded persistent-governance qualification

Qualified on Swift6.4.1/macOS27.0.1/M2Max with Apple container1.5.0,
pinned Containerization0.47.0 and the reviewed API patch, Linux6.18.35.
This is a finite isolated research slice, not unattended product adoption.

## Hardware results

All ten contracts used the same signed v3host/static guest artifact. The expected
BUSY failure retains native exit1. No operation/query/memory/outer watchdog limit
was enlarged. Both private NICs and all vCPUs progressed; all recorded cgroup
OOM/OOM-kill/swap samples are zero and data/integrity checks remain enforced.

| Trial | vCPU | Seconds | Cumulative owned backing retired | Native exit |
| --- | ---: | ---: | ---: | ---: |
| continuous-two-v3 | 2 | 31.518 | 384MiB | 0 |
| continuous-four-v3 | 4 | 30.594 | 384MiB | 0 |
| adaptive-v3 | 2 | 34.556 | 212MiB | 0 |
| manual-v3 | 2 | 27.369 | 256MiB | 0 |
| busy-v3 | 2 | 23.742 | 0MiB | 1 |
| cancel-v3 | 2 | 16.511 | 0MiB | 0 |
| pending-stop-v3 | 2 | 18.403 | 128MiB | 0 |
| history-soak-v3 | 2 | 78.632 | 384MiB | 0 |
| history-churn-v3 | 2 | 56.109 | 2128MiB | 0 |
| lifetime-expire-v3 | 2 | 15.671 | 0MiB | 0 |

The soak recorded524observations while retaining512 (12dropped). Churn performed
two original live-query cycles plus18additional real pressure cycles,41policy
requests with32retained (9dropped), and1064native retirement records with1024
retained. Actual cumulative backing retirement was2128MiB; the same capacity was
regrown/reused. This is not2128MiB simultaneously freed or larger guest capacity.

Every retained retired extent was resident, exclusively owned, fully unmapped
with all vCPUs parked and natively deallocated. Retained task-ledger credit is
reported separately from cumulative retirement because old telemetry was evicted.
Global physical free-list causality remains unknown/physicalReleasedBytes null.
Residency includes host security zeroing. Whole-process peak RSS is not private
physical footprint or Swift-runtime overhead.

The real BUSY alias restored64mappings and freed nothing. Pending graceful stop
released the deliberate alias, drained its one known resize and published coherent
final state. The2s lifetime test admitted zero resize requests, expired as expected
and left the wire usable for integrity/QUIT.

Actual SIGKILL/journal recovery was rerun on the same signed v3host:39.650s, the
killed process/group reaped, fresh replacement,400K-row durable integrity retained.
It does not establish power-loss recovery or live migration.

## Source and review evidence

Root39/native29/product3release test declarations pass (history test has five
capacity cases). Both long-wire tests fail on pre-fix G21 and pass after repair.
Static ARM64 Linux probe is7101400bytes after separate runtime stripping; original
symbols/debug executable are retained. Final187source hashes, signed host/dSYM
and raw outcomes are retained in the private root. The exact v2source snapshot
and rejected disk-basename/freeze trials remain; failed trials were not overwritten.

Focused Opus5.5 max public review returned950.396s under its original1800s budget.
See PERSISTENT-REVIEW.md for checked corrections and limitations.

## Product and remaining boundaries

A separate local ContainerWorkspace repo builds a native SwiftUI/CLI0.0.1 research
inspector using the actual saved results. Folder selection, result display and
refresh were checked through native accessibility/UI; the owned app was closed.
It explicitly does not claim live status or enable container control/migration.

The native VMM still has120s/3million-exit lab guards, a512MiBwrite budget and
console/admission limits. RAM geometry remains1GiBboot+128MiBdynamic; one native
VM per process. Larger geometry, long-duration policy, multi-VM budgets, real
network/shares, production helper ownership, security/fuzz/soak and migration
remain open. No fair OrbStack load comparison was run against production services.

AST maps updated: backend1962nodes/4013edges/139communities with24partial Swift
parses; product70nodes/98edges/8communities. External cross-repo/modulemap and
semantic-document scope remains incomplete. Compiler/runtime evidence is primary.

No main0106/0117, installed container/OrbStack, household network, VPS or protected
data changes. No remote push/release. All builds and test data are on the owned
T7root; an initial attempt was interrupted to relocate shared SwiftPM caching.
