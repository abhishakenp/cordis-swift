// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "cordis-swift",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "Cordis", targets: ["Cordis"]),
    .library(name: "CordisValue", targets: ["CordisValue"]),
    .library(name: "CCordis", targets: ["CCordis"]),
    .executable(name: "cordis-bench", targets: ["cordis-bench"]),
  ],
  targets: [
    // Plugin ABI (C header). Shared by the host and by Embedded Swift plugins.
    .target(name: "CCordis"),
    // Value + binary codec. Foundation-free; also compiled into every plugin.
    .target(name: "CordisValue"),
    // Async-signal-safe crash attribution for the host.
    .target(name: "CCordisHost", dependencies: ["CCordis"]),
    // Host runtime.
    .target(name: "Cordis", dependencies: ["CCordis", "CordisValue", "CCordisHost"]),
    // Plugin SDK. Real plugins compile these sources as Embedded Swift via Scripts/cordis-build;
    // this target only exists so the SDK is type-checked by `swift build`.
    .target(name: "CordisKit", dependencies: ["CCordis", "CordisValue"]),
    .executableTarget(name: "cordis-bench", dependencies: ["Cordis"]),
    .testTarget(name: "CordisValueTests", dependencies: ["CordisValue"]),
    .testTarget(
      name: "CordisTests", dependencies: ["Cordis", "cordis-bench"],
      exclude: ["Fixtures"]),
  ]
)
