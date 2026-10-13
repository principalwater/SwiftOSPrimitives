import PageMemory

func legalBorrows() throws -> Int {
  var first = try PageRegion.allocate(byteCount: 4096)
  let second = try PageRegion.allocate(byteCount: 4096)
  try first.withMutableBytes { bytes in bytes[0] = 42 }
  let result = try first.withBytes { outer in
    let value = try! second.withBytes { inner in Int(outer[0]) + Int(inner[0]) }
    return value
  }
  try first.release()
  return result
}
