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
  targets: [
    .target(name: "RilliyaKit"),
    .testTarget(name: "RilliyaKitTests", dependencies: ["RilliyaKit"]),
  ],
  swiftLanguageModes: [.v6]
)
