# Hosted Windows validation

The experimental BoundedMemory branch includes the existing Windows PageMemory
port. Package products remain Swift-only. Native WinSDK supplies allocation,
decommit/recommit, residency, working-set and error-code APIs; no POSIX
compatibility layer, driver, background sampler or freestanding PAL is included.

Windows 10 x64 validation on Swift 6.4.1, 2026-10-14:

- 12 PageMemory and 19 BoundedMemory optimized tests pass with strict memory
  safety and warnings as errors. Discovery is checked independently so an empty
  SwiftBuild test anchor cannot count as success.
- Three valid ownership consumers compile; 25 invalid consumers are rejected with
  their expected diagnostics. These cover page, byte, typed and frame loans.
- A 1,027-page fixture crosses the bounded residency-query batch boundary and
  observes zero resident pages after decommit, then verifies reset and release.
- The native probe passes 300 mapping cycles and 1,000 reuse cycles of 64 KiB.
  One reuse observation recorded a 27.4 us median cycle; it is not an A/B speedup.
- In one isolated 16 MiB touch/discard observation, process working set rose from
  7,671,808 to 24,453,120 bytes, then fell to 7,680,000 after decommit. Working set
  is an observation; Windows physical footprint remains unknown.

Windows residency uses at most 1,024 native entries in scoped temporary storage,
without an Array/ARC owner. Placement is a standard-library decision; this does
not prove that all runtime work avoids heap allocation. Advice, allocation and
release failure injection is not covered.

## Frame comparison

The existing checked harness now uses QueryPerformanceCounter/Frequency on
Windows. The inspector accepts LF and CRLF and verifies raw ticks, timebase,
digests and generations. Both variants use the same hosted Swift flags and
identical workload: the scanning ledger from `9cb8cf2` and the cached ledger from
`c4214b2`. Three runs of each were interleaved, using below-normal process priority.

At 65,536 slots, the ranges of p50 batch means were:

| Workload | Scanning | Cached |
| --- | ---: | ---: |
| Three reservations and three releases | 124,013–125,721 ns | 91–100 ns |
| Fully occupied refusal | 286,475–290,596 ns | 9 ns, near clock floor |
| Fragmented refusal | 161,612–169,143 ns | 114,018–117,118 ns |

These are synthetic batch means, not individual tail latency. The improvement
comes primarily from exact O(1) availability accounting and early refusal;
fragmented searches remain O(capacity). The harness manages integer frame IDs,
not physical RAM or application scheduling. Peak working-set observations were
unavailable after process exit; no memory comparison is claimed. Windows Embedded
and Windows Rust references are not validated.

## Consumer choice

SwiftyToys currently uses stable PageMemory for a scoped 64 KiB SHA-256 buffer.
Its CNG/signature checks and mapped tokenizer remain separate. There is no frame
allocator in its UI/search path, so the frame comparison does not justify adding
FrameLedger there. Typed scratch reservations may help a demonstrated repeated
buffer workload, but require consumer lifetime, capacity and performance checks.
Neither a package upgrade nor a smaller benchmark replaces that evidence.
