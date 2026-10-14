// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "MemoryContracts",
  platforms: [.macOS("27.0")],
  dependencies: [.package(path: "../..")],
  targets: [
    .systemLibrary(name: "MemoryFaultABI", path: "MemoryFaultABI"),
    .executableTarget(
      name: "memory-faults",
      dependencies: [
        .product(name: "PageMemory", package: "SwiftOSPrimitives"),
        .target(name: "MemoryFaultABI", condition: .when(platforms: [.linux])),
      ],
      swiftSettings: [.strictMemorySafety()],
      linkerSettings: [
        .unsafeFlags(
          ["-Xlinker", "--wrap=mmap", "-Xlinker", "--wrap=munmap"],
          .when(platforms: [.linux])),
      ]),
    .executableTarget(
      name: "memory-contracts",
      dependencies: [
        .product(name: "PageMemory", package: "SwiftOSPrimitives"),
        .product(name: "BoundedMemory", package: "SwiftOSPrimitives"),
      ],
      swiftSettings: [.strictMemorySafety(), .enableExperimentalFeature("Lifetimes")]),
  ],
  swiftLanguageModes: [.v6])
