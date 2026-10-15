# Native memory control with a real ClickHouse workload

This is an isolated research qualification, not a production sizing recommendation.
The owner and resource/control code are Swift6.4.1 on macOS/SDK27, using the real
Apple Container1.5.0 release's Containerization0.47.0 LinuxContainer/vminitd/OCI
runtime. The workload is the official ClickHouse ARM64 server26.9.19.9.

## Reproducible scope

The image is pinned by immutable multi-platform index
`sha256:bdb5c911a23d92fd364e246ab20b5a0a485f00112f3663fa626b083fb46c146b`;
its ARM64 manifest is
`sha256:a1cbb0635ba000b415454b9e46e2c8694e0a2ee49e506e2e5a4b7b47c1a6e0c5`.
A mutable tag is never resolved during a run. The native preparer unpacks an8GiB
sparse ext4 template and records its SHA256. The owner hashes the actual private
copy before boot, measures the initfs/probe inputs, and verifies their unchanged
hashes on exit. These are local reproducibility checks, not upstream filesystem
attestation. The original OCI bytes/digests and raw native outcomes are retained.

All OCI/image/rootfs/database/log/temp/build paths in the observed runs live on
one exclusively owned T7 workspace. No existing database or global container
service is used. One VM at a time:1CPU/2GiB/noNIC,1.5GiB workload cgroup, ordinary
capabilities/no_new_privs; only the trusted telemetry exec gets RAWIO/ADMIN to
read balloon PCI configuration. Config/probe shares are read-only, database data
is a separate writable owned share. SQL connects only to guest127.0.0.1.

Held control keeps2GiB. Adaptive control uses floor1GiB, step128MiB, reserve512MiB,
hysteresis64MiB,200ms cooldown and sticky10s request completion timeout. Full host
grant remains reserved until VM stop; no host-pressure/lending experiment runs.
Application query memory is capped at512MiB, server tracking at1GiB, with explicit
query/scan/output/time bounds. Fixed background pools are coordinated below the
64-thread global cap so a small VM can actually start its foreground loader.

## Workload and observations

The finite scenario includes idle, eight100k-row batches into a typed MergeTree,
800k-row exact hash aggregation and array sorting, idle, explicit
`SYSTEM JEMALLOC PURGE`, idle and deterministic data verification. Payloads are
fixed128-byte strings derived from each id. Validation recomputes content and
checks row count, sum, uniqueness and endpoint ids; it does not accept a plausible
RSS graph in place of correct data. No OPTIMIZE FINAL, production data or deliberate
host/global memory pressure is involved.

Each sample records guest MemTotal/MemAvailable, native guest requested/actual
balloon PFNs, cgroup usage/anon/cache and CPU time, and OOM counters. The serial
controller handles its sample before optional extra statistics. Request completion
requires a later sequence captured after real setter delivery with both driver
counts equal to that target. Idle sampling windows may carry a pending request;
they do not replace the request's sticky completion deadline. Final completion is
still required, and adaptive PASS requires observed non-zero balloon activity.

Per-phase ClickHouse asynchronous metrics distinguish RSS from allocator resident
and allocated bytes. Native Mach TASK_VM_INFO and process CPU clock samples refer
only to the Swift controller, explicitly excluding unknown VZ helper backing.
Large input hashes use64KiB streaming reads, bounded autorelease scopes and
per-descriptor F_NOCACHE, avoiding an8GiB allocation or host-wide cache purge.

## Qualification boundary

Both final native runs passed with fresh images/data, real stopped VM state,
empty primary/cleanup errors, zero OOM counters and unchanged passive host-service/
interface observations. Every request passed an independent sequence/capture/
delivery/PFN replay. Final source has10passing release API/protocol tests; the EOF
regression first demonstrably failed with deadline instead of disconnected.
Seven real controller cases passed: policy, held, absent, ignored, cancel, paused
and paused+caller-cancel. Successful NIO shutdown is mandatory, even in forced cases.

| Observed metric | Held | Adaptive |
|---|---:|---:|
| Driver-confirmed guest grant, MiB | 2048 | 2048 → 1024 → 1124 → 1024 |
| Native requests (shrink / grow) | 0 | 9 / 1 |
| Observed cgroup maximum, MiB | 1108.1 | 853.0 |
| Final cgroup usage, MiB | 775.7 | 575.4 |
| Final cgroup anonymous memory, MiB | 118.6 | 118.0 |
| Final cgroup file cache, MiB | 649.7 | 449.9 |
| Cgroup CPU in sampled window, seconds | 2.666 | 2.775 |
| Swift controller RSS samples, MiB | 22.1–36.5 | 20.0–34.9 |
| Command wall time including input hashing, seconds | 42.76 | 45.22 |
| Physical host memory released | UNKNOWN | UNKNOWN |

The complete final target trace is2048→1920→1792→1664→1536→1408→1280→1152→1024→
1124→1024MiB. A separate preceding accepted run grew to1141MiB under the same
policy; these are individual observations, not statistical performance claims.
Observed maxima depend on sampling and do not establish allocator peaks. The two
cold sequential runs are no throughput/latency or Rust comparison. Lower guest
cache usage is not physical VZ host release. Explicit allocator purge by itself
did not remove most ClickHouse RSS; allocator, mapped code/cache and balloon
accounting are different scopes.

Integrity result was exactly800000 rows, sum319999600000,800000 matching128-byte
payloads,800000distinct ids, min0/max799999 in both controls. The paused cleanup
phase completed in1.016s (including the deliberate1s grace), versus6.009s before
the EOF-owner repair. Whole native paused command was2.858s. This does not bound a
framework queue wedge or certify upstream internal retainers closed.

Historical startup/integrity failures remain failures, including the incorrect
variable-length hex fixture caught by the independent Sonnet review. Actual
Opus5.5 and Sonnet5.5 max-requested earlier-source/design reviews completed and
were reconciled; neither is a final-binary approval or a replacement for tests.
The collector's Swift6.4.1 Testing event mapping is unsupported; raw native test
logs are retained and collection is explicitly partial.

`physicalReleasedBytes` remains null. Guest allocator release, cgroup reduction,
balloon PFNs and controller footprint are separate observations; none proves
physical VZ host RAM return. Neither a guessed helper PID nor aggregate host free
memory is a release receipt. This experiment does not remove Apple's documented
platform limitation or qualify hostile containers, OOM auto-deflate, all-await
faults or persistent in-process recovery.

A finite native deadline retires admission and can destructively stop the exact
owned VM if graceful shutdown hangs. Caller-owned tasks and NIO shutdown are
joined. Forced epochs are never reused: upstream TimeSyncer teardown after an
out-of-band stop remains inaccessible through the current public API, so process
exit is the final retention boundary. The external180s process watchdog remains
mandatory for a framework/native queue wedge. Its expiry is a failure, not a pass.

## Sources and decision provenance

- Official: [Docker server image](https://github.com/ClickHouse/ClickHouse/blob/master/docker/server/README.md),
  [server settings](https://clickhouse.com/docs/reference/settings/server-settings/settings),
  [query complexity bounds](https://clickhouse.com/docs/operations/settings/query-complexity),
  [SYSTEM statements](https://clickhouse.com/docs/reference/statements/system).
- Derived for this small synthetic VM: coordinated background pools and explicit
  budgets. They follow actual startup evidence, not a universal deployment claim.
- Applied rules: `insert-batch-size`, `schema-pk-plan-before-creation`,
  `schema-types-native-types`, `schema-partition-start-without`, `agent-query-safety`.
  Full scans are intentional bounded stress workloads; no application indexing
  recommendation is inferred from them.
