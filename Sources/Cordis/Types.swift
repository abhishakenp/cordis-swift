@_exported import CordisValue

/// Identifies one registration (listener, service, timer). 0 is never a valid handle.
public typealias CordisHandle = UInt64

public enum LogLevel: Int32, Sendable {
  case debug = 0, info = 1, warn = 2, error = 3
}

public enum PluginState: Equatable, Sendable {
  /// Loaded, waiting for these injected services to exist.
  case pending(missing: [String])
  /// `cordis_plugin_apply` succeeded and the plugin's registrations are live.
  case active
  /// Not running and its image is unloaded. Needs a new build (or an explicit `load`).
  case disabled(reason: String)
}

public struct PluginInfo: Equatable, Sendable {
  public let id: String
  public let name: String
  public let version: String
  public let inject: [String]
  public let provides: [String]
  /// The path the plugin was loaded from (not the private cache copy).
  public let path: String
  /// First 16 hex digits of the SHA-256 of the dylib.
  public let buildHash: String
  public let state: PluginState
}

/// What happened when a plugin image was closed.
public struct UnloadReport: Equatable, Sendable {
  public let id: String
  /// The image path as dyld knew it (the private cache copy).
  public let imagePath: String
  public let imageCountBefore: Int
  public let imageCountAfter: Int
  /// True when dyld no longer lists the image and its code address no longer resolves.
  public let unmapped: Bool
  /// Plugins that were disposed by the cascade because they injected a service this one provided.
  public let cascaded: [String]
}

/// Written by the signal handler when a plugin crashed the process; read back on the next start.
public struct CrashRecord: Equatable, Sendable {
  public let pluginID: String
  public let buildHash: String
  public let signal: Int32
}

public enum PluginHostError: Error, Equatable, CustomStringConvertible {
  case unreadable(path: String, reason: String)
  case dlopenFailed(String)
  case missingExport(String)
  case badManifest(String)
  case abiMismatch(Int64)
  case duplicate(id: String)
  case crashedBuild(id: String, buildHash: String)
  case notLoaded(id: String)

  public var description: String {
    switch self {
    case let .unreadable(path, reason): "cannot read \(path): \(reason)"
    case let .dlopenFailed(msg): "dlopen failed: \(msg)"
    case let .missingExport(sym): "plugin does not export \(sym)"
    case let .badManifest(msg): "bad manifest: \(msg)"
    case let .abiMismatch(v): "plugin ABI \(v) is not supported (host speaks \(1))"
    case let .duplicate(id): "a plugin with id '\(id)' is already loaded"
    case let .crashedBuild(id, hash): "plugin '\(id)' build \(hash) crashed the host last time; waiting for a new build"
    case let .notLoaded(id): "no plugin with id '\(id)'"
    }
  }
}

/// Lifecycle notifications, for logging and UI.
public enum HostEvent: Sendable {
  case log(pluginID: String, level: LogLevel, message: String)
  case applied(id: String)
  case disposed(id: String)
  case applyFailed(id: String, reason: String)
  case unloaded(UnloadReport)
  case reloaded(id: String, buildHash: String)
  case reloadFailed(path: String, reason: String)
}
