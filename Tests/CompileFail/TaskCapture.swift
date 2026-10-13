import PageMemory

func taskCapture(_ region: borrowing PageRegion) throws {
  try region.withBytes { bytes in
    _ = Task { bytes.count }
  }
}
