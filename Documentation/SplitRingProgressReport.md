# Split-ring progress validation — 2026-10-14

This isolated research slice extends experimental7. Production Macray, original task0106,
existing VM/container workloads and public client links were not changed. Public main
remains separate. Core APIs are Swift; the optional guest keeps the existing tiny ARM64
privileged instruction/boot boundary. A freestanding ELF is not a Linux kernel module.

The native M2Max layout probe measures a 16-byte sequence value (stride 16, alignment 8).
It owns no heap storage or ARC references; the actual guest profile compiles it with
Embedded -no-allocations. This is not a whole-process RSS or runtime replacement claim.

## Accepted local evidence

| Gate | Actual result |
|---|---|
| macOS 27.0.1/M2Max, Swift 6.4.1 release tests |40 passed |
| AddressSanitizer release tests |40 passed |
| Compiler/lifetime consumers |36 passed |
| Default-framework MemoryContracts consumer |Build and native execution passed |
| iOS18 deployment target using SDK27 |BoundedMemory compiled; no device claim |
| Static Linux musl consumer |Built and ran in the strict native VPS sandbox |
| Embedded allocation-free whole ARM64/x86 profiles |Passed |
| Actual audited ARM64 guest |21 cases passed after Opus and injection precondition corrections |
| Actual host/QMP control |Four cases passed using independently accepted host controller |
| Pre-fix classification guard mutation |Refused1 with wrong DMA_TIMEOUT attribution |
| Corrected unpublished-index case |Passed0 with exact VIRTIO_USED_INDEX_FAIL |

The positive guest starts a real virtio-rng queue at zero and validates 65,540 device-written
used-ring completions, crossing the65,536 wire wrap and continuing to index4. It retains
its frame ticket until native reset and bounds checking. Four wrap negatives require an
exact count 65,536 injection marker and distinct ID/length/index/stale refusal. A fifth
unpublished-index control verifies that an unexpected completion index cannot masquerade
as an expected timeout. The final control withholds publication at count65536 and must produce a timeout
without an injection marker: synthetic corruption cannot mask absent actual completion.
Existing no-publication/missing-device/timeout/IRQ/balloon/guard/
trap/memory cases remain enforced. No fresh-payload-on-every-request claim is made.

The regression-before artifact is an isolated source copy restoring exactly the old index
classification guard, with the same new fault input. It is not an unchanged historical
release. Its real ELF emitted IRQ_PASS, DMA_UNPUBLISHED_INDEX_INJECT, DMA_TIMEOUT and was
refused by the strict runner. The corrected real ELF emitted the required index refusal.

Initial SwiftTesting macro mutation syntax failed compilation; corrected explicit mutation
bindings passed. An initial compiler-check command pointed at the native product rather
than its Modules subdirectory and was refused before positive consumer acceptance. Both
original failures are retained. Axbuild event-stream mapping is partial on the selected
toolchain; actual native exit status and complete saved SwiftTesting logs are primary.

## Capped Linux evidence

The inventory-selected home standby still serves real clients. Only two short final source
native probes ran there, with 32 MiB RAM, zero swap,10%CPU,8tasks,15-second runtime, Nice19,
network namespace isolation, read-only filesystem/home and W^X restrictions. No QEMU,
package installation, kernel/module or persistent service change was made there.

| Counter | Final probe1 | Final probe2 |
|---|---:|---:|
| Native process CPU |7.207ms |7.297ms |
| Native process wall |79.539ms |79.637ms |
| Final approximate RSS |5705728B |5701632B |
| Touched/discarded2MiB pages |512 ->0 |512 ->0 |
| Sequence steps/checksum |131080 /4294901788 |131080 /4294901788 |

These process timings include the existing ownership/frame/mapping checks and the new
sequence loop. They exclude SSH/systemd orchestration. Linux statm RSS is approximate,
not a language runtime constant. Two samples do not prove all-client latency isolation
or Swift/Rust performance parity. Home selection, Xray/agent PIDs/restarts and config
hashes matched the before/after samples; only the exact uploaded probe/empty private
folder was removed. Initial pre-attribute-correction probe artifacts remain distinct.

On Darwin, the same 2 MiB owned-region discard keeps 128 pages resident under lazy advice.
Residency, footprint accounting and physical release remain separate. Balloon physical
host RAM release stays unverified on the16KiB backing host.

## Independent opinions and limits

Actual firstParty Sonnet5.5 completed in160.395s and Opus5.5 in580.428s, both end_turn,
exit0, tools disabled, max requested,3600-second timeout. Provider-effective effort was
not reported. Only public answers were inspected; private thinking was not read. They
reviewed supplied snapshots, not final-source execution.

Sonnet found no must-fix arithmetic error. Its optional ignored-overflow warning was
adopted by removing @discardableResult. Opus identified incorrect index-failure
classification and negative-control attribution; both were fixed and natively verified.
The maximum written extent was already corrected before its answer. Fresh RNG payload
claims were narrowed, and first-use used-entry sentinels plus explicit avail.idx zeroing
were added. Final corrections were reviewed by the root against actual native evidence.

Graphify AST navigation is refreshed; Swift parser gaps and document semantic gaps remain
qualified. Generated graph/build/log artifacts are excluded from Git. Physical VM reclaim,
Virtualization.framework acknowledgement/guest integration, cached multicore DMA, live
driver recovery, general Pin and LinuxKbuild/CFI/ORC remain open. No production adoption
permission transfers from this research release. See [contracts](SplitRingProgress.md).
