// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "LinuxMemoryLab", platforms: [.macOS("27.0")],
  dependencies: [.package(path: "../..")],
  targets: [
    .executableTarget(
      name: "linux-memory-lab",
      dependencies: [.product(name: "PageMemory", package: "SwiftOSPrimitives")]),
    .systemLibrary(name: "NativeLinux"),
    .executableTarget(
      name: "linux-memory-guest",
      dependencies: [
        "NativeLinux",
        .product(name: "PageMemory", package: "SwiftOSPrimitives"),
      ]),
    .testTarget(name: "LinuxMemoryLabTests", dependencies: ["linux-memory-lab"]),
  ], swiftLanguageModes: [.v6])
