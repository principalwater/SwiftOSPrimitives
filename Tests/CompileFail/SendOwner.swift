import PageMemory

func requireSendable<Value: Sendable & ~Copyable>(_ value: borrowing Value) {}
func sendOwner() throws {
  let region = try PageRegion.allocate(byteCount: 4096)
  requireSendable(region)
}
