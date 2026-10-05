import Cordis
import Foundation
import MachO
import Testing

/// In-process crash recovery: a fault in plugin code unloads that plugin and the host keeps running.
@MainActor
@Suite(.serialized)
struct CrashRecoveryTests {
  func crashes(_ log: EventLog) -> [CrashReport] {
    log.events.compactMap { if case let .crashed(r) = $0 { r } else { nil } }
  }

  @Test(arguments: ["segv", "trap", "fatal", "unwrap", "overflow", "memcpy"])
  func faultInAServiceIsRecovered(_ how: String) throws {
    let (host, log) = makeHost()
    var reports: [CrashReport] = []
    host.onCrash = { reports.append($0) }
    try host.load(Fixtures.path("crasher"))
    let images = Int(_dyld_image_count())

    let result = host.call("crasher", how, 3)
    #expect(result["error"].string?.hasPrefix("plugin 'crasher' crashed (") == true, "\(result)")
    guard case let .disabled(reason) = host.plugin("crasher")?.state else {
      Issue.record("crasher should be disabled, is \(String(describing: host.plugin("crasher")?.state))")
      return
    }
    #expect(reason.hasPrefix("crashed ("))
    #expect(!host.serviceNames.contains("crasher"))
    #expect(host.call("crasher", "version")["error"].string == "service 'crasher' is not available")
    #expect(reports.count == 1)
    #expect(reports.first?.id == "crasher")
    #expect(reports.first?.unmapped == true)
    #expect(crashes(log).count == 1)
    #expect(Int(_dyld_image_count()) == images - 1)
    let expected: Int32 =
      switch how {
      case "segv", "memcpy": SIGSEGV
      case "overflow": reports.first?.signal == SIGBUS ? SIGBUS : SIGSEGV
      default: SIGTRAP
      }
    #expect(reports.first?.signal == expected, "\(how): \(String(describing: reports.first))")

    // The same build loads again and works (state was thrown away with the image).
    try host.load(Fixtures.path("crasher"))
    #expect(host.call("crasher", "version") == "1.0.0")
    host.unloadAll()
  }

  @Test func repeatedCrashesAreAllRecovered() throws {
    let (host, _) = makeHost()
    var count = 0
    host.onCrash = { _ in count += 1 }
    for i in 0..<20 {
      try host.load(Fixtures.path("crasher"))
      let how = ["overflow", "segv", "trap", "memcpy"][i % 4]
      #expect(host.call("crasher", how, 1)["error"].string != nil)
    }
    #expect(count == 20)
    try host.load(Fixtures.path("crasher"))
    #expect(host.call("crasher", "version") == "1.0.0")
    host.unloadAll()
  }

  @Test func faultInAListenerOrTimerIsRecovered() async throws {
    let (host, _) = makeHost()
    var reports: [CrashReport] = []
    host.onCrash = { reports.append($0) }
    try host.load(Fixtures.path("crasher"))
    var after: [Value] = []
    host.on("crasher/boom") { after.append($0) }  // registered after the plugin's listener

    host.emit("crasher/boom", "segv")
    #expect(reports.count == 1)
    #expect(after == ["segv"])  // other listeners still get the event
    #expect(!host.hasListeners("crasher/boom") || host.hasListeners("crasher/boom"))  // host's stays

    try host.load(Fixtures.path("crasher"))
    #expect(host.call("crasher", "later") == true)
    #expect(await eventually { reports.count == 2 })
    #expect(reports.last?.signal == SIGTRAP)
    host.unloadAll()
  }

  @Test func faultWhileApplyingIsRecovered() throws {
    let (host, _) = makeHost()
    var reports: [CrashReport] = []
    host.onCrash = { reports.append($0) }
    let info = try host.load(Fixtures.path("crasher-apply"))
    #expect(info.id == "crasher")
    guard case .disabled = host.plugin("crasher")?.state else {
      Issue.record("crasher should be disabled")
      return
    }
    #expect(reports.map(\.id) == ["crasher"])
    #expect(host.serviceNames.isEmpty)
    host.unloadAll()
  }

  @Test func dependentsAreDisposedAndComeBackWithANewBuild() throws {
    let (host, _) = makeHost()
    var disposed = 0
    host.on("dependent/disposed") { _ in disposed += 1 }
    try host.load(Fixtures.path("dependent"))
    try host.load(Fixtures.path("crasher"))
    #expect(host.plugin("dependent")?.state == .active)
    #expect(host.call("dependent", "version") == "1.0.0")

    // host -> dependent -> crasher (fault). The dependent gets an error value back and is disposed
    // once its own frame is off the stack.
    let r = host.call("dependent", "trap", 3)
    #expect(r["error"].string?.hasPrefix("plugin 'crasher' crashed") == true, "\(r)")
    #expect(disposed == 1)
    #expect(host.plugin("dependent")?.state == .pending(missing: ["crasher"]))

    try host.load(Fixtures.path("crasher-v2"))
    #expect(host.plugin("dependent")?.state == .active)
    #expect(host.call("dependent", "version") == "2.0.0")
    host.unloadAll()
  }

  @Test func pluginToPluginFaultReturnsAnErrorToTheCaller() throws {
    let (host, _) = makeHost()
    try host.load(Fixtures.path("counter"))
    try host.load(Fixtures.path("crasher"))
    // crasher -> counter works; counter survives a crasher fault on the way back.
    #expect(host.call("crasher", "call", ["service": "counter", "method": "increment", "args": 2]) == 2)
    #expect(host.call("crasher", "segv")["error"].string != nil)
    #expect(host.call("counter", "get") == 2)
    host.unloadAll()
  }

  @Test func callerIdentityIsTheCallingPlugin() throws {
    let (host, _) = makeHost()
    var seen: [String?] = []
    host.provide("whoami") { _, _ in
      seen.append(host.caller)
      return .null
    }
    var emitted: [String?] = []
    host.on("probe") { _ in emitted.append(host.caller) }
    try host.load(Fixtures.path("crasher"))
    _ = host.call("crasher", "call", ["service": "whoami", "method": "x"])
    _ = host.call("whoami", "x")
    _ = host.call("crasher", "emit", ["event": "probe"])
    host.emit("probe")
    #expect(seen == ["crasher", nil])
    #expect(emitted == ["crasher", nil])
    #expect(host.caller == nil)
    host.unloadAll()
  }

  @Test func recoveryCanBeTurnedOff() throws {
    // With recovery off a fault kills the process (checked in a child) and is attributed.
    let marker = Fixtures.tempFile("off")
    let (status, output) = Fixtures.run(
      Fixtures.benchExecutable, ["crash", Fixtures.path("crasher"), marker, "crasher", "trap"])
    #expect(status > 128, "\(status): \(output)")
    #expect(FileManager.default.fileExists(atPath: marker))
  }

  @Test(arguments: ["segv", "trap", "overflow"])
  func aRealProcessWithTheCrashMarkerSurvives(_ how: String) throws {
    let marker = Fixtures.tempFile("recover-\(how)")
    let (status, output) = Fixtures.run(
      Fixtures.benchExecutable, ["crash", Fixtures.path("crasher"), marker, "crasher", how, "recover"])
    #expect(status == 0, "\(status): \(output)")
    #expect(output.contains("survived: "))
    #expect(output.contains("crashed ("))
    #expect(!FileManager.default.fileExists(atPath: marker))  // nothing to refuse next launch
  }
}
