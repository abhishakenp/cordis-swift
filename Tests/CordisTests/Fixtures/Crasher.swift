// Fixture: crashes on demand, to exercise crash attribution (a child process that dies) and crash
// recovery (the host survives, the plugin is unloaded).
#if CRASHER_V2
  let crasherVersion = "2.0.0"
#else
  let crasherVersion = "1.0.0"
#endif

import CCordis  // stdlib.h: mkstemp, exit

nonisolated(unsafe) var depth: Int64 = 0

/// Unbounded recursion: overflows the stack. The array keeps each frame alive.
@inline(never)
func recurse(_ n: Int64) -> Int64 {
  var local: [Int64] = [n, n &+ 1]
  depth = n
  local.append(recurse(n &+ 1))
  return local[2]
}

func crash(_ how: String, _ arg: Int64) -> Value {
  switch how {
  case "segv":
    let p = UnsafeMutablePointer<Int64>(bitPattern: 8)!
    p.pointee = arg
    return .int(p.pointee)
  case "trap":
    let items: [Int64] = []
    return .int(items[Int(arg)])
  case "fatal":
    fatalError("crasher: fatal on purpose")
  case "unwrap":
    let missing: Int64? = arg > 1000 ? arg : nil
    return .int(missing!)
  case "overflow":
    return .int(recurse(arg))
  case "memcpy":
    // A wild copy: libsystem_platform's memmove faults, called straight from plugin code.
    let dst = UnsafeMutableRawPointer(bitPattern: 16)!
    let src: [UInt8] = [1, 2, 3, 4, 5, 6, 7, 8]
    src.withUnsafeBytes { dst.copyMemory(from: $0.baseAddress!, byteCount: 8) }
    return .null
  case "touch":
    // Creates a temporary file: -1 inside the pure-computation sandbox.
    var path: [CChar] = []
    for b in "/tmp/cordis-sandbox-XXXXXX".utf8 { path.append(CChar(bitPattern: b)) }
    path.append(0)
    return .int(Int64(path.withUnsafeMutableBufferPointer { mkstemp($0.baseAddress!) }))
  case "spin":
    // Never returns (a hung plugin).
    while depth >= 0 { depth &+= 1 }
    return .null
  case "exit":
    exit(Int32(truncatingIfNeeded: arg))
  default:
    return .string(crasherVersion)
  }
}

struct Plugin: CordisPlugin {
  static let manifest = Manifest(name: "Crasher", version: crasherVersion, provides: ["crasher"])

  static func apply(_ ctx: Context) throws(PluginError) {
    #if CRASH_IN_APPLY
      _ = crash("trap", 3)
    #endif
    ctx.on("crasher/boom") { payload in _ = crash(payload.string ?? "trap", 3) }
    ctx.provide("crasher") { method, args in
      switch method {
      case "later":
        // Crashes in a timer callback.
        ctx.timer(milliseconds: 5) { _ = crash("trap", 3) }
        return true
      case "call":
        // Calls another service (which may crash) and returns what came back.
        return ctx.call(args["service"].string ?? "", args["method"].string ?? "", args["args"])
      case "emit":
        ctx.emit(args["event"].string ?? "", args["payload"])
        return true
      default:
        return crash(method, args.int ?? 1)
      }
    }
  }
}
