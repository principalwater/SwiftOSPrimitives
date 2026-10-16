import Darwin
import Dispatch
import Foundation

// A dead supervisor closes its only writer, even on SIGKILL; the VM owner then exits.
actor SupervisionLease {
  private let source: any DispatchSourceRead
  private let descriptor: Int32
  private var closed = false
  static func install() throws -> SupervisionLease? {
    let env = ProcessInfo.processInfo.environment
    guard let owner = env["SWIFTOS_LAB_PARENT"] else { return nil }
    guard let parent = Int32(owner), parent > 1, parent == getppid(),
      env["SWIFTOS_LAB_LEASE_FD"] == "3"
    else { throw Lab.Failure.check("supervisor identity") }
    var info = stat()
    guard fstat(3, &info) == 0, info.st_mode & S_IFMT == S_IFIFO,
      fcntl(3, F_GETFL) & O_ACCMODE == O_RDONLY
    else { throw Lab.Failure.check("supervisor pipe") }
    return SupervisionLease(descriptor: 3)
  }
  private init(descriptor: Int32) {
    self.descriptor = descriptor
    let queue = DispatchQueue(label: "SwiftOSPrimitives.supervisor-lease")
    source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
    source.setEventHandler {
      var byte: UInt8 = 0
      let count = Darwin.read(descriptor, &byte, 1)
      if count < 0, errno == EINTR || errno == EAGAIN { return }
      // No guest memory is reclaimed in place after its authority disappeared.
      let message: StaticString = "SUPERVISOR_LEASE_LOST\n"
      message.withUTF8Buffer { _ = Darwin.write(2, $0.baseAddress, $0.count) }
      _exit(125)
    }
    source.resume()
  }
  func close() async throws {
    guard !closed else { return }
    closed = true
    let fd = descriptor
    try await withCheckedThrowingContinuation {
      (continuation: CheckedContinuation<Void, any Error>) in
      source.setCancelHandler {
        if Darwin.close(fd) == 0 {
          continuation.resume()
        } else {
          continuation.resume(throwing: Lab.Failure.check("supervisor pipe close"))
        }
      }
      source.cancel()
    }
  }
}
