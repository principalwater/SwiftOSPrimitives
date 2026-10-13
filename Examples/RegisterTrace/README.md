# Native volatile code generation

This optional fixture uses the `_Volatile` module shipped with Swift 6.4.1. The
module is underscored: pin and revalidate the compiler before upgrading. There is
no C implementation, dependency on SwiftMMIO, inline assembly, or device access.

`RegisterTrace.swift` performs two UInt32 stores and two UInt32 loads through
`VolatileMappedRegister`. The compiler helper verifies the optimized exported
function contains exactly those four volatile operations and no calls, for
`aarch64-none-none-elf` and `x86_64-unknown-none-elf`. It also compiles with
`-no-allocations` and retains assembly for inspection. The complete compiler
output may still contain unused Embedded support functions; the leaf-function
check is not a whole-object dependency or kernel-hardening certificate.

The executable only tests ordinary owned RAM, including wrapping increment at
UInt32.max. The caller of the exported fixture must supply a live, valid,
naturally aligned address. This is deliberately not a safe public driver API.

Volatile accesses do not supply Linux readl/writel semantics, DMA ordering, IOMMU
mapping, interrupt-context safety, mapping lifetime, or inter-thread synchronization.
Do not use it on arbitrary addresses or device registers without those contracts.
In particular, a CPU atomic fence is not automatically a device/DMA barrier.

Run the combined validation with the compiler helper described in
[EmbeddedPageProbe](../EmbeddedPageProbe/README.md).
