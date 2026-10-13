import PageMemory

func releaseDuringBorrow() throws {
  var region = try PageRegion.allocate(byteCount: 4096)
  _ = try region.withBytes { bytes in
    try! region.release()
    return bytes.count
  }
}
