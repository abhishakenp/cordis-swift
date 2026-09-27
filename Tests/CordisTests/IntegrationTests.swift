import Cordis
import Foundation
import Testing

@MainActor
@Suite(.serialized)
struct IntegrationTests {
  @Test func callsServicesAcrossPlugins() throws {
    let (host, _) = makeHost()
    try host.load(Fixtures.path("greeter"))
    #expect(host.plugin("greeter")?.state == .pending(missing: ["counter"]))
    try host.load(Fixtures.path("counter"))
    #expect(host.plugin("counter")?.state == .active)
    #expect(host.plugin("greeter")?.state == .active)

    // host -> greeter -> counter (plugin to plugin through the host)
    #expect(host.call("greeter", "greet", ["name": "Den"]) == "Hello, Den! (#1)")
    #expect(host.call("greeter", "greet", [:]) == "Hello, world! (#2)")
    #expect(host.call("counter", "get") == 2)
    #expect(host.call("counter", "increment", 5) == 7)
    let payload: Value = ["s": "héllo 🌈", "n": nil, "list": [1, 2.5, true, .bytes([0, 255])]]
    #expect(host.call("counter", "echo", payload) == payload)

    // Errors come back as values.
    #expect(host.call("counter", "nope")["error"].string == "counter: unknown method nope")
    #expect(host.call("missing", "x")["error"].string == "service 'missing' is not available")
    #expect(Set(host.serviceNames) == ["counter", "greeter"])
    host.unloadAll()
  }

  @Test func deliversEventsBetweenHostAndPlugins() throws {
    let (host, log) = makeHost()
    try host.load(Fixtures.path("counter"))
    try host.load(Fixtures.path("greeter"))

    var pongs: [Value] = []
    var seen: [Value] = []
    var changed: [Value] = []
    host.on("greeter/pong") { pongs.append($0) }
    host.on("greeter/seen") { seen.append($0) }
    let h = host.on("counter/changed") { changed.append($0) }

    host.emit("greeter/ping", ["tab": 7])
    #expect(pongs == [["tab": 7]])

    _ = host.call("counter", "increment")  // counter emits counter/changed, greeter re-emits greeter/seen
    _ = host.call("counter", "increment", 2)
    #expect(changed == [1, 3])
    #expect(seen == [1, 3])

    host.dispose(h)
    _ = host.call("counter", "increment")
    #expect(changed == [1, 3])
    #expect(seen == [1, 3, 4])
    #expect(log.logs.contains("counter: counter 1.0.0 ready"))
    host.unloadAll()
  }

  @Test func hostServicesTimersAndMissingInject() async throws {
    let (host, _) = makeHost()
    try host.load(Fixtures.path("needy"))
    // "storage" does not exist yet: the plugin is loaded but not applied.
    #expect(host.plugin("needy")?.state == .pending(missing: ["storage"]))
    #expect(host.call("needy", "timer")["error"].string != nil)

    var store: [String: Value] = [:]
    let storage = host.provide("storage") { method, args in
      guard method == "set", let key = args["key"].string else { return ["error": "bad call"] }
      store[key] = args["value"]
      return true
    }
    #expect(host.plugin("needy")?.state == .active)
    #expect(store["needy"] == "applied")

    host.emit("needy/poke", 42)
    #expect(store["poked"] == 42)
    #expect(host.call("needy", "unlisten") == true)
    host.emit("needy/poke", 43)
    #expect(store["poked"] == 42)

    var fired: [Value] = []
    var ticks: [Value] = []
    host.on("needy/fired") { fired.append($0) }
    host.on("needy/tick") { ticks.append($0) }
    #expect(host.call("needy", "timer", 10) == true)
    #expect(host.call("needy", "repeat").int != nil)
    #expect(await eventually { fired.count == 1 && ticks.count == 3 })
    try await Task.sleep(for: .milliseconds(60))
    #expect(fired == ["once"])
    #expect(ticks == [1, 2, 3])  // the repeating timer disposed itself after 3 ticks

    // Removing the injected service disposes the plugin; it goes back to pending.
    host.dispose(storage)
    #expect(host.plugin("needy")?.state == .pending(missing: ["storage"]))
    #expect(host.call("needy", "timer")["error"].string != nil)
    host.provide("storage") { _, _ in true }
    #expect(host.plugin("needy")?.state == .active)
    host.unloadAll()
  }

  @Test func unloadingProviderCascadesAndReloadReapplies() throws {
    let (host, log) = makeHost()
    try host.load(Fixtures.path("counter"))
    try host.load(Fixtures.path("greeter"))
    #expect(host.call("greeter", "greet", ["name": "a"]) == "Hello, a! (#1)")

    let report = try host.unload("counter")
    #expect(report.cascaded == ["greeter"])
    #expect(report.unmapped)
    #expect(host.plugin("counter") == nil)
    #expect(host.plugin("greeter")?.state == .pending(missing: ["counter"]))
    #expect(host.serviceNames.isEmpty)
    #expect(host.call("greeter", "greet")["error"].string == "service 'greeter' is not available")
    #expect(log.events.contains { if case .disposed(id: "greeter") = $0 { true } else { false } })

    try host.load(Fixtures.path("counter"))
    #expect(host.plugin("greeter")?.state == .active)
    #expect(host.call("greeter", "greet", ["name": "b"]) == "Hello, b! (#1)")  // fresh counter state
    host.unloadAll()
  }

