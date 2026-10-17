#if os(Linux)
  import NativeGuestMemory
  #if canImport(Musl)
    import Musl
  #else
    import Glibc
  #endif

  @main private struct Monitor {
    static func main() {
      do {
        try GuestMemoryService.validate()
        try GuestMemoryMonitor.run()
      } catch {
        // Stdout is the protocol wire; the exit status is the failure signal and stderr is
        // best-effort context only.
        var message = "container-memory-monitor: \(error)\n"
        message.withUTF8 { bytes in _ = write(2, bytes.baseAddress, bytes.count) }
        exit(1)
      }
    }
  }
#else
  import Darwin

  @main private struct Monitor {
    static func main() {
      print("Memory monitoring requires Linux.")
      exit(EXIT_FAILURE)
    }
  }
#endif
