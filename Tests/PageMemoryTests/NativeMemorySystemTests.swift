import Testing

@testable import PageMemory

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif os(Windows)
  import WinSDK
#else
  import Musl
#endif
@Test func nativeMacroEquivalentsPreserveMappingFailureAndErrno() {
  // A zero-length mapping is refused without creating or modifying any mapping.
  #if os(Windows)
    let address = unsafe VirtualAlloc(
      nil, 0, DWORD(MEM_RESERVE | MEM_COMMIT), DWORD(PAGE_READWRITE))
    let errorCode = NativeMemorySystem.errorCode
    let nativeError = GetLastError()
    #expect(unsafe address == nil)
    #expect(unsafe NativeMemorySystem.mappingFailed(address))
    #expect(errorCode == Int32(bitPattern: nativeError) && nativeError != 0)
  #else
    let address = unsafe mmap(nil, 0, PROT_READ, MAP_PRIVATE | MAP_ANONYMOUS, -1, 0)
    let errorCode = NativeMemorySystem.errorCode
    let macroError = errno
    let failed = unsafe NativeMemorySystem.mappingFailed(address)
    let macroFailed = unsafe address == MAP_FAILED
    #expect(failed && macroFailed)
    #expect(errorCode == macroError && errorCode == EINVAL)
  #endif
}
