#if os(Linux)
  #if canImport(Musl)
    import Musl
  #else
    import Glibc
  #endif

  /// Line framing on the guest's stdin and stdout.
  public enum GuestWire {
    /// Longest accepted request line including its newline.
    static let requestLimit = 64

    /// Writes all of `text` to stdout, retrying `EINTR`; a zero-byte write is an error.
    public static func emit(_ text: String) throws {
      var text = text
      try text.withUTF8 { bytes in
        var done = 0
        while done < bytes.count {
          // The loop condition proves the buffer is non-empty, so the base address exists.
          let count = write(1, bytes.baseAddress! + done, bytes.count - done)
          if count < 0, errno == EINTR { continue }
          guard count > 0 else { throw GuestMemoryFailure.system(count < 0 ? errno : EIO) }
          done += count
        }
      }
    }

    /// Reads one newline-terminated line of printable ASCII from stdin, one byte at a time so
    /// no later request is consumed. Returns nil on EOF before any byte; EOF inside a line, a
    /// control or non-ASCII byte, or a line over the limit is `framing`.
    public static func nextCommand() throws -> String? {
      var bytes: [UInt8] = []
      bytes.reserveCapacity(requestLimit)
      while true {
        var byte: UInt8 = 0
        let count = read(0, &byte, 1)
        if count < 0, errno == EINTR { continue }
        guard count >= 0 else { throw GuestMemoryFailure.system(errno) }
        if count == 0 {
          if bytes.isEmpty { return nil }
          throw GuestMemoryFailure.framing
        }
        if byte == 10 { return String(decoding: bytes, as: UTF8.self) }
        guard byte >= 32, byte <= 126, bytes.count < requestLimit - 1 else {
          throw GuestMemoryFailure.framing
        }
        bytes.append(byte)
      }
    }
  }

  /// The guest side of `NativeMemorySession`: it blocks on stdin, never polls, and answers each
  /// request with one flushed `write` of a bounded frame.
  public enum GuestMemoryMonitor {
    /// Emits `MEMORY_READY <total> <available>`, then answers `OBS n`, `OBS_REFRESH n` and
    /// `QUIT n` with `MEMORY_OK n <total> <available>`. `OBS_REFRESH` refreshes VM statistics
    /// before sampling. Returns after a valid `QUIT` (answered) or EOF between requests; a
    /// wrong sequence, unknown command or malformed line throws. READY is withheld until the
    /// initial statistics refresh succeeds, so it also proves permission to refresh later.
    public static func run() throws {
      try GuestMemory.refreshStatistics()
      let ready = try GuestMemory.snapshot()
      try GuestWire.emit("MEMORY_READY \(ready.wireFields)\n")
      var sequence: UInt64 = 0
      while sequence < UInt64.max {
        sequence += 1
        guard let line = try GuestWire.nextCommand() else { return }
        guard let command = MemoryMonitorCommand(line: line, sequence: sequence) else {
          throw GuestMemoryFailure.framing
        }
        if command == .observeRefreshing { try GuestMemory.refreshStatistics() }
        let reading = try GuestMemory.snapshot()
        try GuestWire.emit("MEMORY_OK \(sequence) \(reading.wireFields)\n")
        if command == .quit { return }
      }
      throw GuestMemoryFailure.framing
    }
  }
#endif
