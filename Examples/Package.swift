// swift-tools-version: 6.0
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
  name: "RilliyaKitExamples",
  platforms: [
    .macOS("14.2")
  ],
  products: [
    .executable(name: "MinimalGraph", targets: ["MinimalGraph"]),
    .executable(name: "CustomNode", targets: ["CustomNode"]),
    .executable(name: "ExecutableGraph", targets: ["ExecutableGraph"]),
    .executable(name: "LargeGraph", targets: ["LargeGraph"]),
  ],
  dependencies: [
    .package(name: "RilliyaKit", path: "..")
  ],
  targets: [
    .executableTarget(
      name: "MinimalGraph",
      dependencies: [.product(name: "RilliyaGraph", package: "RilliyaKit")]
    ),
    .executableTarget(
      name: "CustomNode",
      dependencies: [.product(name: "RilliyaGraph", package: "RilliyaKit")]
    ),
    .executableTarget(
      name: "ExecutableGraph",
      dependencies: [
        .product(name: "RilliyaEngine", package: "RilliyaKit"),
        .product(name: "RilliyaGraph", package: "RilliyaKit"),
        .product(name: "RilliyaRealtime", package: "RilliyaKit"),
      ]
    ),
    .executableTarget(
      name: "LargeGraph",
      dependencies: [.product(name: "RilliyaGraph", package: "RilliyaKit")]
    ),
  ],
  swiftLanguageModes: [.v6]
)
