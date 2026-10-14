import Darwin
import Foundation

// A deliberately fixed initramfs, not a general archive extractor or provisioning tool.
enum Failure: Error { case arguments, image, output }
func validate(_ image: Data, limit: Int) throws {
  guard image.count >= 64, image.count <= limit,
    Array(image.prefix(6)) == [0x7f, 0x45, 0x4c, 0x46, 2, 1],
    image[16] == 2, image[17] == 0, image[18] == 183, image[19] == 0
  else { throw Failure.image }
  func number(_ index: Int, count: Int) -> UInt64 {
    var value: UInt64 = 0
    for byte in 0..<count { value |= UInt64(image[index + byte]) << (byte * 8) }
    return value
  }
  let start = number(32, count: 8)
  let count = number(56, count: 2)
  guard number(54, count: 2) == 56, count > 0, count <= 128, start >= 64,
    start <= UInt64(image.count), count * 56 <= UInt64(image.count) - start
  else { throw Failure.image }
  var load = false
  for index in 0..<Int(count) {
    let type = number(Int(start) + index * 56, count: 4)
    guard type != 2, type != 3 else { throw Failure.image }
    if type == 1 { load = true }
  }
  guard load else { throw Failure.image }
}
func run() throws {
  let args = CommandLine.arguments
  guard args.count == 4 else { throw Failure.arguments }
  let image = try Data(contentsOf: URL(filePath: args[1]), options: .mappedIfSafe)
  try validate(image, limit: 32 * 1024 * 1024)
  let bootstrap = try Data(contentsOf: URL(filePath: args[2]))
  try validate(bootstrap, limit: 256 * 1024)
  let fd = open(args[3], O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
  guard fd >= 0 else { throw Failure.output }
  let output = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
  var offset = 0
  func write(_ bytes: Data) throws {
    try output.write(contentsOf: bytes)
    offset += bytes.count
  }
  func align(_ boundary: Int) throws {
    try write(Data(repeating: 0, count: (boundary - offset % boundary) % boundary))
  }
  func entry(_ name: String, mode: Int, body: Data = Data(), major: Int = 0, minor: Int = 0) throws
  {
    let path = Data((name + "\0").utf8)
    let fields = [1, mode, 0, 0, 1, 0, body.count, 0, 0, major, minor, path.count, 0]
    let header = "070701" + fields.map { String(format: "%08x", $0) }.joined()
    guard header.utf8.count == 110 else { throw Failure.output }
    try write(Data(header.utf8))
    try write(path)
    try align(4)
    try write(body)
    try align(4)
  }
  for name in ["proc", "sys", "dev"] { try entry(name, mode: 0o040755) }
  try entry("dev/console", mode: 0o020600, major: 5, minor: 1)
  try entry("init", mode: 0o100755, body: bootstrap)
  try entry("probe", mode: 0o100755, body: image)
  try entry("TRAILER!!!", mode: 0)
  try align(512)
  try output.synchronize()
  try output.close()
  print("INITRAMFS_PASS \(offset)")

}
do { try run() } catch {
  fputs("INITRAMFS_FAIL \(error)\n", stderr)
  exit(1)
}
