import CCordis

/// Static C entry points of the `cordis_host` table. `host_ctx` is an unretained `PluginRecord`,
/// so every registration is attributed to the plugin that made it.
enum HostTable {
  static func make(context: UnsafeMutableRawPointer?) -> cordis_host {
    cordis_host(
      abi_version: UInt32(CORDIS_ABI_VERSION),
      host_ctx: context,
      log: { ctx, level, msg in
        let r = HostTable.record(ctx)
        MainActor.assumeIsolated { r.host.pluginLog(r, level: level, message: CBytes.string(msg)) }
      },
      call: { ctx, service, method, args in
        let r = HostTable.record(ctx)
        return MainActor.assumeIsolated {
          r.host.rawCall(from: r, service: CBytes.string(service), method: method, args: args)
        }
      },
      on: { ctx, event, fn, userdata in
        let r = HostTable.record(ctx)
        guard let fn else { return 0 }
        nonisolated(unsafe) let userdata = userdata
        return MainActor.assumeIsolated {
          r.host.addListener(owner: r, event: CBytes.string(event), target: .plugin(fn, userdata))
        }
      },
      emit: { ctx, event, payload in
        let r = HostTable.record(ctx)
        MainActor.assumeIsolated { r.host.rawEmit(from: r, event: CBytes.string(event), payload: payload) }
      },
      provide: { ctx, service, fn, userdata in
        let r = HostTable.record(ctx)
        guard let fn else { return 0 }
        nonisolated(unsafe) let userdata = userdata
        return MainActor.assumeIsolated {
          r.host.addService(owner: r, name: CBytes.string(service), target: .plugin(fn, userdata))
        }
      },
      timer: { ctx, ms, repeats, fn, userdata in
        let r = HostTable.record(ctx)
        guard let fn else { return 0 }
        nonisolated(unsafe) let userdata = userdata
        return MainActor.assumeIsolated {
          r.host.addTimer(owner: r, milliseconds: ms, repeats: repeats, target: .plugin(fn, userdata))
        }
      },
      dispose: { ctx, handle in
        let r = HostTable.record(ctx)
        MainActor.assumeIsolated { r.host.dispose(handle, requestedBy: r) }
      }
    )
  }

  @inline(__always)
  fileprivate static func record(_ ctx: UnsafeMutableRawPointer?) -> PluginRecord {
    Unmanaged<PluginRecord>.fromOpaque(ctx!).takeUnretainedValue()
  }
}

enum CBytes {
  static func string(_ b: cordis_bytes) -> String {
    guard let data = b.data, b.len > 0 else { return "" }
    return String(decoding: UnsafeBufferPointer(start: data, count: b.len), as: UTF8.self)
  }

  static func value(_ b: cordis_bytes) -> Value {
    guard let data = b.data, b.len > 0 else { return .null }
    return Codec.decode(UnsafeRawBufferPointer(start: data, count: b.len)) ?? .null
  }

  /// Decodes a malloc'd buffer produced by a plugin, then frees it.
  static func take(_ b: cordis_bytes) -> Value {
    let v = value(b)
    if let data = b.data { free(UnsafeMutableRawPointer(mutating: data)) }
    return v
  }

  static func owned(_ bytes: [UInt8]) -> cordis_bytes {
    let p = malloc(max(bytes.count, 1))!.assumingMemoryBound(to: UInt8.self)
    bytes.withUnsafeBufferPointer { if let base = $0.baseAddress { p.update(from: base, count: $0.count) } }
    return cordis_bytes(data: UnsafePointer(p), len: bytes.count)
  }

  static func owned(_ value: Value) -> cordis_bytes {
    let n = Codec.encodedSize(value)
    let p = malloc(max(n, 1))!.assumingMemoryBound(to: UInt8.self)
    Codec.encode(value, into: p)
    return cordis_bytes(data: UnsafePointer(p), len: n)
  }

  @inline(__always)
  static func borrow<R>(_ bytes: [UInt8], _ body: (cordis_bytes) -> R) -> R {
    bytes.withUnsafeBufferPointer { body(cordis_bytes(data: $0.baseAddress, len: $0.count)) }
  }

  @inline(__always)
  static func borrow<R>(_ string: String, _ body: (cordis_bytes) -> R) -> R {
    var s = string
    return s.withUTF8 { body(cordis_bytes(data: $0.baseAddress, len: $0.count)) }
  }
}

// Plain C value types; only ever used on the main thread.
extension cordis_bytes: @retroactive @unchecked Sendable {}
