import Cordis
import Foundation

/// Builds the example and fixture plugins once per test process, in parallel, with the real
/// `Scripts/cordis-build`.
enum Fixtures {
  static let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
    .deletingLastPathComponent()
  static let workDir: URL = {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("cordis-tests-\(getpid())")
    try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
  }()
  static let cacheDir = workDir.appendingPathComponent("image-cache").path

  struct Spec: Sendable {
    let name: String
    let id: String
    let source: String
    let defines: [String]
  }

  static let specs: [Spec] = [
    Spec(name: "counter", id: "counter", source: "Examples/Counter/Counter.swift", defines: []),
    Spec(name: "counter-v2", id: "counter", source: "Examples/Counter/Counter.swift", defines: ["COUNTER_V2"]),
    Spec(name: "greeter", id: "greeter", source: "Examples/Greeter/Greeter.swift", defines: []),
    Spec(name: "needy", id: "needy", source: "Tests/CordisTests/Fixtures/Needy.swift", defines: []),
    Spec(name: "watcher", id: "watcher", source: "Tests/CordisTests/Fixtures/Watcher.swift", defines: []),
    Spec(name: "failer", id: "failer", source: "Tests/CordisTests/Fixtures/Failer.swift", defines: []),
    Spec(name: "crasher", id: "crasher", source: "Tests/CordisTests/Fixtures/Crasher.swift", defines: []),
    Spec(name: "crasher-v2", id: "crasher", source: "Tests/CordisTests/Fixtures/Crasher.swift", defines: ["CRASHER_V2"]),
    Spec(name: "crasher-apply", id: "crasher", source: "Tests/CordisTests/Fixtures/Crasher.swift", defines: ["CRASH_IN_APPLY"]),
    Spec(name: "dependent", id: "dependent", source: "Tests/CordisTests/Fixtures/Dependent.swift", defines: []),
  ]

  /// name -> dylib path
  static let built: [String: String] = {
    let results = UnsafeMutableBufferPointer<String?>.allocate(capacity: specs.count)
    results.initialize(repeating: nil)
    defer { results.deallocate() }
    nonisolated(unsafe) let base = results.baseAddress!
    DispatchQueue.concurrentPerform(iterations: specs.count) { i in
      let spec = specs[i]
      let out = workDir.appendingPathComponent("lib\(spec.name).dylib").path
      var args = ["--id", spec.id, "--out", out]
      for d in spec.defines { args += ["-D", d] }
      args.append(root.appendingPathComponent(spec.source).path)
      let (status, output) = run(root.appendingPathComponent("Scripts/cordis-build").path, args)
      precondition(status == 0, "cordis-build failed for \(spec.name):\n\(output)")
      (base + i).pointee = out
    }
    var map: [String: String] = [:]
    for (i, spec) in specs.enumerated() { map[spec.name] = results[i] }
    return map
  }()

  static func path(_ name: String) -> String { built[name]! }

  /// Runs a program and returns (exit status or 128+signal, combined output).
  @discardableResult
  static func run(_ exe: String, _ args: [String]) -> (Int32, String) {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: exe)
    p.arguments = args
    let pipe = Pipe()
    p.standardOutput = pipe
    p.standardError = pipe
    try! p.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    let status = p.terminationReason == .uncaughtSignal ? 128 + p.terminationStatus : p.terminationStatus
    return (status, String(decoding: data, as: UTF8.self))
  }

  static func tempFile(_ name: String) -> String {
    workDir.appendingPathComponent("\(name)-\(UUID().uuidString)").path
  }

  /// Copies `from` over `to` atomically, as a build tool would.
  static func install(_ from: String, to: String) throws {
    let tmp = to + ".tmp"
    try? FileManager.default.removeItem(atPath: tmp)
    try FileManager.default.copyItem(atPath: from, toPath: tmp)
    _ = rename(tmp, to)
  }
}

final class BundleMarker {}

extension Fixtures {
  /// The cordis-bench executable built next to the test bundle.
  static var benchExecutable: String {
    Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("cordis-bench").path
  }
}

@MainActor
func makeHost(crashMarker: String? = nil) -> (PluginHost, EventLog) {
  let host = PluginHost(crashMarkerPath: crashMarker, cacheDirectory: Fixtures.cacheDir)
  let log = EventLog()
  host.onEvent = { log.events.append($0) }
  return (host, log)
}

@MainActor
final class EventLog {
  var events: [HostEvent] = []
  var logs: [String] {
    events.compactMap { if case let .log(id, _, msg) = $0 { "\(id): \(msg)" } else { nil } }
  }
}

/// Polls the main actor until `condition` holds or the timeout expires.
@MainActor
func eventually(timeout: Double = 10, _ condition: () -> Bool) async -> Bool {
  let deadline = Date().addingTimeInterval(timeout)
  while Date() < deadline {
    if condition() { return true }
    try? await Task.sleep(for: .milliseconds(20))
  }
  return condition()
}
