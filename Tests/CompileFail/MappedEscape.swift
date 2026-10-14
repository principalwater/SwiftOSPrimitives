import PageMemory
func check() throws {
  let value = try MappedValue.allocate { 73 }
  let saved: Span<Int> = try value.withValue { return $0 }
  _ = saved.count
}
