import Testing

@testable import PageMemory

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#else
  import Musl
#endif

@Test func nativeMacroEquivalentsPreserveMappingFailureAndErrno() {
  // A zero-length mapping is refused without creating or modifying any mapping.
  let address = unsafe mmap(nil, 0, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0)
  let errorCode = NativeMemorySystem.errorCode
  let macroError = errno
  let failed = unsafe NativeMemorySystem.mappingFailed(address)
  let macroFailed = unsafe address == MAP_FAILED
  #expect(failed && macroFailed)
  #expect(errorCode == macroError && errorCode == EINVAL)
}
