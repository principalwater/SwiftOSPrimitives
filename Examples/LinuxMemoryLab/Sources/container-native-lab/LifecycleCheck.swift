import Containerization
import Foundation
import NIOPosix
import NativeLinuxVMM

// This consumer observes failed-start retirement before performing fallback cleanup.
enum LifecycleCheck {
  enum Failure: Error { case contract }
  static func run(args: [String], output: URL) async throws {
    let group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
    let manager = NativeVirtualMachineManager(
      kernel: URL(filePath: args[0]), initfs: URL(filePath: args[1]),
      console: output.appending(path: "console.log"), group: group)
    var startError = ""
    var stopError = ""
    var groupError = ""
    var succeeded = false
    var before = Data()
    do {
      let instance = try await manager.create(
        config: StandardVMConfig(
          configuration: .init(
            cpus: 1, memoryInBytes: 1152 << 20,
            mountsByID: [
              "swiftos-native": [.block(format: "ext4", source: args[2], destination: "/")]
            ])))
      do {
        try await instance.start()
        succeeded = true
      } catch { startError = String(describing: error) }
      before = manager.instance?.result ?? Data()
    } catch { startError = "factory \(error)" }
    let errors = await Task { @concurrent in
      var errors = ["", ""]
      if let instance = manager.instance {
        do { try await instance.stop() } catch { errors[0] = String(describing: error) }
      }
      do { try await group.shutdownGracefully() } catch { errors[1] = String(describing: error) }
      return errors
    }.value
    stopError = errors[0]
    groupError = errors[1]
    let after = manager.instance?.result ?? Data()
    try before.write(
      to: output.appending(path: "before-caller-cleanup.json"), options: .withoutOverwriting)
    try after.write(
      to: output.appending(path: "after-caller-cleanup.json"), options: .withoutOverwriting)
    let observed = (try? JSONSerialization.jsonObject(with: before)) as? [String: Any]
    let checked =
      !succeeded && !startError.isEmpty && groupError.isEmpty
      && observed?["primaryError"] as? String == "arguments"
      && observed?["workerJoined"] as? Bool == true && observed?["joinError"] as? Int == 0
      && observed?["exits"] as? Int == 0
    let result: [String: Any] = [
      "checked": checked, "startError": startError,
      "stopError": stopError, "groupError": groupError, "startSucceeded": succeeded,
      "contract": "failed start joins native worker before returning to caller",
      "physicalReleasedBytes": NSNull(),
    ]
    try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
      .write(to: output.appending(path: "result.json"), options: .withoutOverwriting)
    guard checked else { throw Failure.contract }
    print("NATIVE_FAILED_START_JOIN_PASS")
  }
}
