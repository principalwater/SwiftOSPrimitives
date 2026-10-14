# Native Mach failure fixture

This macOS-only standalone executable aliases four imports at link time and forwards
successful operations to the real libSystem symbols through RTLD_NEXT. Fault state is
serialized and private to the executable. No wrapper, alias or fault flag enters a
package product; never link this example into an application or load it into another
process. Build/run with the macOS recipe in .github/workflows/validate.yml.

It exercises refused allocation/nonblocking admission, actual purge/reset retirement,
partial erasure failure, full mapped extent including rounded padding, failed explicit
unmap with ownership/retry and idempotent success. A real mlock/EMPTY/munlock/EMPTY cycle
proves a successful purge can leave resident wired pages and must be retryable. Native
memory management, full logical reinitialization and entire-region deallocation remain
real OS operations. All behavior is Swift; Darwin headers supply only native ABI.
