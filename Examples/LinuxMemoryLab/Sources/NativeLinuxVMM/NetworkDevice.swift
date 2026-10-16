import Containerization
import ContainerizationExtras
import Darwin
import Foundation
import Synchronization

/// An owned private Ethernet cable. It creates no host interface or IP route.
public final class IsolatedNetwork: Interface {
  public let index: Int
  public let ipv4Address: CIDRv4
  public var ipv4Gateway: IPv4Address? { nil }
  public let macAddress: MACAddress?
  private struct State {
    var device: Int32
    var peer: Int32
  }
  private let state: Mutex<State>
  public init(index: Int = 0) throws {
    guard (0...1).contains(index) else { throw NativeFailure.unsupported }
    self.index = index
    ipv4Address = try CIDRv4(index == 0 ? "192.0.2.2/30" : "198.51.100.2/30")
    macAddress = try MACAddress(index == 0 ? "02:00:00:00:00:02" : "02:00:00:00:01:02")
    var descriptors: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_DGRAM, 0, &descriptors) == 0 else {
      throw DeviceFailure.native(errno)
    }
    do {
      for descriptor in descriptors {
        var enabled: Int32 = 1
        var capacity: Int32 = 65536
        guard fcntl(descriptor, F_SETFD, FD_CLOEXEC) == 0,
          fcntl(descriptor, F_SETFL, O_NONBLOCK) == 0,
          setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &enabled, 4) == 0,
          setsockopt(descriptor, SOL_SOCKET, SO_SNDBUF, &capacity, 4) == 0,
          setsockopt(descriptor, SOL_SOCKET, SO_RCVBUF, &capacity, 4) == 0
        else { throw DeviceFailure.native(errno) }
      }
    } catch {
      for descriptor in descriptors { _ = Darwin.close(descriptor) }
      throw error
    }
    state = Mutex(State(device: descriptors[0], peer: descriptors[1]))
  }
  func claim() throws -> Int32 {
    try state.withLock {
      guard $0.device >= 0, $0.peer >= 0 else { throw NativeFailure.state }
      let descriptor = $0.device
      $0.device = -1
      return descriptor
    }
  }
  /// Returns false for bounded peer backpressure without losing the caller's packet.
  public func send(_ frame: Data) throws -> Bool {
    guard (14...1514).contains(frame.count) else { throw DeviceFailure.request }
    return try state.withLock {
      guard $0.peer >= 0 else { throw NativeFailure.state }
      return try Self.transmit(frame, descriptor: $0.peer)
    }
  }
  public func receive() throws -> Data? {
    try state.withLock {
      guard $0.peer >= 0 else { throw NativeFailure.state }
      return try Self.receive(descriptor: $0.peer)
    }
  }
  static func transmit(_ frame: Data, descriptor: Int32) throws -> Bool {
    let count = frame.withUnsafeBytes { Darwin.send(descriptor, $0.baseAddress, $0.count, 0) }
    if count == frame.count { return true }
    if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == ENOBUFS || errno == EINTR {
      return false
    }
    throw DeviceFailure.native(errno)
  }
  static func receive(descriptor: Int32) throws -> Data? {
    var bytes = [UInt8](repeating: 0, count: 1515)
    let count = recv(descriptor, &bytes, bytes.count, 0)
    if count < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == ENOBUFS || errno == EINTR {
      return nil
    }
    guard (14...1514).contains(count) else {
      throw DeviceFailure.descriptor("ethernet-size count=\(count) errno=\(errno)")
    }
    return Data(bytes.prefix(count))
  }
  public func close() throws {
    try state.withLock {
      var first: Int32 = 0
      for descriptor in [$0.peer, $0.device] where descriptor >= 0 {
        if Darwin.close(descriptor) != 0, first == 0 { first = errno }
      }
      $0.peer = -1
      $0.device = -1
      guard first == 0 else { throw DeviceFailure.native(first) }
    }
  }
  deinit { try? close() }
}

// Only the stopped-vCPU coordinator can resolve/copy NIC DMA payloads.
final class NetworkDevice {
  let thread = pthread_self()
  private var descriptor: Int32
  private var received: Data?
  let transport: VirtioMMIO
  let index: Int
  var txPackets = 0
  var rxPackets = 0
  init(network: IsolatedNetwork) throws {
    index = network.index
    transport = VirtioMMIO(
      identity: 1, features: (1 << 5) | (1 << 16), interrupt: UInt32(39 + index), queueCount: 2)
    descriptor = try network.claim()
  }
  private func confined() throws {
    guard pthread_equal(thread, pthread_self()) != 0 else { throw DeviceFailure.request }
  }
  func config() -> Data { Data([2, 0, 0, 0, UInt8(index), 2, 1, 0]) }
  func poll(
    memory: (UInt64, Int) throws -> UnsafeMutableRawPointer,
    payloadMemory: (UInt64, Int) throws -> UnsafeMutableRawPointer
  ) throws {
    try confined()
    if transport.status == 0 { received = nil }
    guard transport.status & 0xcc == 12 else { return }
    if transport.queues[1].ready {
      if try transport.queues[1].drain(
        memory: memory,
        process: { buffers in
          let size = buffers.reduce(0) { $0 + $1.size }
          guard buffers.allSatisfy({ !$0.writable }), (26...1526).contains(size) else {
            throw DeviceFailure.descriptor("net-tx-layout")
          }
          var packet = Data()
          for buffer in buffers {
            var copied = 0
            while copied < buffer.size {
              let address = buffer.address + UInt64(copied)
              let count = min(
                buffer.size - copied, MemoryDevice.block - Int(address % UInt64(MemoryDevice.block))
              )
              packet.append(Data(bytes: try payloadMemory(address, count), count: count))
              copied += count
            }
          }
          guard packet[0] == 0, packet[1] == 0 else {
            throw DeviceFailure.descriptor("net-unnegotiated-offload")
          }
          guard
            try IsolatedNetwork.transmit(Data(packet.dropFirst(12)), descriptor: self.descriptor)
          else { return nil }
          self.txPackets += 1
          return 0
        })
      {
        transport.interruptStatus |= 1
      }
    }
    if received == nil { received = try IsolatedNetwork.receive(descriptor: descriptor) }
    if transport.queues[0].ready, received != nil {
      if try transport.queues[0].drain(
        memory: memory,
        process: { buffers in
          guard let frame = self.received else { return nil }
          let capacity = buffers.reduce(0) { $0 + $1.size }
          guard buffers.allSatisfy(\.writable), capacity >= frame.count + 12 else {
            throw DeviceFailure.descriptor("net-rx-capacity")
          }
          var packet = Data(count: 12)
          packet[10] = 1
          packet.append(frame)
          var offset = 0
          for buffer in buffers where offset < packet.count {
            let size = min(buffer.size, packet.count - offset)
            var copied = 0
            while copied < size {
              let address = buffer.address + UInt64(copied)
              let count = min(
                size - copied, MemoryDevice.block - Int(address % UInt64(MemoryDevice.block)))
              let destination = try payloadMemory(address, count)
              packet.withUnsafeBytes {
                destination.copyMemory(from: $0.baseAddress! + offset + copied, byteCount: count)
              }
              copied += count
            }
            offset += size
          }
          self.received = nil
          self.rxPackets += 1
          return UInt32(packet.count)
        })
      {
        transport.interruptStatus |= 1
      }
    }
  }
  func close() throws {
    try confined()
    if descriptor >= 0 {
      let result = Darwin.close(descriptor)
      descriptor = -1
      guard result == 0 else { throw DeviceFailure.native(errno) }
    }
  }
}
