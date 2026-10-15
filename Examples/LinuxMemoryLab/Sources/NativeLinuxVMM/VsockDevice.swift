import Containerization
import Darwin
import Foundation

// A single stopped vCPU owns all descriptors, credits and local socket I/O.
final class VsockDevice {
  struct Packet {
    var source: UInt32
    var destination: UInt32
    var operation: UInt16
    var flags: UInt32 = 0
    var allocation: UInt32 = 65536
    var forwarded: UInt32 = 0
    var payload = Data()

    func encoded() -> Data {
      var data = Data()
      func append<T: FixedWidthInteger>(_ value: T) {
        var little = value.littleEndian
        withUnsafeBytes(of: &little) { data.append(contentsOf: $0) }
      }
      append(UInt64(2))
      append(UInt64(3))
      append(source)
      append(destination)
      append(UInt32(payload.count))
      append(UInt16(1))
      append(operation)
      append(flags)
      append(allocation)
      append(forwarded)
      data.append(payload)
      return data
    }
  }
  struct Key: Hashable, Comparable {
    let local: UInt32
    let remote: UInt32
    static func < (lhs: Self, rhs: Self) -> Bool {
      lhs.local < rhs.local || lhs.local == rhs.local && lhs.remote < rhs.remote
    }
  }
  struct Connection {
    let descriptor: Int32
    var remote: UInt32
    var established = false
    var allocation: UInt32 = 0
    var forwarded: UInt32 = 0
    var sent: UInt32 = 0
    var received: UInt32 = 0
    var delivered: UInt32 = 0
    var pending = Data()
    var shutdownSent = false
    var peerShutdown: UInt32 = 0
    var writeEOF = false
  }
  let transport = VirtioMMIO(identity: 19, features: 0, interrupt: 38, queueCount: 3)
  var connections: [Key: Connection] = [:]
  let thread = pthread_self()
  var packets: [Packet] = []
  let control: NativeControl

  init(control: NativeControl) { self.control = control }

