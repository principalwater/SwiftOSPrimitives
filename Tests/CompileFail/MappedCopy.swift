import PageMemory
func check() throws {
  let value = try MappedValue.allocate { 73 }
  let other = copy value
  _ = other.isDestroyed
}
