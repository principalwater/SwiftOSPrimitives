// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "VirtualizationBalloonLab",
  platforms: [.macOS("27.0")],
  dependencies: [.package(path: "../..")],
  targets: [
    .executableTarget(
      name: "vz-balloon-lab",
      dependencies: [.product(name: "PageMemory", package: "SwiftOSPrimitives")]),
    .executableTarget(
      name: "vz-balloon-guest",
      dependencies: [.product(name: "PageMemory", package: "SwiftOSPrimitives")],
      swiftSettings: [.enableExperimentalFeature("Volatile")]),
  ], swiftLanguageModes: [.v6])
