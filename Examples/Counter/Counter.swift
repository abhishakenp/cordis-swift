// Example provider: exposes a "counter" service.
//   counter.increment(n?) -> new total      counter.get() -> total      counter.version() -> string
// Build with -D COUNTER_V2 to get a v2 that steps by 10 (used by the hot-reload test).

#if COUNTER_V2
  let step: Int64 = 10
  let versionString = "2.0.0"
#else
  let step: Int64 = 1
  let versionString = "1.0.0"
#endif

nonisolated(unsafe) var total: Int64 = 0

struct Plugin: CordisPlugin {
  static let manifest = Manifest(name: "Counter", version: versionString, provides: ["counter"])

  static func apply(_ ctx: Context) throws(PluginError) {
    total = 0
    ctx.provide("counter") { method, args in
      switch method {
      case "increment":
        total += (args.int ?? 1) * step
        ctx.emit("counter/changed", .int(total))
        return .int(total)
      case "get":
        return .int(total)
      case "version":
        return .string(versionString)
      case "echo":
        return args
      default:
        return ["error": .string("counter: unknown method " + method)]
      }
    }
    ctx.log("counter " + versionString + " ready")
  }

  static func dispose() { total = 0 }
}
