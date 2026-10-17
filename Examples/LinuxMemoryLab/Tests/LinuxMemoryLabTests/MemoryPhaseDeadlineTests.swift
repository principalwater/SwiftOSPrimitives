import Foundation
import Testing

@testable import NativeLinuxVMM

@Test(.timeLimit(.minutes(1)), arguments: [false, true])
func memoryPhaseCannotRenewAnExpiredOwnerBudget(quitting: Bool) async throws {
  let input = NativeMemoryInput()
  defer { input.finish() }
  let output = NativeMemoryOutput()
  let session = try NativeMemorySession(input: input, output: output, maximumGuestBytes: 1000)
  try output.write(Data("MEMORY_READY 1000 900\n".utf8))
  if quitting { try await session.start() }
  let expired = ContinuousClock.now.advanced(by: .seconds(-1))
  if quitting {
    await #expect(throws: NativeControlFailure.wireTimedOut) {
      try await session.quit(until: expired)
    }
  } else {
    await #expect(throws: NativeControlFailure.wireTimedOut) {
      try await session.start(until: expired)
    }
  }
  await session.close()
  var commands = input.stream().makeAsyncIterator()
  #expect(await commands.next() == nil)
}
