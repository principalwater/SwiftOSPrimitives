// Compile-only negative control: the no-allocation gate must reject this array owner.
@c(allocating_control)
public func allocatingControl(_ count: Int) -> Int {
  let bytes = [UInt8](repeating: 73, count: count)
  return bytes.count > 0 ? Int(bytes[0]) : 0
}
