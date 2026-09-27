// Fixture: a second consumer of "counter" that calls it while applying. Unloading counter must
// never re-apply it (or greeter) while counter is half torn down.
struct Plugin: CordisPlugin {
  static let manifest = Manifest(name: "Watcher", version: "1.0.0", inject: ["counter"], provides: ["watcher"])

  static func apply(_ ctx: Context) throws(PluginError) {
    _ = ctx.call("counter", "get")
    ctx.provide("watcher") { _, _ in .int(1) }
  }
}
