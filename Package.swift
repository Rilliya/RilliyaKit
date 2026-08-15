// swift-tools-version: 6.0
// SPDX-License-Identifier: Apache-2.0

import PackageDescription

let package = Package(
  name: "RilliyaKit",
  platforms: [
    .macOS("14.2")
  ],
  products: [
    .library(name: "RilliyaKit", targets: ["RilliyaKit"])
  ],
  dependencies: [
    .package(
      url: "https://github.com/apple/swift-atomics.git",
      .upToNextMajor(from: "1.3.1")
    )
  ],
  targets: [
    .target(
      name: "RilliyaKit",
      dependencies: [
        .product(name: "Atomics", package: "swift-atomics")
      ]
    ),
    .testTarget(name: "RilliyaKitTests", dependencies: ["RilliyaKit"]),
  ],
  swiftLanguageModes: [.v6]
)
