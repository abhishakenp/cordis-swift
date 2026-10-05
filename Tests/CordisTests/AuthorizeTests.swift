import Cordis
import Foundation
import Testing

/// `PluginHost.authorize`: every call, listen, emit and provide a plugin makes is asked first.
@MainActor
@Suite(.serialized)
struct AuthorizeTests {
  @Test(arguments: [PluginIsolation.inProcess, .process(sandbox: true)])
  func refusedAccessIsDeniedEverywhere(_ isolation: PluginIsolation) throws {
    let (host, _) = makeRemoteHost()
    var asked: [String] = []
    host.authorize = { plugin, access in
      asked.append(plugin)
      switch access {
      case .call(service: "counter", method: "increment"): return false
      case .emit(event: "secret"): return false
      case .listen(event: "greeter/ping"): return false
      case .provide(service: "greeter"): return true
      default: return true
      }
    }
    try host.load(Fixtures.path("counter"))
    try host.load(Fixtures.path("crasher"), isolation: isolation)
    // crasher -> counter.increment: refused; counter.get: allowed.
    let r = host.call("crasher", "call", ["service": "counter", "method": "increment"])
    #expect(r["error"].string == "permission denied: crasher may not call counter.increment")
    #expect(host.call("crasher", "call", ["service": "counter", "method": "get"]) == 0)
    // An emit that is refused never reaches anyone; another one does.
    var heard: [String] = []
    host.on("secret") { _ in heard.append("secret") }
    host.on("public") { _ in heard.append("public") }
    _ = host.call("crasher", "emit", ["event": "secret"])
    _ = host.call("crasher", "emit", ["event": "public"])
    #expect(heard == ["public"])
    #expect(asked.contains("crasher"))
    // The host's own calls are never asked.
    asked.removeAll()
    #expect(host.call("counter", "increment") == 1)
    #expect(asked == ["counter"])  // counter emitting counter/changed; the call itself was not asked
    host.unloadAll()
  }

  @Test func refusedListenAndProvide() throws {
    let (host, log) = makeHost()
    host.authorize = { _, access in
      access != .listen(event: "crasher/boom") && access != .provide(service: "counter")
    }
    try host.load(Fixtures.path("crasher"))
    #expect(host.plugin("crasher")?.state == .active)
    #expect(!host.hasListeners("crasher/boom"))
    try host.load(Fixtures.path("counter"))
    #expect(!host.serviceNames.contains("counter"))
    #expect(log.logs.contains("counter: permission denied: may not provide counter"))
    host.unloadAll()
  }
}
