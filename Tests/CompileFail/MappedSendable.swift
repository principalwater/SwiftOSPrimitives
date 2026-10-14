import PageMemory
func requireSendable<Value: Sendable & ~Copyable>(_ value: borrowing Value) {}
func check() throws {
  let value = try MappedValue.allocate { 73 }
  requireSendable(value)
}
