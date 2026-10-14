import PageMemory
func check() throws {
  let value = try MappedValue.allocate { 73 }
  try value.withValue { $0[0] = 91 }
}
