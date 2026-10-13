import PageMemory

func replaceMutableBorrow() throws {
  var first = try PageRegion.allocate(byteCount: 4096)
  try first.withMutableBytes { outer in
    do {
      var second = try! PageRegion.allocate(byteCount: 4096)
      try! second.withMutableBytes { inner in outer = inner }
    }
    outer[0] = 42
  }
}
