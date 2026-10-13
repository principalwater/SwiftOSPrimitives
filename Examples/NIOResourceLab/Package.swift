// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "NIOResourceLab", platforms: [.macOS("27.0")],
  dependencies: [
    .package(url: "https://github.com/apple/swift-nio.git", exact: "2.103.0"),
    .package(path: "../.."),
  ],
  targets: [
    .executableTarget(
      name: "NIOResourceLab",
      dependencies: [
        .product(name: "NIOCore", package: "swift-nio"),
        .product(name: "NIOPosix", package: "swift-nio"),
        .product(name: "PageMemory", package: "SwiftOSPrimitives"),
      ])
  ], swiftLanguageModes: [.v6])
