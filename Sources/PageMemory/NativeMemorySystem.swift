// These native ABI accesses also work when Embedded's importer rejects the C macros.
#if os(Linux) && hasFeature(Embedded)
  import NativePOSIX
#elseif canImport(Darwin)
  import Darwin
#elseif os(Linux) && canImport(Glibc)
  import Glibc
#elseif os(Linux) && canImport(Musl)
  import Musl
#elseif os(Windows)
  import WinSDK
#endif
enum NativeMemorySystem {
  static var errorCode: Int32 {
    #if canImport(Darwin)
      return unsafe __error().pointee
    #elseif os(Linux)
      return unsafe __errno_location().pointee
    #elseif os(Windows)
      return Int32(bitPattern: GetLastError())
    #else
      #error("NativeMemorySystem requires Darwin, Linux or Windows.")
    #endif
  }

  static func mappingFailed(_ address: UnsafeMutableRawPointer?) -> Bool {
    #if os(Windows)
      unsafe address == nil
    #else
      unsafe address == UnsafeMutableRawPointer(bitPattern: -1)
    #endif
  }
}
