// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "SwiftOSPrimitives",
  platforms: [.macOS("27.0"), .iOS(.v18)],
  products: [
    .library(name: "PageMemory", targets: ["PageMemory"]),
    .library(name: "BoundedMemory", targets: ["BoundedMemory"]),
    .executable(name: "page-memory-probe", targets: ["PageMemoryProbe"]),
  ],
  targets: [
    .target(
      name: "BoundedMemory",
      swiftSettings: [.strictMemorySafety(), .enableExperimentalFeature("Lifetimes")]),
    .target(name: "PageMemory", swiftSettings: [.strictMemorySafety()]),
    .executableTarget(name: "PageMemoryProbe", dependencies: ["PageMemory"]),
    .testTarget(
      name: "BoundedMemoryTests", dependencies: ["BoundedMemory", "PageMemory"],
      swiftSettings: [.strictMemorySafety(), .enableExperimentalFeature("Lifetimes")]),
    .testTarget(
      name: "PageMemoryTests", dependencies: ["PageMemory"],
      swiftSettings: [.strictMemorySafety()]),
  ],
  swiftLanguageModes: [.v6])
