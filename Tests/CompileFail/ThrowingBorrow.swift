import PageMemory

enum PayloadFailure: Error { case rejected }

func escapeThrowing(_ region: borrowing PageRegion) throws -> () -> Int {
  try region.withReadAccess { (bytes: Span<UInt8>) throws(PayloadFailure) -> () -> Int in
    { bytes.count }
  }
}
