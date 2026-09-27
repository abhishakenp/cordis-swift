// Example consumer: injects "counter", provides "greeter", and reacts to events.
//   greeter.greet({"name": String}) -> "Hello, <name>! (#<n>)"   n comes from counter.increment
//   Listens to "greeter/ping" and answers with "greeter/pong" carrying the same payload.
//   Mirrors every "counter/changed" event as "greeter/seen".

struct Plugin: CordisPlugin {
  static let manifest = Manifest(
    name: "Greeter", version: "1.0.0", inject: ["counter"], provides: ["greeter"])

  static func apply(_ ctx: Context) throws(PluginError) {
    guard ctx.call("counter", "version").string != nil else {
      throw PluginError("greeter: counter service is not answering")
    }
    ctx.provide("greeter") { method, args in
      guard method == "greet" else { return ["error": .string("greeter: unknown method " + method)] }
      let name = args["name"].string ?? "world"
      let n = ctx.call("counter", "increment").int ?? -1
      return .string("Hello, " + name + "! (#" + String(n) + ")")
    }
    ctx.on("greeter/ping") { payload in ctx.emit("greeter/pong", payload) }
    ctx.on("counter/changed") { payload in ctx.emit("greeter/seen", payload) }
  }
}
