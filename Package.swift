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
        "RilliyaFilePlayback",
        "RilliyaFileWriting",
        "RilliyaNetworkAudio",
        "RilliyaPlayback",
        "RilliyaVirtualAudio",
        "RilliyaGraph",
        "RilliyaEngine",
        "RilliyaCaptureNodes",
      ]
    ),
    .library(name: "RilliyaCore", targets: ["RilliyaCore"]),
    .library(name: "RilliyaRealtime", targets: ["RilliyaRealtime"]),
    .library(name: "RilliyaDiscovery", targets: ["RilliyaDiscovery"]),
    .library(name: "RilliyaCapture", targets: ["RilliyaCapture"]),
    .library(name: "RilliyaDSP", targets: ["RilliyaDSP"]),
    .library(name: "RilliyaFilePlayback", targets: ["RilliyaFilePlayback"]),
    .library(name: "RilliyaFileWriting", targets: ["RilliyaFileWriting"]),
    .library(name: "RilliyaNetworkAudio", targets: ["RilliyaNetworkAudio"]),
    .library(name: "RilliyaPlayback", targets: ["RilliyaPlayback"]),
    .library(name: "RilliyaVirtualAudio", targets: ["RilliyaVirtualAudio"]),
    .library(name: "RilliyaGraph", targets: ["RilliyaGraph"]),
    .library(name: "RilliyaEngine", targets: ["RilliyaEngine"]),
    .library(name: "RilliyaCaptureNodes", targets: ["RilliyaCaptureNodes"]),
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
    .target(name: "RilliyaVirtualAudio"),
    .target(
      name: "RilliyaFilePlayback",
      dependencies: ["RilliyaRealtime"]
    ),
    .target(
      name: "RilliyaFileWriting",
      dependencies: ["RilliyaRealtime"]
    ),
    .target(
      name: "RilliyaNetworkAudio",
      dependencies: ["RilliyaRealtime"]
    ),
    .target(name: "RilliyaGraph"),
    .target(
      name: "RilliyaEngine",
      dependencies: ["RilliyaGraph", "RilliyaRealtime"]
    ),
    .target(
      name: "RilliyaCaptureNodes",
      dependencies: [
        "RilliyaCore",
        "RilliyaCapture",
        "RilliyaEngine",
        "RilliyaGraph",
        "RilliyaRealtime",
      ]
    ),
    .testTarget(
      name: "RilliyaKitTests",
      dependencies: [
        "RilliyaCore",
        "RilliyaRealtime",
        "RilliyaDiscovery",
        "RilliyaCapture",
        "RilliyaDSP",
        "RilliyaFilePlayback",
        "RilliyaFileWriting",
        "RilliyaNetworkAudio",
        "RilliyaPlayback",
        "RilliyaVirtualAudio",
      ]
    ),
    .testTarget(name: "RilliyaGraphTests", dependencies: ["RilliyaGraph"]),
    .testTarget(
      name: "RilliyaEngineTests",
      dependencies: ["RilliyaEngine", "RilliyaGraph", "RilliyaRealtime"]
    ),
    .testTarget(
      name: "RilliyaCaptureNodesTests",
      dependencies: [
        "RilliyaCaptureNodes",
        "RilliyaCapture",
        "RilliyaCore",
        "RilliyaEngine",
        "RilliyaGraph",
        "RilliyaRealtime",
      ]
    ),
  ],
  swiftLanguageModes: [.v6]
)
