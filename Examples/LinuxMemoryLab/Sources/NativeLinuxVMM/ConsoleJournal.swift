import Foundation

/// Keeps UART framing bounded even when a VM outlives its retained diagnostic history.
struct ConsoleJournal {
  private let policy: NativeExecutionPolicy
  private var history = Data()
  private var line = Data()
  private var fileBytes = 0
  private var failed = false

  var retained: Data {
    guard policy == .sustained else { return history }
    var snapshot = history
    snapshot.append(line)
    return snapshot.suffix(64 << 10)
  }

  init(policy: NativeExecutionPolicy) { self.policy = policy }

  mutating func append(_ byte: UInt8, sink: FileHandle?) throws -> String? {
    guard !failed else { throw Failure.boundary }
    do {
      guard line.count < 8192 else { throw Failure.boundary }
      if policy == .qualification {
        guard history.count < 2 << 20 else { throw Failure.boundary }
        history.append(byte)
      }
      line.append(byte)
      guard byte == 10 else { return nil }
      if policy == .sustained {
        if fileBytes + line.count > 1 << 20 {
          try sink?.truncate(atOffset: 0)
          try sink?.seek(toOffset: 0)
          fileBytes = 0
        }
      }
      try sink?.write(contentsOf: line)
      if policy == .sustained {
        history.removeFirst(max(0, history.count + line.count - (64 << 10)))
        history.append(line)
      }
      fileBytes += line.count
      let completed = String(decoding: line, as: UTF8.self)
      line.removeAll(keepingCapacity: true)
      return completed
    } catch {
      // A failed sink has an unknown file offset; the VM owner must stop instead of retrying.
      failed = true
      throw error
    }
  }
}
