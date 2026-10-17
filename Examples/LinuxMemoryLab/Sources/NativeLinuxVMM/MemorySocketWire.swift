import Darwin
import Foundation
import Synchronization

enum MemorySocketFailure: Error, Equatable, Sendable {
  case system(String, Int32)
  case initialization(String, [MemorySocketFailure])
}

/// Transaction IO over the native vsock carrier's three SOCK_STREAM endpoints.
/// The caller exclusively borrows the handles during initialization; only our duplicates close.
final class MemorySocketWire: MemorySessionWire {
  private struct State {
    var descriptors: InlineArray<3, Int32>
    var closed = false
    var outputEOF = false
    var diagnostics = Data()
    var cleanupErrors: [MemorySocketFailure] = []
  }
  private let state: Mutex<State>
  private let output = NativeMemoryOutput()

  init(input: FileHandle, output: FileHandle, error: FileHandle) throws {
    let sources = [input.fileDescriptor, output.fileDescriptor, error.fileDescriptor]
    guard sources.allSatisfy({ $0 >= 0 }), Set(sources).count == 3 else {
      throw NativeControlFailure.ownership
    }
    var descriptors = InlineArray<3, Int32>(repeating: -1)
    do {
      for index in 0..<3 {
        let fd = fcntl(sources[index], F_DUPFD_CLOEXEC, 3)
        guard fd >= 0 else { throw MemorySocketFailure.system("duplicate", errno) }
        descriptors[index] = fd
        var kind: Int32 = 0
        var length = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_TYPE, &kind, &length) == 0 else {
          throw MemorySocketFailure.system("socket-type", errno)
        }
        guard length == MemoryLayout<Int32>.size, kind == SOCK_STREAM else {
          throw NativeControlFailure.ownership
        }
        let flags = fcntl(fd, F_GETFL)
        guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
          throw MemorySocketFailure.system("nonblocking", errno)
        }
        var one: Int32 = 1
        var immediate = linger(l_onoff: 0, l_linger: 0)
        guard setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, 4) == 0,
          setsockopt(fd, SOL_SOCKET, SO_LINGER, &immediate, socklen_t(MemoryLayout<linger>.size)) == 0
        else { throw MemorySocketFailure.system("socket-options", errno) }
      }
      state = Mutex(State(descriptors: descriptors))
    } catch {
      var failures: [MemorySocketFailure] = []
      for index in 0..<3 where descriptors[index] >= 0 {
        if Darwin.close(descriptors[index]) != 0 { failures.append(.system("close", errno)) }
      }
      if !failures.isEmpty {
        throw MemorySocketFailure.initialization(String(describing: error), failures)
      }
      throw error
    }
  }

  deinit { close() }

  func send(_ data: Data, until deadline: ContinuousClock.Instant) async throws {
    guard !data.isEmpty, data.count <= 64 else { throw NativeControlFailure.framing }
    var offset = 0
    while offset < data.count {
      try Task.checkCancellation()
      let count = try state.withLock { value -> Int in
        guard !value.closed, !value.outputEOF else { throw NativeControlFailure.disconnected }
        guard ContinuousClock.now < deadline else { throw NativeControlFailure.wireTimedOut }
        let result = data.withUnsafeBytes {
          Darwin.write(value.descriptors[0], $0.baseAddress! + offset, $0.count - offset)
        }
        if result < 0 {
          let failure = errno
          if failure == EINTR || failure == EAGAIN || failure == EWOULDBLOCK || failure == ENOBUFS {
            return 0
          }
          if failure == EPIPE || failure == ECONNRESET || failure == ENOTCONN {
            throw NativeControlFailure.disconnected
          }
          throw MemorySocketFailure.system("write", failure)
        }
        guard result > 0 else { throw MemorySocketFailure.system("write", EIO) }
        return result
      }
      offset += count
      if count == 0 {
        // shortcut: active-write retries; use readiness if measured control budgets require it.
        try await Task.sleep(
          until: min(.now.advanced(by: .milliseconds(2)), deadline), clock: .continuous)
      }
    }
  }

  func takeLine(allowAfterClose: Bool) throws -> String? {
    try state.withLock { value in
      if !value.closed, !value.outputEOF {
        try withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 4096) { buffer in
          for _ in 0..<4 {
            let count = Darwin.read(value.descriptors[1], buffer.baseAddress!, buffer.count)
            if count < 0 {
              if errno == EINTR { continue }
              if errno == EAGAIN || errno == EWOULDBLOCK { break }
              throw MemorySocketFailure.system("read", errno)
            }
            if count == 0 {
              value.outputEOF = true
              output.close()
              break
            }
            try output.write(Data(bytes: buffer.baseAddress!, count: count))
          }
        }
      }
      return try output.takeLine(allowAfterClose: allowAfterClose)
    }
  }

  /// Capped, sanitized error context survives descriptor retirement.
  var diagnosticText: String {
    state.withLock {
      String(
        decoding: $0.diagnostics.map { byte in
          byte == 9 || byte == 10 || (32...126).contains(byte) ? byte : 63
        }, as: UTF8.self)
    }
  }
  var cleanupErrors: [MemorySocketFailure] { state.withLock { $0.cleanupErrors } }

  private func captureDiagnostics(_ value: inout State) {
    withUnsafeTemporaryAllocation(of: UInt8.self, capacity: 512) { buffer in
      for _ in 0..<5 {
        let count = Darwin.read(value.descriptors[2], buffer.baseAddress!, buffer.count)
        if count < 0 {
          if errno == EINTR { continue }
          if errno != EAGAIN && errno != EWOULDBLOCK {
            value.cleanupErrors.append(.system("stderr", errno))
          }
          break
        }
        if count == 0 { break }
        let remaining = 2048 - value.diagnostics.count
        value.diagnostics.append(buffer.baseAddress!, count: min(count, remaining))
        if count > remaining {
          value.cleanupErrors.append(.system("stderr-bound", EOVERFLOW))
          break
        }
      }
    }
  }

  func close() {
    state.withLock { value in
      guard !value.closed else { return }
      value.closed = true
      captureDiagnostics(&value)
      for index in 0..<3 {
        let fd = value.descriptors[index]
        value.descriptors[index] = -1
        // Retrying an interrupted close could close an unrelated, reused descriptor.
        if Darwin.close(fd) != 0 { value.cleanupErrors.append(.system("close", errno)) }
      }
      output.close()
    }
  }
}
