import Containerization
import Foundation
import Synchronization

/// One bounded sink shared by a process's stdout and stderr; overflow stays observable.
final class BoundedOutput: Writer {
  enum Failure: Error { case limit }
  private struct State {
    var bytes = Data()
    var overflowed = false
  }
  private let state = Mutex(State())
  var text: String { state.withLock { String(decoding: $0.bytes, as: UTF8.self) } }
  var overflowed: Bool { state.withLock { $0.overflowed } }
  func write(_ value: Data) throws {
    try state.withLock {
      guard value.count <= (1 << 20) - $0.bytes.count else {
        $0.overflowed = true
        throw Failure.limit
      }
      $0.bytes.append(value)
    }
  }
  // One stream closing must not discard output still arriving on the other stream.
  func close() {}
}
