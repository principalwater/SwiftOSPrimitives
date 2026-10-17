# Exact tested Mach backing controls

These independent, finite Swift files preserve the exact sources used for the
2026-10-18 memory checkpoint. They are outside package products and are not
linked together: each file is a separate executable with its own main.

Scope: owned synthetic 64 MiB objects on the qualified macOS 27 / SDK 27 /
Swift 6.4.1 Apple Silicon host with 16 KiB pages. No arbitrary pointer, foreign
task, global purge, pressure forcing, production service or installed VM is used.
The wired negative control locks only one owned 16 KiB page. Do not run this as
a privileged or permanent service, or treat it as a product memory governor.

| Source | Fixed profiles | Qualified observation |
|---|---|---|
| MachBackingControlLab.swift | ordinary-reject, shared-held, purgable | Rejected purge preserves ordinary memory; removing VA views can lower RSS without retiring backing; per-entry purge/regrowth |
| MachWiredBackingControlLab.swift | purgable-wired | EMPTY can succeed while one wired page remains resident; successful return is not complete discard proof |
| MachHVFExecutableBackingControlLab.swift | purgable-hvf | Actual guest execution over host NX backing, exact unmap faults, cold discard/remap, guest zero and full regrowth |

Compile exactly one source with the installed Swift 6.4.1 compiler, optimization,
debug symbols, Swift 6 language mode, warnings-as-errors and explicit SDK 27.
Use an explicit output and module-cache directory on an owned external test disk.
For the HVF control link Hypervisor.framework, ad-hoc sign with the existing
LinuxMemoryLab hypervisor entitlement and verify the signature before launch.
The two host-only controls do not require a hypervisor entitlement.

The recorded compiler arguments were: -O -g -parse-as-library -swift-version 6
-warnings-as-errors, plus -framework Hypervisor for the HVF file and explicit
-sdk, source and -o paths. Retain the source/host SHA256 and matching dSYM UUID.

Run each fresh process under a native-process-group watchdog (25 seconds in the
qualified harness), join/reap on success or failure, keep bounded stdout/stderr,
and stop before another VM if native cleanup is uncertain. Admit only under
normal host pressure with conservative RAM/disk headroom; do not force a global
purge or warm guest pages to make a residency gate pass. No compiler, other VM or
resource benchmark ran concurrently with the qualified HVF control.

Output is bounded JSON. Independently check primaryError/cleanupErrors, all native
cleanup and actual process reap. For HVF additionally require 69,633 guest runs,
12,288 exact stage-2 faults, three cycles, host maximum protection RW, stage-2 RWX,
actual guest execution, zero resident/swapped counts before reads and after cold
remap, then guest zero and complete regrowth checks. A timeout is a failure.
Task RSS/footprint remain context; physicalGlobalFreeBytesAttributed stays null.

The tested source SHA256 values and selected independent measurements are in
[checkpoint evidence](../../Documentation/MemoryBallooningCheckpoint-2026-10-18.json).
The full [checkpoint and remaining plan](../../Documentation/MemoryBallooningCheckpoint-2026-10-18.md)
distinguish this synthetic proof from actual Linux/ClickHouse and product gates.
