# Mach-O instruction-entry experiment

This optional ARM64/macOS example tests a fixed ADD/RET code pair stored using
Swift section-placement attributes and called with the C ABI. It follows the
mechanism demonstrated by [swift-asm-macro](https://github.com/p-x9/swift-asm-macro),
without installing a macro/assembler dependency. It is not constrained inline
assembly, a JIT, a portable framework API or a privileged-operation test.

Four unsigned edge cases and disassembly are checked. Linux/ELF, x86-64,
arm64e/PAC and App Store validation remain outside this experiment. Ordinary
Swift addition is preferable for arithmetic; this exists to test the mechanism.
