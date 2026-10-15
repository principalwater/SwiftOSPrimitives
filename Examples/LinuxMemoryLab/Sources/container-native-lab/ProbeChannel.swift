import Containerization
import Foundation
import Synchronization

enum LabFailure: Error, Equatable { case arguments, framing, disconnected, deadline, invariant }

final class CommandInput: ReaderStream {
  private let values: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation
  init() {
    (values, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(1))
  }
  func stream() -> AsyncStream<Data> { values }
  func send(_ data: Data) throws {
    guard data.count <= 64 else { throw LabFailure.framing }
    guard case .enqueued = continuation.yield(data) else { throw LabFailure.disconnected }
  }
  func finish() { continuation.finish() }
}

final class ProbeOutput: Writer {
  private struct State {
    var bytes = Data()
    var total = 0
    var closed = false
  }
  private let state = Mutex(State())
  func write(_ data: Data) throws {
    try state.withLock { state in
      guard !state.closed, data.count <= 16384 - state.bytes.count,
        data.count <= 1024 * 1024 - state.total
      else { throw LabFailure.framing }
      state.bytes.append(data)
      state.total += data.count
    }
  }
  func close() { state.withLock { $0.closed = true } }
  func takeLine() throws -> String? {
    try state.withLock { state in
      if let newline = state.bytes.firstIndex(of: 10) {
        let line = state.bytes[..<newline]
        guard line.count <= 8192, line.allSatisfy({ $0 >= 32 && $0 <= 126 }) else {
          throw LabFailure.framing
        }
        let text = String(decoding: line, as: UTF8.self)
        state.bytes.removeSubrange(...newline)
        return text
      }
      guard state.bytes.count <= 8192 else { throw LabFailure.framing }
      guard !state.closed else { throw LabFailure.disconnected }
      return nil
    }
  }
}
