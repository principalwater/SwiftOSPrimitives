import PageMemory

func retainInnerBorrow() throws -> Int {
  let outerRegion = try PageRegion.allocate(byteCount: 4096)
  return try outerRegion.withBytes { outer in
    var saved = outer
    do {
      let innerRegion = try! PageRegion.allocate(byteCount: 4096)
      try! innerRegion.withBytes { inner in saved = inner }
    }
    return Int(saved[0])
  }
}
