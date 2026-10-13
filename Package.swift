// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "SwiftOSPrimitives",
  platforms: [.macOS("27.0"), .iOS(.v18)],
  products: [
    .library(name: "PageMemory", targets: ["PageMemory"]),
    .executable(name: "page-memory-probe", targets: ["PageMemoryProbe"]),
  ],
  targets: [
    .target(name: "PageMemory", swiftSettings: [.strictMemorySafety()]),
    .executableTarget(name: "PageMemoryProbe", dependencies: ["PageMemory"]),
    .testTarget(name: "PageMemoryTests", dependencies: ["PageMemory"]),
  ],
  swiftLanguageModes: [.v6])
