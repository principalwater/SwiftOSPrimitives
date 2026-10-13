#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#elseif canImport(Musl)
  import Musl
#elseif canImport(SwiftGlibc)
  import SwiftGlibc
#elseif canImport(SwiftMusl)
  import SwiftMusl
#else
  #error("A native libc declaration module is required.")
#endif

@main struct RegisterTraceProbe {
  static func main() {
    // Ordinary, exclusively owned RAM only. This never opens a device or maps hardware.
    var storage: UInt32 = 0
    withUnsafeMutablePointer(to: &storage) { address in
      let values: InlineArray<4, UInt32> = [0, 1, 73, UInt32.max]
      for index in 0..<4 {
        let value = values[index]
        guard unsafe registerTrace32(address, value) == (value ^ (value &+ 1)),
          unsafe address.pointee == value &+ 1
        else { exit(3) }
      }
    }
    let message: StaticString = "{\"register_trace32\":\"pass\",\"hardware_access\":false}\n"
    guard unsafe write(1, message.utf8Start, message.utf8CodeUnitCount) == message.utf8CodeUnitCount
    else { exit(5) }
  }
}
