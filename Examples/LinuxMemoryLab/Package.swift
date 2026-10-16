// swift-tools-version: 6.4
import Foundation
import PackageDescription

guard
  let containerizationPath = ProcessInfo.processInfo.environment["SWIFTOS_CONTAINERIZATION_PATH"]
else {
  fatalError("Set an explicit path to the reviewed Containerization patch; see README")
}

let package = Package(
  name: "LinuxMemoryLab", platforms: [.macOS("27.0")],
  products: [.library(name: "NativeLinuxVMM", targets: ["NativeLinuxVMM"])],
  dependencies: [
    .package(path: "../.."),
    .package(name: "containerization", path: containerizationPath),
    .package(url: "https://github.com/apple/swift-nio.git", exact: "2.101.3"),
  ],
  targets: [
    .target(name: "MemoryCanary"),
    .executableTarget(name: "canary-pattern-bench", dependencies: [
      "MemoryCanary", .product(name: "PageMemory", package: "SwiftOSPrimitives")
    ]),
    .target(
      name: "NativeLinuxVMM",
      dependencies: [
        .product(name: "PageMemory", package: "SwiftOSPrimitives"),
        .product(name: "Containerization", package: "containerization"),
        .product(name: "ContainerizationExtras", package: "containerization"),
        .product(name: "NIOPosix", package: "swift-nio"),
      ]),
    .executableTarget(name: "linux-memory-lab", dependencies: ["NativeLinuxVMM"]),
    .executableTarget(name: "container-recovery-lab"),
    .executableTarget(name: "container-journal-lab", dependencies: [
      .product(name: "ContainerizationEXT4", package: "containerization")
    ]),
    .executableTarget(name: "container-native-lab", dependencies: [
      "NativeLinuxVMM", .product(name: "BoundedMemory", package: "SwiftOSPrimitives")
    ]),
    .executableTarget(
      name: "container-memory-probe",
      dependencies: [
        "NativeLinux", "MemoryCanary",
        .product(name: "PageMemory", package: "SwiftOSPrimitives")
      ]),
    .systemLibrary(name: "NativeLinux"),
    .executableTarget(
      name: "linux-memory-guest",
      dependencies: [
        "NativeLinux",
        .product(name: "PageMemory", package: "SwiftOSPrimitives"),
      ]),
    .testTarget(name: "LinuxMemoryLabTests", dependencies: ["NativeLinuxVMM", "container-native-lab", "MemoryCanary"]),
  ], swiftLanguageModes: [.v6])
