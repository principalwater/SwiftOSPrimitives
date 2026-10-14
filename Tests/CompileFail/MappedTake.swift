import PageMemory
struct Token: ~Copyable { let number: Int }
func check() throws {
  let value = try MappedValue.allocate { Token(number: 73) }
  let taken = try value.withValue { consume $0[0] }
  _ = taken.number
}
