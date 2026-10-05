// swift-tools-version: 6.0
import PackageDescription

let package = Package(
  name: "cordis-swift",
  platforms: [.macOS(.v15)],
  products: [
    .library(name: "Cordis", targets: ["Cordis"]),
    .library(name: "CordisValue", targets: ["CordisValue"]),
    .library(name: "CCordis", targets: ["CCordis"]),
    // The process that hosts an out-of-process plugin. Apps ship this executable (or their own
    // one-line main calling `cordisHelperMain`) next to theirs; see PluginHost.helperExecutable.
    .library(name: "CordisHelper", targets: ["CordisHelper"]),
    .executable(name: "cordis-plugin-helper", targets: ["cordis-plugin-helper"]),
    .executable(name: "cordis-bench", targets: ["cordis-bench"]),
  ],
  targets: [
    // Plugin ABI (C header). Shared by the host and by Embedded Swift plugins.
    .target(name: "CCordis"),
    // Value + binary codec. Foundation-free; also compiled into every plugin.
    .target(name: "CordisValue"),
    // Async-signal-safe crash attribution for the host.
    .target(name: "CCordisHost", dependencies: ["CCordis"]),
    // Framed messages between a host and an out-of-process plugin. Foundation-free.
    .target(name: "CordisWire", dependencies: ["CordisValue"]),
    // Out-of-process plugins: the helper's runtime (sandbox, footprint helpers in C).
    .target(name: "CCordisHelper"),
    .target(name: "CordisHelper", dependencies: ["CCordis", "CCordisHelper", "CordisValue", "CordisWire"]),
    .executableTarget(name: "cordis-plugin-helper", dependencies: ["CordisHelper"]),
    // Host runtime.
    .target(name: "Cordis", dependencies: ["CCordis", "CordisValue", "CCordisHost", "CCordisHelper", "CordisWire"]),
    // Plugin SDK. Real plugins compile these sources as Embedded Swift via Scripts/cordis-build;
    // this target only exists so the SDK is type-checked by `swift build`.
    .target(name: "CordisKit", dependencies: ["CCordis", "CordisValue"]),
    .executableTarget(name: "cordis-bench", dependencies: ["Cordis"]),
    .testTarget(name: "CordisValueTests", dependencies: ["CordisValue"]),
    .testTarget(
      name: "CordisTests", dependencies: ["Cordis", "cordis-bench", "cordis-plugin-helper"],
      exclude: ["Fixtures"]),
  ]
)
