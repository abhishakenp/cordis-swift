import Cordis
import Foundation
import Testing

extension Fixtures {
  static var helperExecutable: String {
    Bundle(for: BundleMarker.self).bundleURL.deletingLastPathComponent().appendingPathComponent("cordis-plugin-helper").path
  }
}

@MainActor
func makeRemoteHost() -> (PluginHost, EventLog) {
  let (host, log) = makeHost()
  host.helperExecutable = Fixtures.helperExecutable
  return (host, log)
}

func processExists(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

/// Out-of-process plugins: same API and semantics, a helper process per plugin.
@MainActor
@Suite(.serialized)
struct RemoteTests {
  let sandboxed = PluginIsolation.process(sandbox: true)

  @Test func servicesEventsAndNestedCallsAcrossTheProcessBoundary() throws {
    let (host, log) = makeRemoteHost()
    // greeter in-process calls counter in a helper; the helper's events reach host and greeter.
    try host.load(Fixtures.path("greeter"))
    let info = try host.load(Fixtures.path("counter"), isolation: sandboxed)
    #expect(info.isolation == sandboxed)
    #expect(host.isolation(of: "counter") == sandboxed)
    #expect(host.isolation(of: "greeter") == .inProcess)
    #expect(host.isolation(of: "nobody") == nil)
    let pid = try #require(info.helperPID)
    #expect(pid != getpid() && processExists(pid))
    #expect(host.plugin("counter")?.state == .active)
    #expect(host.plugin("greeter")?.state == .active)

    var changed: [Value] = []
    var seen: [Value] = []
    host.on("counter/changed") { changed.append($0) }
    host.on("greeter/seen") { seen.append($0) }
    #expect(host.call("counter", "increment", 5) == 5)
    #expect(host.call("greeter", "greet", ["name": "Den"]) == "Hello, Den! (#6)")
    #expect(host.call("counter", "get") == 6)
    let payload: Value = ["s": "héllo 🌈", "n": nil, "list": [1, 2.5, true, .bytes([0, 255])]]
    #expect(host.call("counter", "echo", payload) == payload)
    #expect(host.call("counter", "nope")["error"].string == "counter: unknown method nope")
    #expect(changed == [5, 6])  // emitted by the helper before its reply
    #expect(seen == [5, 6])  // greeter (in-process) heard the helper's event
    #expect(log.logs.contains("counter: counter 1.0.0 ready"))

    // A plugin in a helper calling the host and then itself (host -> helper -> host -> helper).
    try host.load(Fixtures.path("crasher"), isolation: sandboxed)
    #expect(host.call("crasher", "call", ["service": "crasher", "method": "version"]) == "1.0.0")
    #expect(host.call("crasher", "call", ["service": "counter", "method": "get"]) == 6)

    let report = try host.unload("counter")
    #expect(report.unmapped)
    #expect(!processExists(pid))
    #expect(host.plugin("greeter")?.state == .pending(missing: ["counter"]))
    host.unloadAll()
  }

  @Test func hostEventsReachTheHelperAsynchronously() async throws {
    let (host, _) = makeRemoteHost()
    try host.load(Fixtures.path("greeter"), isolation: sandboxed)
    try host.load(Fixtures.path("counter"))
    var pongs: [Value] = []
    host.on("greeter/pong") { pongs.append($0) }
    host.emit("greeter/ping", ["tab": 7])
    #expect(await eventually { pongs == [["tab": 7]] })
    host.unloadAll()
  }

  @Test func timersAndHostServices() async throws {
    let (host, _) = makeRemoteHost()
    var stored: [String: Value] = [:]
    host.provide("storage") { method, args in
      if method == "set", let k = args["key"].string { stored[k] = args["value"] }
      return .null
    }
    try host.load(Fixtures.path("needy"), isolation: sandboxed)
    #expect(stored["needy"] == "applied")
    var fired: [Value] = []
    var ticks: [Value] = []
    host.on("needy/fired") { fired.append($0) }
    host.on("needy/tick") { ticks.append($0) }
    #expect(host.call("needy", "timer", 10) == true)
    #expect(await eventually { fired == ["once"] })
    _ = host.call("needy", "repeat")
    #expect(await eventually { ticks == [1, 2, 3] })
    host.emit("needy/poke", "hi")
    #expect(await eventually { stored["poked"] == "hi" })
    host.unloadAll()
  }

  @Test(arguments: ["segv", "trap", "overflow", "exit"])
  func aCrashingHelperIsUnloadedAndTheHostKeepsGoing(_ how: String) throws {
    let (host, _) = makeRemoteHost()
    var reports: [CrashReport] = []
    host.onCrash = { reports.append($0) }
    try host.load(Fixtures.path("dependent"))
    let pid = try #require(try host.load(Fixtures.path("crasher"), isolation: sandboxed).helperPID)
    #expect(host.plugin("dependent")?.state == .active)
    let r = host.call("dependent", how, 3)
    #expect(r["error"].string?.hasPrefix("plugin 'crasher' crashed") == true, "\(r)")
    #expect(reports.map(\.id) == ["crasher"])
    #expect(reports.first?.cascaded == ["dependent"])
    #expect(!processExists(pid))
    #expect(host.plugin("dependent")?.state == .pending(missing: ["crasher"]))
    // The same build comes back in a new helper.
    try host.load(Fixtures.path("crasher"), isolation: sandboxed)
    #expect(host.call("dependent", "version") == "1.0.0")
    host.unloadAll()
  }

  @Test func aHungHelperIsKilled() async throws {
    let (host, _) = makeRemoteHost()
    host.helperTimeout = 0.5
    var reports: [CrashReport] = []
    host.onCrash = { reports.append($0) }
    try host.load(Fixtures.path("crasher"), isolation: sandboxed)
    let t0 = Date()
    #expect(host.call("crasher", "spin")["error"].string?.contains("crashed (SIGKILL)") == true)
    #expect(Date().timeIntervalSince(t0) < 3)
    #expect(reports.first?.signal == SIGKILL)

    // A hang inside an event handler (the host doesn't wait) is caught by the same timeout.
    try host.load(Fixtures.path("crasher"), isolation: sandboxed)
    host.emit("crasher/boom", "spin")
    #expect(await eventually(timeout: 5) { reports.count == 2 })
    host.unloadAll()
  }

  @Test func theSandboxKeepsThePluginAwayFromFiles() throws {
    let (host, _) = makeRemoteHost()
    try host.load(Fixtures.path("crasher"), isolation: sandboxed)
    #expect(host.call("crasher", "touch") == -1)
    try host.unload("crasher")
    try host.load(Fixtures.path("crasher"), isolation: .process(sandbox: false))
    #expect((host.call("crasher", "touch").int ?? -1) >= 0)
    host.unloadAll()
  }

  @Test func hotReloadKeepsTheIsolation() async throws {
    let (host, log) = makeRemoteHost()
    let path = Fixtures.tempFile("libcounter-remote") + ".dylib"
    try Fixtures.install(Fixtures.path("counter"), to: path)
    host.watch(path, isolation: sandboxed)
    let pid = try #require(host.plugin("counter")?.helperPID)
    #expect(host.call("counter", "increment") == 1)
    try Fixtures.install(Fixtures.path("counter-v2"), to: path)
    #expect(await eventually { host.call("counter", "version") == "2.0.0" })
    let info = try #require(host.plugin("counter"))
    #expect(info.isolation == sandboxed)
    #expect(info.helperPID != pid && !processExists(pid))
    #expect(host.call("counter", "increment") == 10)
    #expect(log.events.contains { if case .reloaded = $0 { true } else { false } })
    host.unwatch(path)
    host.unloadAll()
  }

  @Test func aMissingHelperIsAnError() throws {
    let (host, _) = makeHost()
    host.helperExecutable = "/nonexistent/cordis-plugin-helper"
    #expect(throws: PluginHostError.self) { try host.load(Fixtures.path("counter"), isolation: sandboxed) }
    #expect(host.plugin("counter") == nil)
  }
}
