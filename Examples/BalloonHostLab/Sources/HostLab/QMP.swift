import Foundation

#if canImport(Darwin)
  import Darwin
#elseif canImport(Musl)
  import Musl
#else
  import Glibc
#endif

public enum LabError: Error, Equatable {
  case deadline, disconnected, framing, protocolViolation
  case system(Int32)
  case rejected(String)
}

// Internal bounded wire framing, independent from JSON decoding and command correlation.
struct LineBuffer {
  private var bytes = Data()
  mutating func append(_ data: Data) throws {
    guard data.count <= 16384 - bytes.count else { throw LabError.framing }
    bytes.append(data)
  }
  mutating func take() -> Data? {
    guard let end = bytes.firstIndex(of: 10) else { return nil }
    let line = Data(bytes[..<end])
    bytes.removeSubrange(...end)
    return line
  }
}

private struct Envelope: Decodable {
  struct Balloon: Decodable { let actual: UInt64? }
  struct Failure: Decodable {
    let `class`: String
    let desc: String
  }
  struct Greeting: Decodable {
    struct Version: Decodable {
      struct Number: Decodable {
        let major: Int
        let minor: Int
      }
      let qemu: Number
    }
    let version: Version
  }
  let id: String?
  let event: String?
  let result: Balloon?
  let error: Failure?
  let greeting: Greeting?
  enum CodingKeys: String, CodingKey {
    case id, event, error
    case result = "return"
    case greeting = "QMP"
  }
}

/// One synchronous QMP session over exclusively owned pipe descriptors; not an async UI API.
/// Descriptor ownership stays with the caller. Serialized use, bounded frames and total deadline.
public struct QMPClient: ~Copyable {
  private let input: Int32
  private let output: Int32
  private let deadline: ContinuousClock.Instant
  private var buffer = LineBuffer()
  private var sequence: UInt64 = 0
  private var remainingBytes = 1_048_576
  private var greetingReceived = false
  private var negotiated = false

  public init(input: Int32, output: Int32, deadline: ContinuousClock.Instant) throws {
    guard input >= 0, output >= 0, input != output else { throw LabError.protocolViolation }
    for fd in [input, output] {
      let flags = fcntl(fd, F_GETFL)
      guard flags >= 0, fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
        throw LabError.system(errno)
      }
    }
    self.input = input
    self.output = output
    self.deadline = deadline
  }

  private func ready(_ fd: Int32, events: Int16) throws {
    while ContinuousClock.now < deadline {
      var descriptor = pollfd(fd: fd, events: events, revents: 0)
      let result = poll(&descriptor, 1, 10)
      if result < 0 {
        if errno == EINTR { continue }
        throw LabError.system(errno)
      }
      if result == 0 { continue }
      guard ContinuousClock.now < deadline else { throw LabError.deadline }
      guard descriptor.revents & Int16(POLLNVAL | POLLERR) == 0 else {
        throw LabError.disconnected
      }
      // Read buffered data before treating HUP as EOF.
      if descriptor.revents & (events | Int16(POLLHUP)) != 0 { return }
    }
    throw LabError.deadline
  }

  private mutating func receive() throws -> Envelope {
    while true {
      guard ContinuousClock.now < deadline else { throw LabError.deadline }
      if let line = buffer.take() {
        do { return try JSONDecoder().decode(Envelope.self, from: line) } catch {
          throw LabError.protocolViolation
        }
      }
      try ready(output, events: Int16(POLLIN))
      var scratch = [UInt8](repeating: 0, count: 4096)
      let count = scratch.withUnsafeMutableBytes { read(output, $0.baseAddress, $0.count) }
      if count < 0 {
        if errno == EINTR || errno == EAGAIN { continue }
        throw LabError.system(errno)
      }
      guard count > 0 else { throw LabError.disconnected }
      guard count <= remainingBytes else { throw LabError.framing }
      remainingBytes -= count
      try buffer.append(Data(scratch.prefix(count)))
    }
  }

  /// Accepts the pinned10.2 lab greeting before negotiation; no command is admitted earlier.
  public mutating func negotiate() throws {
    guard !greetingReceived else { throw LabError.protocolViolation }
    let greeting = try receive()
    guard let number = greeting.greeting?.version.qemu, number.major == 10, number.minor == 2,
      greeting.id == nil, greeting.event == nil, greeting.result == nil, greeting.error == nil
    else { throw LabError.protocolViolation }
    greetingReceived = true
    _ = try command("qmp_capabilities")
  }

  /// A successful balloon request does not imply actual convergence; query actual separately.
  @discardableResult public mutating func command(_ name: String, value: UInt64? = nil) throws
    -> UInt64?
  {
    guard sequence < UInt64.max,
      ["qmp_capabilities", "cont", "balloon", "query-balloon", "quit"].contains(name),
      greetingReceived, name == "qmp_capabilities" ? !negotiated : negotiated,
      (name == "balloon") == (value != nil), value == nil || value! <= UInt64(Int64.max)
    else { throw LabError.protocolViolation }
    sequence += 1
    let id = "balloon-lab-" + String(sequence)
    var object: [String: Any] = ["execute": name, "id": id]
    if let value { object["arguments"] = ["value": value] }
    var data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    data.append(10)
    guard data.count < 512 else { throw LabError.framing }
    var offset = 0
    while offset < data.count {
      try ready(input, events: Int16(POLLOUT))
      let count = data.withUnsafeBytes {
        write(input, $0.baseAddress!.advanced(by: offset), data.count - offset)
      }
      if count < 0 {
        if errno == EINTR || errno == EAGAIN { continue }
        throw LabError.system(errno)
      }
      guard count > 0 else { throw LabError.disconnected }
      offset += count
    }
    for _ in 0..<64 {
      let reply = try receive()
      if reply.event != nil {
        guard reply.id == nil, reply.result == nil, reply.error == nil, reply.greeting == nil else {
          throw LabError.protocolViolation
        }
        continue
      }
      guard reply.id == id, reply.greeting == nil,
        (reply.result != nil) != (reply.error != nil)
      else { throw LabError.protocolViolation }
      if let error = reply.error { throw LabError.rejected(error.class) }
      if name == "query-balloon" {
        guard let actual = reply.result?.actual, actual <= UInt64(Int64.max) else {
          throw LabError.protocolViolation
        }
        return actual
      }
      guard reply.result?.actual == nil else { throw LabError.protocolViolation }
      if name == "qmp_capabilities" { negotiated = true }
      return nil
    }
    throw LabError.framing
  }
}
