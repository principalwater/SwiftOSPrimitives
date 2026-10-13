import NIOCore
import NIOPosix
import PageMemory
import Synchronization

#if canImport(Darwin)
  import Darwin
#elseif canImport(Glibc)
  import Glibc
#else
  import Musl
#endif

final class Echo: ChannelInboundHandler {
  let stall: Bool
  init(stall: Bool) { self.stall = stall }
  typealias InboundIn = ByteBuffer
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    if !stall { context.writeAndFlush(data, promise: nil) }
  }
  func errorCaught(context: ChannelHandlerContext, error: any Error) { context.close(promise: nil) }
}

enum LabError: Error {
  case timeout, invalidReply
  case descriptorMismatch(before: Int, after: Int)
}
struct Reply: Sendable {
  let cycles: Int
  let digest: UInt64
}
final class Completion: Sendable {
  let promise: EventLoopPromise<Reply>
  private let finished = Mutex(false)
  init(_ promise: EventLoopPromise<Reply>) { self.promise = promise }
  private func claim() -> Bool {
    finished.withLock { value in
      if value { return false }
      value = true
      return true
    }
  }
  func succeed(_ reply: Reply) { if claim() { promise.succeed(reply) } }
  func fail(_ error: any Error) { if claim() { promise.fail(error) } }
}
func close(_ channel: Channel) throws {
  do { try channel.close().wait() } catch ChannelError.alreadyClosed {}
}

// All mutable handler state is confined to the channel's single EventLoop.
final class Ping: ChannelInboundHandler {
  typealias InboundIn = ByteBuffer
  typealias OutboundOut = ByteBuffer
  let total: Int
  let done: Completion
  var completed = 0
  var collected = 0
  var digest: UInt64 = 0
  var finished = false
  init(total: Int, done: Completion) {
    self.total = total
    self.done = done
  }
  func send(context: ChannelHandlerContext) {
    var buffer = context.channel.allocator.buffer(capacity: 128)
    buffer.writeRepeatingByte(UInt8(completed % 251 + 1), count: 128)
    context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
  }
  func channelActive(context: ChannelHandlerContext) { send(context: context) }
  func channelRead(context: ChannelHandlerContext, data: NIOAny) {
    guard !finished else { return }
    var buffer = unwrapInboundIn(data)
    while let byte: UInt8 = buffer.readInteger() {
      guard byte == UInt8(completed % 251 + 1), collected < 128 else {
        finished = true
        done.fail(LabError.invalidReply)
        context.close(promise: nil)
        return
      }
      digest += UInt64(byte)
      collected += 1
    }
    if collected == 128 {
      completed += 1
      collected = 0
      if completed == total {
        finished = true
        done.succeed(Reply(cycles: completed, digest: digest))
      } else {
        send(context: context)
      }
    }
  }
  func errorCaught(context: ChannelHandlerContext, error: any Error) {
    if !finished {
      finished = true
      done.fail(error)
    }
    context.close(promise: nil)
  }
  func channelInactive(context: ChannelHandlerContext) {
    if !finished {
      finished = true
      done.fail(LabError.invalidReply)
    }
  }
}

func perform(stall: Bool = false) throws {
  let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
  defer { try? group.syncShutdownGracefully() }
  let loop = group.next()
  let accepted = loop.makePromise(of: Channel.self)
  let done = Completion(loop.makePromise(of: Reply.self))
  let before = try ProcessMemorySnapshot.capture()
  let server = try ServerBootstrap(group: group)
    .serverChannelOption(ChannelOptions.backlog, value: 1)
    .childChannelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
    .childChannelInitializer { channel in
      do {
        try channel.pipeline.syncOperations.addHandler(Echo(stall: stall))
        accepted.succeed(channel)
      } catch {
        accepted.fail(error)
        return channel.eventLoop.makeFailedFuture(error)
      }
      return channel.eventLoop.makeSucceededVoidFuture()
    }.bind(host: "127.0.0.1", port: 0).wait()
  defer { try? server.close().wait() }
  let deadline = loop.scheduleTask(in: stall ? .milliseconds(50) : .seconds(5)) {
    done.fail(LabError.timeout)
  }
  defer { deadline.cancel() }
  let client = try ClientBootstrap(group: group)
    .connectTimeout(.seconds(2))
    .channelOption(ChannelOptions.tcpOption(.tcp_nodelay), value: 1)
    .channelInitializer { channel in
      do { try channel.pipeline.syncOperations.addHandler(Ping(total: 1000, done: done)) } catch {
        return channel.eventLoop.makeFailedFuture(error)
      }
      return channel.eventLoop.makeSucceededVoidFuture()
    }.connect(to: server.localAddress!).wait()
  defer { try? client.close().wait() }
  let reply = try done.promise.futureResult.wait()
  let peer = try accepted.futureResult.wait()
  try close(client)
  try close(peer)
  let after = try ProcessMemorySnapshot.capture()
  guard reply.cycles == 1000,
    reply.digest == (0..<1000).reduce(UInt64(0), { $0 + UInt64(($1 % 251 + 1) * 128) })
  else {
    throw LabError.invalidReply
  }
  print(
    "{\"cycles\":\(reply.cycles),\"digest\":\(reply.digest),\"rss_before\":\(before.residentBytes),\"rss_after\":\(after.residentBytes)}"
  )
}
func descriptorCount() throws -> Int {
  #if canImport(Darwin)
    let path = "/dev/fd"
  #else
    let path = "/proc/self/fd"
  #endif
  guard let directory = opendir(path) else { throw LabError.invalidReply }
  defer { closedir(directory) }
  var count = 0
  while let entry = readdir(directory) {
    let name = withUnsafePointer(to: &entry.pointee.d_name) { raw in
      raw.withMemoryRebound(to: CChar.self, capacity: 256) { String(cString: $0) }
    }
    if name != "." && name != ".." { count += 1 }
  }
  return count
}
do {
  // Warm native runtime/stdio once before comparing resource counts.
  try perform()
  // Observe stable counters around joined shutdown and asynchronous runtime cleanup.
  let settleEnd = ContinuousClock.now.advanced(by: .seconds(1))
  var before = try descriptorCount()
  var stable = 0
  while stable < 10 && ContinuousClock.now < settleEnd {
    _ = usleep(1000)
    let current = try descriptorCount()
    stable = current == before ? stable + 1 : 0
    before = current
  }
  for _ in 0..<20 { try perform() }
  for _ in 0..<10 {
    do {
      try perform(stall: true)
      throw LabError.invalidReply
    } catch LabError.timeout {}
  }
  let retirementEnd = ContinuousClock.now.advanced(by: .seconds(1))
  var after = try descriptorCount()
  while after != before && ContinuousClock.now < retirementEnd {
    _ = usleep(1000)
    after = try descriptorCount()
  }
  guard after == before else { throw LabError.descriptorMismatch(before: before, after: after) }
  print(
    "{\"resource_check\":\"passed\",\"fd_before\":\(before),\"fd_after\":\(after),\"timeouts\":10,\"successful_connections\":21}"
  )
} catch {
  print("NetworkLab failed: \(error)")
  exit(1)
}
