# Stable mapping and isolated device experiment report

Swift6.4.1,2026-10-14. Experimental research only; production Macray adoption remains separate.

## Implemented and checked

- Internal byte-free PageMapping is the single backing owner. MappedValue exposes
  stable typed slots, scoped Span borrowing, typed mapping/factory errors and separate
  value/backing retirement. Null mapping rejection retains fallback cleanup ownership.
- Nonblocking mapping/release admission refuses before syscalls/destruction. Per-region
  budgets include actual page rounding and required alignment padding; exact page-sized
  values no longer unnecessarily reserve an extra alignment page.
- Existing ScratchArena/FrameLedger are composed with actual page backing without
  duplicating the allocator. Native Atomic/Mutex consumers work in owned storage.
  A fixed1024-word Atomic InlineArray uses8192 bytes before rounding:8192 onLinux,
  16384 onMac. This is mapping geometry, not an RSS saving estimate.
- In a64MiB single-CPU networkless/diskless QEMU guest, real timer IRQ, entropy DMA
  and four-page traditional virtio-balloon inflate/deflate execute as Swift driver code.
  ELF/SIL, strict alignment, no-FP/import/stack-guard checks and11 positive/negative
  guest executions pass. Privileged ISA/register-preservation assembly remains optional
  firmware glue; it is not linked into package products.

## Verification

| Gate | Observed result |
|---|---|
| macOS27 / Swift6.4.1 Release |36 tests passed|
| Debug / AddressSanitizer |36 tests passed|
| SIL ownership/compiler consumers |36 checks: positive controls and exact negative diagnostics|
| iOS18 deployment / iOS27 SDK |PageMemory module compiled; no device claim|
| StaticLinux / musl / x86_64 |Both native probes built and ran on authorized standby VPS|
| Resource-bounded VPS execution |CPU10%, RAM32MiB,8 tasks,15s maximum; no swap|
| Native syscall failure fixture |map refusal, null-result cleanup, factory unwind, unmap refusal/retry; one destruction|
| Production observation |active home route, service PIDs/restart counters and Xray config digest unchanged across test sets|

The final Linux contract probe observed1024 compact slots in8192 mapped bytes,
512 resident pages after touching its2MiB payload and0 after discard. Its final
self RSS was4100096 bytes (3.91MiB), CPU5253670ns (5.25ms), wall58976933ns (58.98ms).
Wall time includes cgroup throttling; unit/sandbox startup is separately outside these
process-local timestamps. Earlier final-core replicates used5.54–6.35ms CPU and
59.69–79.73ms wall. These are finite whole-probe measurements, not per-request tails
or a fair unthrottled Mac/Rust performance comparison. The actual standby host has
about3.72GiB RAM and two virtual CPUs; the probe's32MiB/10% cgroup models a small budget.

The initial macOS CI caught a framework-boundary link failure for internal PageMapping
metadata used by a specialized generic owner. Marking that internal storage type
`@usableFromInline` fixes ABI visibility without adding public API. The separate-package
default-build-system consumer is a CI regression gate. Its macOS framework-loaded RSS
is higher than the static native consumer's RSS; build/link layout matters to this metric.

No working service was stopped or restarted, no routes/PF/Xray configuration/public
client links were changed, and no loadable kernel code or physical host device was
used. Checks do not prove every real client experienced zero jitter during observation.

## Review and limitations

Actual Sonnet5.5 design/guest reviews and Opus5.5 source review returned with tools0
and max effort requested; provider-effective effort was not reported. The first
Opus request fell back to4.8 for its final public text and is explicitly qualified.
Reviews cover their supplied snapshots. Native tests verify subsequent repairs;
we do not claim independent model signoff on an unchanged final whole repository.

The Mac QEMU balloon warns about backing pages above4KiB. Five affected executions
retain that exact diagnostic and are explicitly qualified. Protocol acknowledgements,
PFN consumption and guest reuse are verified; physical host RAM reclamation is not.
The guest is firmware, not Linux; Kbuild/CFI/per-CPU guard ABI and real IOMMU/DMA
registration are not supplied. There is no adaptive host balloon target controller
or Apple container integration yet. Arbitrary self-referential pin initialization
and a safe reusable DMA/balloon typestate API also remain open.

PageMapping destruction makes one best-effort unmap attempt and cannot report
permanent failure; explicit release reports it and retains retryable ownership.
Mapping/reading/destruction can block or fault; the context tag is not Linux GFP.
The owner pins its virtual slot after placement, not physical pages or every value
from construction. Preserve dynamic exclusivity checks and compiler/lifetime gates.

See [the contract and primary references](StableMappingAndGuestDevices.md).
