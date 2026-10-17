// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "HypervisorMemoryLab",
  platforms: [.macOS("27.0")],
  dependencies: [.package(name: "SwiftOSPrimitives", path: "../..")],
  targets: [
    .executableTarget(
      name: "hvf-memory-lab",
      dependencies: [.product(name: "PageMemory", package: "SwiftOSPrimitives")])
  ], swiftLanguageModes: [.v6])
