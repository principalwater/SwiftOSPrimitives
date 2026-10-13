import PageMemory

func copyOwner() throws {
  let region = try PageRegion.allocate(byteCount: 4096)
  let first = consume region
  let second = consume region
  _ = (first.byteCount, second.byteCount)
}
