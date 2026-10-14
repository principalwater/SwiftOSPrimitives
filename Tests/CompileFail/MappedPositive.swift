import PageMemory
struct Token: ~Copyable { let number: Int }
func check() throws {
  var value = try MappedValue.allocate { Token(number: 73) }
  _ = try value.withValue { $0[0].number }
  try value.release()
}
