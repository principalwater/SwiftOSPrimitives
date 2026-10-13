#if os(Linux) && hasFeature(Embedded)
  import NativePOSIX
#elseif canImport(Darwin)
  import Darwin
#elseif os(Linux) && canImport(Glibc)
  import Glibc
#elseif os(Linux) && canImport(Musl)
  import Musl

#endif

// These native ABI accesses also work when Embedded's importer rejects the C macros.
enum NativeMemorySystem {
  static var errorCode: Int32 {
    #if canImport(Darwin)
      return unsafe __error().pointee
    #elseif os(Linux)
      return unsafe __errno_location().pointee
    #else
      #error("NativeMemorySystem requires Darwin, Glibc, or Musl.")
    #endif
  }

  static func mappingFailed(_ address: UnsafeMutableRawPointer?) -> Bool {
    unsafe address == UnsafeMutableRawPointer(bitPattern: -1)
  }
}
