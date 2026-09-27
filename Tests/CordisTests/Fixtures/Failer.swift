// Fixture: refuses to apply.
struct Plugin: CordisPlugin {
  static let manifest = Manifest(name: "Failer", provides: ["failer"])

  static func apply(_ ctx: Context) throws(PluginError) {
    ctx.provide("failer") { _, _ in "should never be callable" }
    throw PluginError("failer: refusing on purpose")
  }
}
