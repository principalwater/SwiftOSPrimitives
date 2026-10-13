import PageMemory

func escape(_ region: borrowing PageRegion) throws -> () -> Int {
  try region.withBytes { bytes in
    { bytes.count }
  }
}
