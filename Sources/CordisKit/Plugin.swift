// Plugin SDK: what a plugin author implements, plus the glue the generated exports call.
// Foundation-free; compiles as Embedded Swift (and as a normal SwiftPM target for type-checking).

#if !hasFeature(Embedded)
  import CordisValue
#endif
import CCordis

/// Static description of a plugin. The plugin id is supplied by `cordis-build --id`.
public struct Manifest {
  public var name: String
  public var version: String
  /// Services that must exist before `apply` runs. The plugin is disposed when any goes away.
  public var inject: [String]
  /// Services this plugin promises to provide (informational; used for diagnostics).
  public var provides: [String]

  public init(name: String, version: String = "0.0.0", inject: [String] = [], provides: [String] = []) {
    self.name = name
    self.version = version
    self.inject = inject
    self.provides = provides
  }
}

/// Returned from `apply` to refuse activation. The host disables the plugin and reports `message`.
public struct PluginError: Error {
  public var message: String
  public init(_ message: String) { self.message = message }
}

/// Implement this on a type named `Plugin` (or pass `--entry <Type>` to cordis-build).
public protocol CordisPlugin {
  static var manifest: Manifest { get }
  /// Called on the main thread once every injected service exists.
  /// Everything registered through `ctx` is released automatically on dispose.
  static func apply(_ ctx: Context) throws(PluginError)
  /// Release plugin-owned state. Called before the host drops the plugin's registrations.
  static func dispose()
}

extension CordisPlugin {
  public static func dispose() {}
}

// MARK: - Export glue (called from the generated @_cdecl functions)

public func _cordisExportManifest<P: CordisPlugin>(_: P.Type, id: String) -> cordis_bytes {
  let m = P.manifest
  let value: Value = .object([
    ("id", .string(id)),
    ("name", .string(m.name)),
    ("version", .string(m.version)),
    ("inject", .array(m.inject.map { .string($0) })),
    ("provides", .array(m.provides.map { .string($0) })),
    ("abi", .int(Int64(CORDIS_ABI_VERSION))),
  ])
  return Bytes.owned(value)
}

public func _cordisExportApply<P: CordisPlugin>(_: P.Type, id: String, _ host: UnsafePointer<cordis_host>?) -> Int32 {
  guard let host, host.pointee.abi_version == CORDIS_ABI_VERSION else { return 2 }
  Runtime.host = host
  Runtime.pluginID = id
  let ctx = Context()
  do {
    try P.apply(ctx)
    return 0
  } catch {
    ctx.log(error.message, level: .error)
    Runtime.releaseAll()
    return 1
  }
}

public func _cordisExportDispose<P: CordisPlugin>(_: P.Type) {
  P.dispose()
  Runtime.releaseAll()
  Runtime.host = nil
}
