// Fixture: injects a service nobody provides until the test does, and uses host services + timers.
nonisolated(unsafe) var ticks: Int64 = 0

struct Plugin: CordisPlugin {
  static let manifest = Manifest(name: "Needy", version: "1.0.0", inject: ["storage"], provides: ["needy"])

  static func apply(_ ctx: Context) throws(PluginError) {
    ticks = 0
    _ = ctx.call("storage", "set", ["key": "needy", "value": "applied"])
    var listener: Handle = 0
    listener = ctx.on("needy/poke") { payload in
      _ = ctx.call("storage", "set", ["key": "poked", "value": payload])
    }
    ctx.provide("needy") { method, args in
      switch method {
      case "unlisten":
        ctx.dispose(listener)
        return true
      case "timer":
        ctx.timer(milliseconds: UInt64(args.int ?? 10)) { ctx.emit("needy/fired", "once") }
        return true
      case "repeat":
        var h: Handle = 0
        h = ctx.timer(milliseconds: 5, repeats: true) {
          ticks += 1
          ctx.emit("needy/tick", .int(ticks))
          if ticks == 3 { ctx.dispose(h) }
        }
        return .int(Int64(h))
      default:
        return ["error": "unknown"]
      }
    }
  }

  static func dispose() {
    ticks = 0
  }
}
