import Containerization
import Foundation
import Synchronization

/// Bounded host control and transport failures; policy errors retain their original type.
public enum NativeControlFailure: Error, Equatable, Sendable {
  case arguments, framing, disconnected, wireTimedOut, invariant, ownership
  case capacityTimedOut, drainTimedOut, lifetimeExpired, staleObservation
  case unsettled, belowResidentFloor, quarantineTimedOut, pulseTimedOut
}

/// A single-consumer command wire, bounded to one queued command of at most64 bytes.
public final class NativeMemoryInput: ReaderStream {
  private let values: AsyncStream<Data>
  private let continuation: AsyncStream<Data>.Continuation
  public init() {
    (values, continuation) = AsyncStream.makeStream(bufferingPolicy: .bufferingOldest(1))
  }
  public func stream() -> AsyncStream<Data> { values }
  public func send(_ data: Data) throws {
    guard data.count <= 64 else { throw NativeControlFailure.framing }
    guard case .enqueued = continuation.yield(data) else { throw NativeControlFailure.disconnected }
  }
  public func finish() { continuation.finish() }
}

/// Printable ASCII frames, bounded to8KiB per line and16KiB of pending output.
public final class NativeMemoryOutput: Writer {
  private struct State {
    var bytes = Data()
    var closed = false
  }
  private let state = Mutex(State())
  public init() {}
  public func write(_ data: Data) throws {
    try state.withLock { state in
      guard !state.closed, data.count <= 16384 - state.bytes.count
      else { throw NativeControlFailure.framing }
      state.bytes.append(data)
    }
  }
  public func close() { state.withLock { $0.closed = true } }
  public func takeLine() throws -> String? {
    try state.withLock { state in
      if let newline = state.bytes.firstIndex(of: 10) {
        let line = state.bytes[..<newline]
        guard line.count <= 8192, line.allSatisfy({ $0 >= 32 && $0 <= 126 }) else {
          throw NativeControlFailure.framing
        }
        let text = String(decoding: line, as: UTF8.self)
        state.bytes.removeSubrange(...newline)
        return text
      }
      guard state.bytes.count <= 8192 else { throw NativeControlFailure.framing }
      guard !state.closed else { throw NativeControlFailure.disconnected }
      return nil
    }
  }
}
