// swift-tools-version: 6.0
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
  name: "RilliyaKit",
  platforms: [
    .macOS("14.2")
  ],
  products: [
    .library(
      name: "RilliyaKit",
      targets: [
        "RilliyaCore",
        "RilliyaRealtime",
        "RilliyaDiscovery",
        "RilliyaCapture",
        "RilliyaDSP",
        "RilliyaPlayback",
      ]
    ),
    .library(name: "RilliyaCore", targets: ["RilliyaCore"]),
    .library(name: "RilliyaRealtime", targets: ["RilliyaRealtime"]),
    .library(name: "RilliyaDiscovery", targets: ["RilliyaDiscovery"]),
    .library(name: "RilliyaCapture", targets: ["RilliyaCapture"]),
    .library(name: "RilliyaDSP", targets: ["RilliyaDSP"]),
    .library(name: "RilliyaPlayback", targets: ["RilliyaPlayback"]),
  ],
  dependencies: [
    .package(
      url: "https://github.com/apple/swift-atomics.git",
      .upToNextMajor(from: "1.3.1")
    )
  ],
  targets: [
    .target(
      name: "RilliyaRealtime",
      dependencies: [
        .product(name: "Atomics", package: "swift-atomics")
      ]
    ),
    .target(name: "RilliyaCore"),
    .target(name: "RilliyaDiscovery", dependencies: ["RilliyaCore"]),
    .target(
      name: "RilliyaCapture",
      dependencies: ["RilliyaCore", "RilliyaRealtime"]
    ),
    .target(
      name: "RilliyaDSP",
      dependencies: [
        "RilliyaRealtime",
        .product(name: "Atomics", package: "swift-atomics"),
      ]
    ),
    .target(
      name: "RilliyaPlayback",
      dependencies: ["RilliyaCore", "RilliyaRealtime"]
    ),
    .testTarget(
      name: "RilliyaKitTests",
      dependencies: [
        "RilliyaCore",
        "RilliyaRealtime",
        "RilliyaDiscovery",
        "RilliyaCapture",
        "RilliyaDSP",
        "RilliyaPlayback",
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