  static func pair() throws -> (Int32, Int32) {
    var fds: [Int32] = [-1, -1]
    guard socketpair(AF_UNIX, SOCK_STREAM, 0, &fds) == 0 else {
      throw DeviceFailure.native(errno)
    }
    do {
      for fd in fds {
        var enabled: Int32 = 1
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0,
          setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &enabled, 4) == 0
        else { throw DeviceFailure.native(errno) }
      }
      guard fcntl(fds[0], F_SETFL, O_NONBLOCK) == 0 else {
        throw DeviceFailure.native(errno)
      }
      return (fds[0], fds[1])
    } catch {
      _ = Darwin.close(fds[0])
      _ = Darwin.close(fds[1])
      throw error
    }
  }

  private func confined() throws {
    guard pthread_equal(thread, pthread_self()) != 0 else { throw DeviceFailure.request }
  }
  func enqueue(_ packet: Packet) throws {
    try confined()
    guard packets.count < 128, packet.payload.count <= 16384 else {
      throw DeviceFailure.descriptor("vsock-output-bound")
    }
    packets.append(packet)
  }
  func open(_ port: UInt32, descriptor: Int32, token: UInt32) throws {
    try confined()
    let key = Key(local: token, remote: port)
    guard connections.count < 32, connections[key] == nil else {
      _ = Darwin.close(descriptor)
      throw DeviceFailure.request
    }
    connections[key] = Connection(descriptor: descriptor, remote: port)
    try enqueue(Packet(source: token, destination: port, operation: 1))
  }
  func remove(_ key: Key) {
    let port = key.local
    if let connection = connections.removeValue(forKey: key) {
      _ = Darwin.close(connection.descriptor)
    }
    control.state.withLock { if $0.pendingDials.contains(port) { $0.connected[port] = false } }
  }
  func cancel(_ token: UInt32) {
    for key in Array(connections.keys) where key.local == token { remove(key) }
    packets.removeAll { $0.source == token }
  }
  func receive(_ data: Data) throws {
    try confined()
    guard data.count >= 44 else { throw DeviceFailure.request }
    func load<T: FixedWidthInteger>(_ offset: Int, _ type: T.Type) -> T {
      data.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: offset, as: T.self).littleEndian }
    }
    let source = load(16, UInt32.self)
    let destination = load(20, UInt32.self)
    let length = load(24, UInt32.self)
    let operation = load(30, UInt16.self)
    let flags = load(32, UInt32.self)
    let key = Key(local: destination, remote: source)
    let allocation = load(36, UInt32.self)
    let forwarded = load(40, UInt32.self)
    guard load(0, UInt64.self) == 3, load(8, UInt64.self) == 2,
      load(28, UInt16.self) == 1, length <= 65536, Int(length) == data.count - 44,
      operation == 5 || length == 0
    else { throw DeviceFailure.descriptor("vsock-header") }
    if operation == 1 {
      guard forwarded == 0 else { throw DeviceFailure.descriptor("vsock-initial-credit") }
      guard connections.count < 32, connections[key] == nil,
        let listener = control.state.withLock({ $0.listeners[destination] })
      else {
        try enqueue(Packet(source: destination, destination: source, operation: 3))
        return
      }
      let pair = try Self.pair()
      connections[key] = Connection(
        descriptor: pair.0, remote: source, established: true, allocation: min(allocation, 65536),
        forwarded: forwarded)
      if case .terminated = listener.yield(
        FileHandle(fileDescriptor: pair.1, closeOnDealloc: false))
      {
        _ = Darwin.close(pair.1)
        remove(key)
        try enqueue(Packet(source: destination, destination: source, operation: 3))
      } else {
        try enqueue(Packet(source: destination, destination: source, operation: 2))
      }
      return
    }
    guard var connection = connections[key], connection.remote == source else {
      if operation != 3 {
        try enqueue(Packet(source: destination, destination: source, operation: 3))
      }
      return
    }
    if operation == 3 {
      remove(key)
      return
    }
    guard connection.sent &- forwarded <= connection.sent &- connection.forwarded else {
      throw DeviceFailure.descriptor("vsock-credit")
    }
    connection.allocation = min(allocation, 65536)
    connection.forwarded = forwarded
    switch operation {
    case 2:
      guard !connection.established else { throw DeviceFailure.request }
      connection.established = true
      control.state.withLock {
        if $0.pendingDials.contains(destination) { $0.connected[destination] = true }
      }
    case 3:
      remove(key)
      return
    case 4:
      guard flags != 0, flags & ~3 == 0 else { throw DeviceFailure.request }
      connection.peerShutdown |= flags
      if flags & 1 != 0 {
        connection.shutdownSent = true
        guard shutdown(connection.descriptor, SHUT_RD) == 0 || errno == ENOTCONN else {
          throw DeviceFailure.native(errno)
        }
      }
    case 5:
      guard connection.established,
        length <= 65536 - (connection.received &- connection.delivered)
      else { throw DeviceFailure.descriptor("vsock-input-bound") }
      connection.pending.append(data.dropFirst(44))
      connection.received &+= length
    case 6: break
    case 7:
      try enqueue(
        Packet(
          source: destination, destination: source, operation: 6,
          forwarded: connection.delivered))
    default: throw DeviceFailure.request
    }
    connections[key] = connection
  }
  private func flush(_ connection: inout Connection, local: UInt32) throws -> Bool {
    let before = connection.delivered
    while !connection.pending.isEmpty {
      let count = connection.pending.withUnsafeBytes {
        Darwin.write(connection.descriptor, $0.baseAddress!, $0.count)
      }
      if count < 0 && errno == EINTR { continue }
      if count < 0 && (errno == EAGAIN || errno == EWOULDBLOCK) { break }
      if count < 0 && (errno == EPIPE || errno == ECONNRESET) { return false }
      guard count > 0 else { throw DeviceFailure.native(errno) }
      connection.pending.removeFirst(count)
      connection.delivered &+= UInt32(count)
    }
    if connection.delivered != before {
      try enqueue(
        Packet(
          source: local, destination: connection.remote, operation: 6,
          forwarded: connection.delivered))
    }
    return true
  }
  func poll(
    memory: (UInt64, Int) throws -> UnsafeMutableRawPointer,
    payloadMemory: (UInt64, Int) throws -> UnsafeMutableRawPointer
  ) throws {
    try confined()
    guard transport.status & 12 == 12 else { return }
    for key in Array(connections.keys).sorted() {
      let port = key.local
      guard var connection = connections[key], connection.established else { continue }
      guard try flush(&connection, local: port) else {
        try enqueue(Packet(source: port, destination: connection.remote, operation: 3))
        remove(key)
        continue
      }
      if connection.pending.isEmpty, connection.peerShutdown & 2 != 0, !connection.writeEOF {
        guard shutdown(connection.descriptor, SHUT_WR) == 0 || errno == ENOTCONN else {
          throw DeviceFailure.native(errno)
        }
        connection.writeEOF = true
      }
      if connection.peerShutdown == 3, connection.pending.isEmpty {
        try enqueue(Packet(source: port, destination: connection.remote, operation: 3))
        remove(key)
        continue
      }
      let outstanding = connection.sent &- connection.forwarded
      let space = connection.allocation - min(outstanding, connection.allocation)
      if space > 0, packets.count < 96, !connection.shutdownSent {
        var bytes = [UInt8](repeating: 0, count: min(Int(space), 16384))
        let count = Darwin.read(connection.descriptor, &bytes, bytes.count)
        if count > 0 {
          try enqueue(
            Packet(
              source: port, destination: connection.remote, operation: 5,
              forwarded: connection.delivered, payload: Data(bytes.prefix(count))))
          connection.sent &+= UInt32(count)
        } else if count == 0 {
          try enqueue(
            Packet(
              source: port, destination: connection.remote, operation: 4,
              flags: 3, forwarded: connection.delivered))
          connection.shutdownSent = true
        } else if errno != EINTR && errno != EAGAIN && errno != EWOULDBLOCK {
          throw DeviceFailure.native(errno)
        }
      }
      connections[key] = connection
    }
    if transport.queues[0].ready, !packets.isEmpty {
      if try transport.queues[0].drain(
        memory: memory,
        process: { buffers in
          guard !self.packets.isEmpty else { return nil }
          guard buffers.allSatisfy(\.writable) else { throw DeviceFailure.request }
          let capacity = buffers.reduce(0, { $0 + $1.size })
          guard capacity >= 44 else { throw DeviceFailure.descriptor("vsock-rx-header") }
          var fragment = self.packets[0]
          let payloadCount = min(fragment.payload.count, capacity - 44)
          guard fragment.payload.isEmpty || payloadCount > 0 else {
            throw DeviceFailure.descriptor("vsock-rx-progress")
          }
          fragment.payload = Data(fragment.payload.prefix(payloadCount))
          let packet = fragment.encoded()
          var offset = 0
          for buffer in buffers where offset < packet.count {
            let count = min(buffer.size, packet.count - offset)
            var copied = 0
            while copied < count {
              let address = buffer.address + UInt64(copied)
              let piece = min(
                count - copied, MemoryDevice.block - Int(address % UInt64(MemoryDevice.block)))
              let destination = try payloadMemory(address, piece)
              packet.withUnsafeBytes {
                destination.copyMemory(from: $0.baseAddress! + offset + copied, byteCount: piece)
              }
              copied += piece
            }
            offset += count
          }
          if payloadCount == self.packets[0].payload.count {
            self.packets.removeFirst()
          } else {
            self.packets[0].payload.removeFirst(payloadCount)
          }
          return UInt32(packet.count)
        })
      {
        transport.interruptStatus |= 1
      }
    }
  }
  func notify(
    _ queue: UInt32, memory: (UInt64, Int) throws -> UnsafeMutableRawPointer,
    payloadMemory: (UInt64, Int) throws -> UnsafeMutableRawPointer
  ) throws {
    try confined()
    if queue == 1 {
      if try transport.queues[1].drain(
        memory: memory,
        process: { buffers in
          guard buffers.allSatisfy({ !$0.writable }),
            buffers.reduce(0, { $0 + $1.size }) <= 65580
          else { throw DeviceFailure.request }
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
          try self.receive(packet)
          return 0
        })
      {
        transport.interruptStatus |= 1
      }
    }
    try poll(memory: memory, payloadMemory: payloadMemory)
  }
  func close() {
    precondition(pthread_equal(thread, pthread_self()) != 0, "VMM owner thread required")
    for port in Array(connections.keys) { remove(port) }
  }
}
