@_exported import CordisValue
#if canImport(Darwin)
  import Darwin
#else
  import Glibc
#endif

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
  /// Where it runs (`.process` for plugins in a helper process).
  public var isolation: PluginIsolation = .inProcess
  /// The helper's pid for an out-of-process plugin that is running.
  public var helperPID: Int32? = nil
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
  /// The plugin's code faulted while the host read its manifest; the host recovered.
  case crashedWhileLoading(path: String, signal: Int32)
  /// The helper process for an out-of-process plugin could not be started or did not answer.
  case helperFailed(String)

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
    case let .crashedWhileLoading(path, signal): "plugin \(path) crashed while loading (\(signalName(signal)))"
    case let .helperFailed(reason): "plugin helper: \(reason)"
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
  /// A plugin's code faulted and the host recovered: the plugin was fenced off, its dependents
  /// disposed, its registrations dropped and its image closed. It stays `.disabled` until it is
  /// loaded or reloaded again. The process keeps running.
  case crashed(CrashReport)
}

/// A plugin fault the host recovered from (see `PluginHost.crashRecovery`).
public struct CrashReport: Equatable, Sendable {
  public let id: String
  public let buildHash: String
  public let signal: Int32
  /// The plugin's path (as loaded).
  public let path: String
  /// Plugins that were disposed because they injected a service the crashed plugin provided.
  public let cascaded: [String]
  /// True when the plugin's image was closed and unmapped (or its helper process exited).
  public let unmapped: Bool
}

/// "SIGSEGV", "SIGTRAP", ... for the fault signals cordis handles; "signal N" otherwise.
public func signalName(_ signal: Int32) -> String {
  switch signal {
  case SIGSEGV: "SIGSEGV"
  case SIGBUS: "SIGBUS"
  case SIGILL: "SIGILL"
  case SIGTRAP: "SIGTRAP"
  case SIGABRT: "SIGABRT"
  case SIGFPE: "SIGFPE"
  case SIGKILL: "SIGKILL"
  default: "signal \(signal)"
  }
}
