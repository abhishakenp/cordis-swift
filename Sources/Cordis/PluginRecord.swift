import CCordis
import CCordisHost
import Foundation

/// One loaded plugin image and everything it registered. Owned by `PluginHost`.
@MainActor
final class PluginRecord {
  enum Phase: Equatable {
    case pending
    case active
    case disposing
    case disabled(String)
  }

  let id: String
  let name: String
  let version: String
  let inject: [String]
  let provides: [String]
  let path: String
  let buildHash: String
  let imagePath: String
  let cachePath: String?

  var dl: UnsafeMutableRawPointer?
  let applyFn: cordis_plugin_apply_fn?
  let disposeFn: cordis_plugin_dispose_fn?
  /// Any code address inside the image, used to double-check that it was unmapped.
  let probeAddress: UnsafeRawPointer?

  var phase: Phase = .pending
  var handles: Set<CordisHandle> = []
  /// The image's __TEXT range: a fault there while this plugin runs is recovered (`cordis_guard_*`).
  let image: cordis_guard_image
  /// Set when the plugin's code faulted and the host recovered. From then on nothing calls into it.
  var crash: Int32?
  /// How many calls into this plugin are on the stack right now.
  var frames = 0

  /// "<id>\t<buildHash>", read by the crash handler while this plugin's code runs.
  let tag: UnsafeMutablePointer<CChar>
  /// The per-plugin function table handed to `cordis_plugin_apply`; host_ctx points back here.
  let table: UnsafeMutablePointer<cordis_host>
  unowned(unsafe) let host: PluginHost

  init(
    host: PluginHost, id: String, name: String, version: String, inject: [String], provides: [String],
    path: String, buildHash: String, imagePath: String, cachePath: String?, dl: UnsafeMutableRawPointer?,
    applyFn: cordis_plugin_apply_fn?, disposeFn: cordis_plugin_dispose_fn?, probeAddress: UnsafeRawPointer?,
    phase: Phase = .pending
  ) {
    self.host = host
    self.id = id
    self.name = name
    self.version = version
    self.inject = inject
    self.provides = provides
    self.path = path
    self.buildHash = buildHash
    self.imagePath = imagePath
    self.cachePath = cachePath
    self.dl = dl
    self.applyFn = applyFn
    self.disposeFn = disposeFn
    self.probeAddress = probeAddress
    self.phase = phase
    self.image = probeAddress.map { cordis_guard_image_of($0) } ?? cordis_guard_image(lo: 0, hi: 0)
    self.tag = strdup("\(id)\t\(buildHash)")!
    self.table = .allocate(capacity: 1)
    self.table.initialize(to: HostTable.make(context: nil))
    self.table.pointee.host_ctx = Unmanaged.passUnretained(self).toOpaque()
  }

  isolated deinit {
    free(tag)
    table.deinitialize(count: 1)
    table.deallocate()
  }

  func info(missing: [String]) -> PluginInfo {
    let state: PluginState =
      switch phase {
      case .active: .active
      case .pending, .disposing: .pending(missing: missing)
      case let .disabled(reason): .disabled(reason: reason)
      }
    return PluginInfo(
      id: id, name: name, version: version, inject: inject, provides: provides, path: path,
      buildHash: buildHash, state: state)
  }
}
