import Darwin
import Dispatch
import Synchronization

/// A single receiver's level-triggered wakeup; no packet buffer or idle timer.
final class PacketReadiness: Sendable {
  private struct State {
    let source: any DispatchSourceRead
    var active = false
    var closed = false
    var waiter: CheckedContinuation<Void, any Error>?
    var events: UInt64 = 0
    var closeStatus: Int32?
  }
  private let state: Mutex<State>

  init(descriptor: Int32) throws {
    // The registration owns a duplicate: closing the link cannot reuse its watched descriptor.
    let owned = fcntl(descriptor, F_DUPFD_CLOEXEC, 3)
    guard owned >= 0 else { throw DeviceFailure.native(errno) }
    let source = DispatchSource.makeReadSource(
      fileDescriptor: owned, queue: DispatchQueue(label: "NativeLinuxVMM.packet-readiness"))
    state = Mutex(State(source: source))
    source.setEventHandler { [weak self] in self?.notify() }
    source.setCancelHandler { [weak self] in
      let result = Darwin.close(owned)
      let status = result == 0 ? 0 : errno
      self?.state.withLock { $0.closeStatus = status }
    }
  }

  deinit { cancel() }

  var status: (waiting: Bool, events: UInt64, closeStatus: Int32?) {
    state.withLock { ($0.waiter != nil, $0.events, $0.closeStatus) }
  }

  func wait() async throws {
    try Task.checkCancellation()
    try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { continuation in
        let failure: (any Error)? = state.withLock {
          guard !$0.closed else { return CancellationError() }
          guard $0.waiter == nil else { return NativeFailure.state }
          $0.waiter = continuation
          if !$0.active {
            $0.active = true
            $0.source.resume()
          }
          return nil
        }
        if let failure { continuation.resume(throwing: failure) }
      }
    } onCancel: {
      self.cancel()
    }
    try Task.checkCancellation()
  }

  private func notify() {
    let waiter = state.withLock {
      // Saturating diagnostic counter; never wrap after excessive peer activity.
      if $0.events < UInt64.max { $0.events += 1 }
      guard !$0.closed, $0.active else {
        return nil as CheckedContinuation<Void, any Error>?
      }
      // Unconsumed data must not spin the dispatch queue while the async reader resumes.
      $0.source.suspend()
      $0.active = false
      let waiter = $0.waiter
      $0.waiter = nil
      return waiter
    }
    waiter?.resume()
  }

  func cancel() {
    let waiter = state.withLock {
      guard !$0.closed else { return nil as CheckedContinuation<Void, any Error>? }
      $0.closed = true
      if !$0.active {
        $0.active = true
        $0.source.resume()
      }
      $0.source.cancel()
      let waiter = $0.waiter
      $0.waiter = nil
      return waiter
    }
    waiter?.resume(throwing: CancellationError())
  }
}
