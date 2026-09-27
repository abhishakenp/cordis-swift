// Fixture: crashes the host on demand, to exercise crash attribution.
#if CRASHER_V2
  let crasherVersion = "2.0.0"
#else
  let crasherVersion = "1.0.0"
#endif

struct Plugin: CordisPlugin {
  static let manifest = Manifest(name: "Crasher", version: crasherVersion, provides: ["crasher"])

  static func apply(_ ctx: Context) throws(PluginError) {
    ctx.provide("crasher") { method, args in
      switch method {
      case "segv":
        let p = UnsafeMutablePointer<Int64>(bitPattern: 8)!
        p.pointee = args.int ?? 1
        return .int(p.pointee)
      case "trap":
        let items: [Int64] = []
        return .int(items[Int(args.int ?? 3)])
      default:
        return .string(crasherVersion)
      }
    }
  }
}
