import Containerization
import ContainerizationExtras
import Foundation
import Synchronization
@preconcurrency import Virtualization

/// One VM's native request channel. Guest completion and held budget belong to its serial owner.
public final class ContainerBalloonDevice: VZInstanceExtension {
  public enum Failure: Error, Equatable {
    case duplicateConfiguration, unexpectedDevice, invalidTarget, unbound, retired, state, stopInProgress
  }
  private struct State {
    weak var instance: VZVirtualMachineInstance?
    var ceiling: UInt64 = 0
    var bound = false
    var retired = false
    var stopInFlight = false
  }
  private let state = Mutex(State())
  private let minimumResidentBytes: UInt64
  public init(minimumResidentBytes: UInt64) { self.minimumResidentBytes = minimumResidentBytes }

  /// Diagnostic/lifecycle ownership, not a helper PID or physical backing identity.
  public var virtualMachineInstance: VZVirtualMachineInstance? {
    state.withLock { $0.instance }
  }

  public func configureVZ(
    _ config: inout VZVirtualMachineConfiguration,
    allocator: any AddressAllocator<Character>,
    storageDeviceCount: Int, mountsByID: [String: [Mount]]
  ) throws {
    try state.withLock { state in
      guard state.ceiling == 0, !state.retired else { throw Failure.duplicateConfiguration }
      guard config.memoryBalloonDevices.isEmpty else { throw Failure.unexpectedDevice }
      guard config.memorySize >= VZVirtualMachineConfiguration.minimumAllowedMemorySize,
        config.memorySize % (1 << 20) == 0,
        minimumResidentBytes >= VZVirtualMachineConfiguration.minimumAllowedMemorySize,
        minimumResidentBytes <= config.memorySize, minimumResidentBytes % (1 << 20) == 0
      else { throw Failure.invalidTarget }
      state.ceiling = config.memorySize
      config.memoryBalloonDevices = [VZVirtioTraditionalMemoryBalloonDeviceConfiguration()]
    }
  }
  public func didCreate(_ instance: VZVirtualMachineInstance) throws {
    try state.withLock { state in
      guard state.ceiling != 0, !state.bound, !state.retired else { throw Failure.unbound }
      state.instance = instance
      state.bound = true
    }
  }
  /// Close admission before the owner joins IO/stops/pauses its VM. This never stops transport.
  public func retire() { state.withLock { $0.retired = true } }
  public func willStop(_ instance: VZVirtualMachineInstance) async throws { retire() }

  public enum StopOutcome: Sendable, Equatable { case stopped, alreadyStopped }

  /// Destructively stop this exact VM after closing balloon admission, including when paused.
  /// This bypasses guest RPCs and upstream lifecycle cleanup. The owner must still join IO/runtime
  /// work. Once issued, caller cancellation does not abandon the native callback; an external
  /// process deadline remains necessary if the framework itself cannot complete.
  public func retireAndStop() async throws -> StopOutcome {
    let instance = try state.withLock { state in
      state.retired = true
      guard !state.stopInFlight else { throw Failure.stopInProgress }
      guard let instance = state.instance else { throw Failure.unbound }
      state.stopInFlight = true
      return instance
    }
    defer { state.withLock { $0.stopInFlight = false } }
    return try await withCheckedThrowingContinuation {
      (reply: CheckedContinuation<StopOutcome, any Error>) in
      instance.vmQueue.async {
        let vm = instance.vzVirtualMachine
        if vm.state == .stopped {
          reply.resume(returning: .alreadyStopped)
          return
        }
        guard vm.canStop else {
          reply.resume(throwing: Failure.state)
          return
        }
        vm.stop { error in
          if let error {
            reply.resume(throwing: error)
          } else if vm.state == .stopped {
            reply.resume(returning: .stopped)
          } else {
            reply.resume(throwing: Failure.state)
          }
        }
      }
    }
  }

  /// Setter delivery/readback only. The owner still needs a fresh guest observation to complete it.
  public func request(_ bytes: UInt64) async throws -> UInt64 {
    let instance = try state.withLock { state in
      guard !state.retired else { throw Failure.retired }
      guard bytes >= minimumResidentBytes,
        bytes <= state.ceiling, bytes % (1 << 20) == 0
      else { throw Failure.invalidTarget }
      guard let instance = state.instance else { throw Failure.unbound }
      return instance
    }
    let cancelled = Mutex(Task.isCancelled)
    return try await withTaskCancellationHandler {
      try await withCheckedThrowingContinuation { (reply: CheckedContinuation<UInt64, any Error>) in
        instance.vmQueue.async {
          do {
            let applied = try cancelled.withLock { cancelled in
              guard !cancelled else { throw CancellationError() }
              return try self.state.withLock { state in
                guard !state.retired, state.instance === instance else { throw Failure.retired }
                // state is queue.sync-backed; inspect the raw VZ state only on its owning queue.
                let vm = instance.vzVirtualMachine
                guard vm.state == .running, vm.memoryBalloonDevices.count == 1,
                  let device = vm.memoryBalloonDevices[0] as? VZVirtioTraditionalMemoryBalloonDevice
                else { throw Failure.state }
                device.targetVirtualMachineMemorySize = bytes
                guard device.targetVirtualMachineMemorySize == bytes else { throw Failure.state }
                return bytes
              }
            }
            reply.resume(returning: applied)
          } catch { reply.resume(throwing: error) }
        }
      }
    } onCancel: {
      cancelled.withLock { $0 = true }
    }
  }
}

/// Inject one native device through the release's public VM creation extension point.
public struct BalloonVirtualMachineManager: VirtualMachineManager {
  private let base: VZVirtualMachineManager
  public let device: ContainerBalloonDevice
  public init(base: VZVirtualMachineManager, device: ContainerBalloonDevice) {
    self.base = base
    self.device = device
  }
  public func create(config: some VMCreationConfig) async throws -> any VirtualMachineInstance {
    var configuration = config.configuration
    configuration.extensions.append(device)
    return try base.create(config: StandardVMConfig(configuration: configuration))
  }
}
