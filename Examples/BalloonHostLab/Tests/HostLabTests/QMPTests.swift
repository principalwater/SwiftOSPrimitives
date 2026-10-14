import Foundation
import Testing

@testable import HostLab

struct QMPTests {
  @Test func fragmentedFramesAndBound() throws {
    var buffer = LineBuffer()
    try buffer.append(Data("{\"a\":1}\r".utf8))
    #expect(buffer.take() == nil)
    try buffer.append(Data("\n{}\n".utf8))
    #expect(buffer.take() == Data("{\"a\":1}\r".utf8))
    #expect(buffer.take() == Data("{}".utf8))
    #expect(buffer.take() == nil)
    try buffer.append(Data(repeating: 32, count: 16384))
    #expect(throws: LabError.framing) { try buffer.append(Data([10])) }
  }

  @Test func realPipeCorrelationAndErrorRefusals() throws {
    let greeting = "{\"QMP\":{\"version\":{\"qemu\":{\"major\":10,\"minor\":2}}}}\n"
    for (reply, expected) in [
      ("{\"return\":{},\"id\":\"foreign\"}\n", LabError.protocolViolation),
      (
        "{\"return\":{},\"error\":{\"class\":\"X\",\"desc\":\"x\"},\"id\":\"balloon-lab-1\"}\n",
        .protocolViolation
      ),
      (
        "{\"error\":{\"class\":\"DeviceNotActive\",\"desc\":\"absent\"},\"id\":\"balloon-lab-1\"}\n",
        .rejected("DeviceNotActive")
      ),
      ("not JSON\n", .protocolViolation),
    ] {
      let input = Pipe()
      let output = Pipe()
      try output.fileHandleForWriting.write(contentsOf: Data((greeting + reply).utf8))
      var client = try QMPClient(
        input: input.fileHandleForWriting.fileDescriptor,
        output: output.fileHandleForReading.fileDescriptor,
        deadline: .now.advanced(by: .seconds(1)))
      #expect(throws: expected) { try client.negotiate() }
    }
  }

  @Test func realPipeEventsObservationAndDeadline() throws {
    let input = Pipe()
    let output = Pipe()
    let wire = """
      {"QMP":{"version":{"qemu":{"major":10,"minor":2}}}}
      {"return":{},"id":"balloon-lab-1"}
      {"event":"BALLOON_CHANGE","data":{"actual":49152}}
      {"return":{"actual":49152},"id":"balloon-lab-2"}

      """
    try output.fileHandleForWriting.write(contentsOf: Data(wire.utf8))
    var client = try QMPClient(
      input: input.fileHandleForWriting.fileDescriptor,
      output: output.fileHandleForReading.fileDescriptor,
      deadline: .now.advanced(by: .seconds(1)))
    try client.negotiate()
    #expect(try client.command("query-balloon") == 49152)
    var expired = try QMPClient(
      input: input.fileHandleForWriting.fileDescriptor,
      output: output.fileHandleForReading.fileDescriptor, deadline: .now)
    #expect(throws: LabError.deadline) { try expired.negotiate() }
    try output.fileHandleForWriting.close()
    #expect(throws: LabError.disconnected) { try client.command("query-balloon") }
  }

  @Test func malformedActualAndEventIdentity() throws {
    let prefix = """
      {"QMP":{"version":{"qemu":{"major":10,"minor":2}}}}
      {"return":{},"id":"balloon-lab-1"}

      """
    for response in [
      "{\"return\":{},\"id\":\"balloon-lab-2\"}\n",
      "{\"return\":{\"actual\":-1},\"id\":\"balloon-lab-2\"}\n",
      "{\"return\":{\"actual\":true},\"id\":\"balloon-lab-2\"}\n",
      "{\"event\":\"BALLOON_CHANGE\",\"id\":\"balloon-lab-2\"}\n",
      "{\"return\":{\"actual\":65536},\"id\":\"balloon-lab-1\"}\n",
    ] {
      let input = Pipe()
      let output = Pipe()
      try output.fileHandleForWriting.write(contentsOf: Data((prefix + response).utf8))
      var client = try QMPClient(
        input: input.fileHandleForWriting.fileDescriptor,
        output: output.fileHandleForReading.fileDescriptor,
        deadline: .now.advanced(by: .seconds(1)))
      #expect(throws: LabError.protocolViolation) { try client.command("query-balloon") }
      try client.negotiate()
      #expect(throws: LabError.protocolViolation) { try client.command("query-balloon") }
    }
  }
}
