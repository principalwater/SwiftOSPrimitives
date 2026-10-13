# Embedded PageMemory consumer

This standalone consumer uses the same PageMemory sources as the normal library.
It builds with Swift 6.4.1 Embedded mode, whole-module optimization, strict memory
safety, and warnings as errors. It does not add an Embedded setting to consumers
of the main package.

```text
swift Tools/CheckLowLevel.swift /path/to/swiftc /path/to/SwiftOSPrimitives /path/to/owned-scratch
```

On macOS, set SDKROOT to the installed macOS SDK. The helper creates a unique
scratch subdirectory, retains compiler logs, images, LLVM IR and assembly, and
runs finite consumers. The host's compiler must include the Embedded modules
for both freestanding targets. No compiler, OS or signing checks are disabled.

The consumer verifies 1000 reset/reuse cycles in a single 64 KiB mapping, an
independent checksum, bad allocation bounds, retired access, payload-error
propagation, independent noncopyable callback results, explicit/idempotent
release, and native self-memory observation. It uses native libc/libSystem APIs
and no Foundation. It is a user-space executable, not a Linux kernel module.

Both examples linked only libSystem on the tested macOS 27 / ARM64 host; the
Linux build/execution is separately gated by CI. Link results for a consumer
do not certify every specialization of a public generic API.

The full PageMemory sources do not pass `-no-allocations`: string-backed errors
and some standard-library paths still require allocation support. The register
leaf passes that mode separately. No infallible allocation or validation is
removed to make the full library pass. Reclamation is process-local; this is
not guest VM ballooning or a replacement for a kernel allocator.

For native Linux/glibc, the helper locates the compiler-provided SwiftGlibc
declaration map. The optional self-observer uses fopen/fileno/fclose in Embedded
mode because the overlay supplies the normal variadic open wrapper. The FILE
object may allocate in libc and is closed before capture returns. The normal
library retains open/O_CLOEXEC. No custom C implementation or ABI redeclaration
is introduced.
