# Native memory alternatives (macOS27)

An opt-in finite native control for purgeable region state, MADV_ZERO and allocator pressure relief.
This executable is not a library product, automatic pressure controller or security
primitive. It requires Swift6.4.1 and macOS27; no other process or VM is controlled.

From the repository root, using an owned output directory:

```text
swiftc -swift-version 6 -O -wmo -parse-as-library \
  -strict-memory-safety -warnings-as-errors Sources/PageMemory/*.swift \
  Examples/NativeMemoryAlternatives/main.swift -o /owned/output/native-alternatives
/owned/output/native-alternatives
```

MADV_ZERO is called only within an owned PageRegion's synchronous unsafe byte
lending callback. Cold residency is checked before reading bytes; warm zero
readback and residency are measured separately. This is not the library's secure
erasure API. That experiment region is explicitly erased/released afterwards.

The malloc experiment targets only a newly created zone, with64 allocations of
64KiB and a bounded4MiB relief goal. All live bytes are checked after relief.
The successful path erases blocks with checked memset_s before freeing them.
Deferred failure cleanup frees outstanding synthetic-data blocks and destroys the
zone; it is not a general secure allocator. The zone is destroyed on every exit. No global/default zone or live Swift object is discarded. A0-byte
relief report is a valid result; it is not silently converted into physical release.

See [NativeHostReclamation](../../Documentation/NativeHostReclamation.md).

The purge control requires the full SDK27 V3 region-info layout and verifies base,
extent, protections and a non-submap region before checking resident/compressed/
wired counters. GET_STATE verifies NONVOLATILE→EMPTY. It does not print the base
address or promote any counter into a global physical-release amount. A shorter
layout is a refusal, not silently interpreted as a newer one.

Run wiring acceptance natively: ASan intercepts mlock/munlock as no-ops and this
control deliberately refuses that false-success condition through V3 kernel
counters. No sanitizer bypass or optional test-only wiring waiver is provided.
