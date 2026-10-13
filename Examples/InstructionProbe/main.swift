#if arch(arm64) && canImport(Darwin)
  @used
  @section("__TEXT,__text")
  nonisolated(unsafe) var addInstructions: (UInt32, UInt32) = (0x8b01_0000, 0xd65f_03c0)

  @unsafe func instructionAdd(_ left: UInt64, _ right: UInt64) -> UInt64 {
    typealias Operation = @convention(c) (UInt64, UInt64) -> UInt64
    let operation = unsafe withUnsafePointer(to: &addInstructions) {
      unsafe unsafeBitCast($0, to: Operation.self)
    }
    return operation(left, right)
  }

  @main struct InstructionProbe {
    static func main() {
      precondition(unsafe instructionAdd(10, 32) == 42)
      precondition(unsafe instructionAdd(UInt64.max, 1) == 0)
      precondition(unsafe instructionAdd(0, 0) == 0)
      precondition(unsafe instructionAdd(1 << 63, 1 << 63) == 0)
    }
  }
#else
  #error("This experiment supports only Mach-O arm64.")
#endif
