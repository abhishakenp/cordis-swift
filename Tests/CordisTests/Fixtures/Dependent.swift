// Fixture: injects "crasher". When crasher crashes, this one is disposed normally (its dispose runs
// and tells the host), and it is applied again when a new crasher build loads.
struct Plugin: CordisPlugin {
  static let manifest = Manifest(name: "Dependent", version: "1.0.0", inject: ["crasher"], provides: ["dependent"])

  static func apply(_ ctx: Context) throws(PluginError) {
    ctx.provide("dependent") { method, args in
      // Calls into crasher; a crash there comes back as an error value.
      ctx.call("crasher", method, args)
    }
  }

  static func dispose() {
    Context().emit("dependent/disposed", true)
  }
}
