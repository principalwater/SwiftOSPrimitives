// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "BalloonHostLab", platforms: [.macOS("27.0")],
  dependencies: [.package(path: "../..")],
  targets: [
    .target(name: "HostLab"),
    .executableTarget(
      name: "balloon-host-lab",
      dependencies: ["HostLab", .product(name: "BoundedMemory", package: "SwiftOSPrimitives")]),
    .testTarget(name: "HostLabTests", dependencies: ["HostLab"]),
  ], swiftLanguageModes: [.v6])
