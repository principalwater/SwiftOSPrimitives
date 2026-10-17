import Foundation

// FDT v17 binary encoding, scoped to the isolated ARM64 machine.
struct DeviceTree {
  private var structure = Data()
  private var strings = Data()
  private var offsets: [String: UInt32] = [:]

  private static func word(_ value: UInt32) -> Data {
    var big = value.bigEndian
    return Data(bytes: &big, count: 4)
  }
  static func cells(_ values: UInt32...) -> Data {
    values.reduce(into: Data()) { $0.append(word($1)) }
  }
  static func string(_ value: String) -> Data { Data((value + "\0").utf8) }
  static func range(_ address: UInt64, _ size: UInt64) -> Data {
    cells(
      UInt32(address >> 32), UInt32(truncatingIfNeeded: address),
      UInt32(size >> 32), UInt32(truncatingIfNeeded: size))
  }
  mutating func begin(_ name: String) {
    structure.append(Self.word(1))
    structure.append(Self.string(name))
    align()
  }
  mutating func end() { structure.append(Self.word(2)) }
  mutating func property(_ name: String, _ value: Data) {
    let offset: UInt32
    if let found = offsets[name] {
      offset = found
    } else {
      offset = UInt32(strings.count)
      offsets[name] = offset
      strings.append(Self.string(name))
    }
    structure.append(Self.cells(3, UInt32(value.count), offset))
    structure.append(value)
    align()
  }
  private mutating func align() { while structure.count % 4 != 0 { structure.append(0) } }
  mutating func finish() -> Data {
    structure.append(Self.word(9))
    let total = 56 + structure.count + strings.count
    precondition(total < 65536)
    var result = Self.cells(
      0xd00d_feed, UInt32(total), 56, UInt32(56 + structure.count),
      40, 17, 16, 0, UInt32(strings.count), UInt32(structure.count))
    result.append(Data(count: 16))
    result.append(structure)
    result.append(strings)
    return result
  }

  static func linux(
    memoryBytes: UInt64, initrd: Range<UInt64>, command: String, memoryDevice: Bool = false,
    blockDevice: Bool = false, container: Bool = false, cpuCount: Int = 1, networkCount: Int = 0,
    freePageReporting: Bool = false
  ) -> Data {
    var tree = Self()
    tree.begin("")
    tree.property("#address-cells", cells(2))
    tree.property("#size-cells", cells(2))
    tree.property("compatible", string("linux,dummy-virt"))
    tree.property("model", string("SwiftOSPrimitives isolated Linux"))
    tree.property("interrupt-parent", cells(1))
    tree.begin("memory@40000000")
    tree.property("device_type", string("memory"))
    tree.property("reg", range(0x4000_0000, memoryBytes))
    tree.end()
    tree.begin("cpus")
    tree.property("#address-cells", cells(1))
    tree.property("#size-cells", cells(0))
    for index in 0..<cpuCount {
      tree.begin("cpu@\(index)")
      tree.property("device_type", string("cpu"))
      tree.property("compatible", string("arm,arm-v8"))
      tree.property("reg", cells(UInt32(index)))
      tree.property("enable-method", string("psci"))
      tree.end()
    }
    tree.end()
    tree.begin("psci")
    tree.property("compatible", string("arm,psci-0.2"))
    tree.property("method", string("hvc"))
    tree.end()
    tree.begin("intc@8000000")
    tree.property("compatible", string("arm,gic-v3"))
    tree.property("#interrupt-cells", cells(3))
    tree.property("interrupt-controller", Data())
    tree.property("phandle", cells(1))
    tree.property("#address-cells", cells(2))
    tree.property("#size-cells", cells(2))
    tree.property("ranges", Data())
    var registers = range(0x0800_0000, 0x10000)
    registers.append(range(0x080a_0000, 0x100000))
    tree.property("reg", registers)
    tree.end()
    tree.begin("timer")
    tree.property("compatible", string("arm,armv8-timer"))
    // Two entries select the physical EL1 timer; HVF's built-in GIC owns INTID30.
    tree.property("interrupts", cells(1, 13, 4, 1, 14, 4))
    tree.end()
    tree.begin("clock")
    tree.property("compatible", string("fixed-clock"))
    tree.property("#clock-cells", cells(0))
    tree.property("clock-frequency", cells(24_000_000))
    tree.property("phandle", cells(2))
    tree.end()
    tree.begin("pl011@9000000")
    tree.property("compatible", string("arm,pl011\0arm,primecell"))
    tree.property("reg", range(0x0900_0000, 0x1000))
    tree.property("interrupts", cells(0, 1, 4))
    tree.property("clocks", cells(2, 2))
    tree.property("clock-names", string("uartclk\0apb_pclk"))
    tree.end()
    if memoryDevice {
      tree.begin("virtio_mmio@a000000")
      tree.property("compatible", string("virtio,mmio"))
      tree.property("dma-coherent", Data())
      tree.property("reg", range(0x0a00_0000, 0x1000))
      tree.property("interrupts", cells(0, 3, 4))
      tree.end()
    }
    if blockDevice {
      tree.begin("virtio_mmio@a001000")
      tree.property("compatible", string("virtio,mmio"))
      tree.property("dma-coherent", Data())
      tree.property("reg", range(0x0a00_1000, 0x1000))
      tree.property("interrupts", cells(0, 4, 4))
      tree.end()
    }
    if container {
      for (offset, irq) in [(0x2000, 5), (0x3000, 6)] {
        tree.begin("virtio_mmio@\(String(0x0a00_0000 + offset, radix: 16))")
        tree.property("compatible", string("virtio,mmio"))
        tree.property("dma-coherent", Data())
        tree.property("reg", range(UInt64(0x0a00_0000 + offset), 0x1000))
        tree.property("interrupts", cells(0, UInt32(irq), 4))
        tree.end()
      }
    }
    for index in 0..<networkCount {
      let address = UInt64(0x0a00_4000 + index * 0x1000)
      tree.begin("virtio_mmio@\(String(address, radix: 16))")
      tree.property("compatible", string("virtio,mmio"))
      tree.property("dma-coherent", Data())
      tree.property("reg", range(address, 0x1000))
      tree.property("interrupts", cells(0, UInt32(7 + index), 4))
      tree.end()
    }
    if freePageReporting {
      tree.begin("virtio_mmio@a006000")
      tree.property("compatible", string("virtio,mmio"))
      tree.property("dma-coherent", Data())
      tree.property("reg", range(0x0a00_6000, 0x1000))
      tree.property("interrupts", cells(0, 9, 4))
      tree.end()
    }
    tree.begin("chosen")
    tree.property("stdout-path", string("/pl011@9000000"))
    tree.property("bootargs", string(command))
    tree.property("linux,initrd-start", range(initrd.lowerBound, 0).prefix(8))
    tree.property("linux,initrd-end", range(initrd.upperBound, 0).prefix(8))
    tree.end()
    tree.end()
    return tree.finish()
  }
}
