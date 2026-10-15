// swift-tools-version: 6.4
import PackageDescription

let package = Package(
  name: "AppleContainerMemoryLab",
  platforms: [.macOS("27.0")],
  products: [.library(name: "AppleContainerMemory", targets: ["AppleContainerMemory"])],
  dependencies: [
    .package(path: "../.."),
    .package(
      url: "https://github.com/apple/containerization.git",
      revision: "bc994b88df46207fad7775b0eabc51947e315881"),
    .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.3"),
  ],
  targets: [
    .target(
      name: "AppleContainerMemory",
      dependencies: [
        .product(name: "Containerization", package: "containerization"),
        .product(name: "ContainerizationExtras", package: "containerization"),
      ]),
    .executableTarget(
      name: "container-memory-lab",
      dependencies: [
        "AppleContainerMemory",
        .product(name: "BoundedMemory", package: "SwiftOSPrimitives"),
        .product(name: "PageMemory", package: "SwiftOSPrimitives"),
        .product(name: "Containerization", package: "containerization"),
        .product(name: "ContainerizationExtras", package: "containerization"),
        .product(name: "NIOPosix", package: "swift-nio"),
      ]),
    .testTarget(
      name: "AppleContainerMemoryTests",
      dependencies: [
        "AppleContainerMemory", "container-memory-lab",
        .product(name: "ContainerizationExtras", package: "containerization"),
      ]),
  ],
  swiftLanguageModes: [.v6])