  @Test func hotReloadSwapsBehavior() async throws {
    let (host, log) = makeHost()
    let dir = Fixtures.tempFile("hot")
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = dir + "/libcounter.dylib"
    try Fixtures.install(Fixtures.path("counter"), to: path)

    host.watch(path)
    try host.load(Fixtures.path("greeter"))
    #expect(host.call("counter", "version") == "1.0.0")
    #expect(host.call("greeter", "greet", ["name": "v1"]) == "Hello, v1! (#1)")

    // A new build lands: the host unloads v1, loads v2 and re-applies the dependent.
    try Fixtures.install(Fixtures.path("counter-v2"), to: path)
    #expect(await eventually { host.call("counter", "version") == "2.0.0" })
    #expect(host.plugin("greeter")?.state == .active)
    #expect(host.call("greeter", "greet", ["name": "v2"]) == "Hello, v2! (#10)")
    let unloadReports = log.events.compactMap { if case let .unloaded(r) = $0 { r } else { nil } }
    #expect(unloadReports.last?.id == "counter")
    #expect(unloadReports.last?.unmapped == true)
    #expect(unloadReports.last?.cascaded == ["greeter"])

    // A broken build: the plugin stays disabled and the reason is reported.
    try Data("not a dylib".utf8).write(to: URL(fileURLWithPath: path + ".tmp"))
    _ = rename(path + ".tmp", path)
    #expect(await eventually { if case .disabled = host.plugin("counter")?.state { true } else { false } })
    guard case let .disabled(reason) = host.plugin("counter")?.state else { Issue.record("not disabled"); return }
    #expect(reason.contains("dlopen failed"))
    #expect(host.plugin("greeter")?.state == .pending(missing: ["counter"]))
    #expect(log.events.contains { if case .reloadFailed = $0 { true } else { false } })

    // Fixing the build recovers without restarting anything.
    try Fixtures.install(Fixtures.path("counter"), to: path)
    #expect(await eventually { host.plugin("counter")?.state == .active })
    #expect(host.call("counter", "version") == "1.0.0")
    #expect(host.plugin("greeter")?.state == .active)
    host.unwatch(path)
    host.unloadAll()
  }

  @Test func imagesAreUnmappedAfterUnload() throws {
    let (host, _) = makeHost()
    let baseline = Int(_dyld_image_count())
    for _ in 0..<25 {
      let info = try host.load(Fixtures.path("counter"))
      #expect(info.state == .active)
      #expect(Int(_dyld_image_count()) == baseline + 1)
      #expect(host.call("counter", "increment") == 1)
      let report = try host.unload("counter")
      #expect(report.unmapped)
      #expect(report.imageCountAfter == report.imageCountBefore - 1)
      #expect(Int(_dyld_image_count()) == baseline)
    }
  }

  @Test func failingApplyIsDisabledAndUnloaded() throws {
    let (host, log) = makeHost()
    let before = Int(_dyld_image_count())
    let info = try host.load(Fixtures.path("failer"))
    #expect(info.state == .disabled(reason: "cordis_plugin_apply returned 1"))
    #expect(host.serviceNames.isEmpty)  // what it registered before failing was dropped
    #expect(Int(_dyld_image_count()) == before)
    #expect(log.logs.contains("failer: failer: refusing on purpose"))
    #expect(log.events.contains { if case let .unloaded(r) = $0 { r.id == "failer" && r.unmapped } else { false } })
  }

  @Test func rejectsDuplicatesAndBadFiles() throws {
    let (host, _) = makeHost()
    try host.load(Fixtures.path("counter"))
    #expect(throws: PluginHostError.duplicate(id: "counter")) { try host.load(Fixtures.path("counter-v2")) }
    let junk = Fixtures.tempFile("junk.dylib")
    try Data("nope".utf8).write(to: URL(fileURLWithPath: junk))
    #expect(throws: PluginHostError.self) { try host.load(junk) }
    #expect(throws: PluginHostError.notLoaded(id: "ghost")) { try host.unload("ghost") }
    host.unloadAll()
  }

  @Test func crashIsAttributedAndBuildStaysDisabled() throws {
    for method in ["segv", "trap"] {
      let marker = Fixtures.tempFile("crash-\(method)")
      let (status, output) = Fixtures.run(
        Fixtures.benchExecutable, ["crash", Fixtures.path("crasher"), marker, "crasher", method])
      #expect(status > 128, "child should die from a signal, got \(status): \(output)")
      #expect(!output.contains("survived"))

      let (host, _) = makeHost(crashMarker: marker)
      let crash = try #require(host.lastCrash)
      #expect(crash.pluginID == "crasher")
      #expect(crash.signal == (method == "segv" ? SIGSEGV : SIGTRAP))

      // The same build is refused and reported as disabled.
      #expect(throws: PluginHostError.crashedBuild(id: "crasher", buildHash: crash.buildHash)) {
        try host.load(Fixtures.path("crasher"))
      }
      guard case .disabled = host.plugin("crasher")?.state else {
        Issue.record("crasher should be disabled")
        return
      }

      // A new build replaces it and clears the record.
      let info = try host.load(Fixtures.path("crasher-v2"))
      #expect(info.state == .active)
      #expect(host.call("crasher", "version") == "2.0.0")
      #expect(host.lastCrash == nil)
      #expect(!FileManager.default.fileExists(atPath: marker))
      host.unloadAll()
    }
  }

  @Test func crashMarkerIsUntouchedWhenHostCodeRuns() throws {
    let marker = Fixtures.tempFile("no-crash")
    let (host, _) = makeHost(crashMarker: marker)
    try host.load(Fixtures.path("crasher"))
    #expect(host.call("crasher", "version") == "1.0.0")
    #expect(!FileManager.default.fileExists(atPath: marker))
    #expect(host.lastCrash == nil)
    host.unloadAll()
  }
}
