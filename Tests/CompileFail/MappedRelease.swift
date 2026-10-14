import PageMemory
func check() throws {
  var value = try MappedValue.allocate { 73 }
  _ = try value.withValue { loan in
    try? value.release()
    return loan[0]
  }
}
