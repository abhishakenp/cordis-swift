// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "cordis-swift",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "CordisValue", targets: ["CordisValue"]),
    .library(name: "CCordis", targets: ["CCordis"]),
  ],
  targets: [
    .target(name: "CCordis"),
    .target(name: "CordisValue"),
    .testTarget(name: "CordisValueTests", dependencies: ["CordisValue"]),
  ]
)
