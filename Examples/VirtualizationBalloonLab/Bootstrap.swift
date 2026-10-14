import NativeInit

// Embedded Swift has no hosted runtime constructors; mount proc before execing hosted Swift PID1.
@main private struct Bootstrap {
  static func main() {
    guard getpid() == 1,
      mountFS("proc", "/proc", flags: UInt(MS_NOSUID | MS_NODEV)) == 0,
      mountFS("sysfs", "/sys", flags: UInt(MS_NOSUID | MS_NODEV)) == 0,
      mountFS("devtmpfs", "/dev", flags: UInt(MS_NOSUID)) == 0
    else { fail() }
    let path: StaticString = "/probe"
    path.withUTF8Buffer { bytes in
      bytes.baseAddress!.withMemoryRebound(to: CChar.self, capacity: bytes.count + 1) { path in
        withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<CChar>?.self, capacity: 2) { args in
          args[0] = UnsafeMutablePointer(mutating: path)
          args[1] = nil
          withUnsafeTemporaryAllocation(of: UnsafeMutablePointer<CChar>?.self, capacity: 1) { env in
            env[0] = nil
            _ = execve(path, args.baseAddress!, env.baseAddress!)
          }
        }
      }
    }
    fail()
  }

  private static func mountFS(_ type: StaticString, _ path: StaticString, flags: UInt) -> Int32 {
    type.utf8Start.withMemoryRebound(to: CChar.self, capacity: type.utf8CodeUnitCount + 1) { type in
      path.utf8Start.withMemoryRebound(to: CChar.self, capacity: path.utf8CodeUnitCount + 1) {
        path in
        mount(type, path, type, flags, nil)
      }
    }
  }

  private static func fail() -> Never {
    let text: StaticString = "BOOTSTRAP_FAIL\n"
    text.withUTF8Buffer { _ = write(2, $0.baseAddress, $0.count) }
    while true { _ = pause() }
  }
}
