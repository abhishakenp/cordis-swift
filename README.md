# cordis-swift

**Hot-swappable native plugins for Swift apps.** A Swift port of [cordis](https://github.com/cordiverse/cordis).

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Platform: macOS 26+](https://img.shields.io/badge/platform-macOS%2026%2B-lightgrey.svg)](#requirements)
[![Swift 6.2+](https://img.shields.io/badge/Swift-6.2%2B-orange.svg)](https://swift.org)

cordis-swift lets an app be built from plugins that can be loaded, unloaded and **replaced while
the app is running, in-process, with nothing left behind**. Plugins provide services, inject
services from other plugins, and talk over an event bus. When a service goes away, everything
that depends on it is disposed; when it comes back, they are applied again. That is the cordis
model, with native code and nanosecond-scale calls.

It is the plugin runtime of [den](https://github.com/abhishakenp/den), a WebKit browser for
macOS where every feature is a plugin.

```swift
import Cordis

let host = PluginHost()
host.provide("storage") { method, args in /* ... */ .null }  // host services are plain closures
host.watch("/path/to/libcounter.dylib")                       // load it, and hot-reload on rebuild
host.call("counter", "increment", 5)                          // -> .int(5)
```

## Why Embedded Swift

On macOS a dylib with normal Swift or Objective-C code **can never be unloaded**. `dlclose`
returns 0, but the image stays mapped, because the Swift and Objective-C runtimes have
registered its metadata (the `__swift5_*` and `__objc_*` sections) and never let go. Hot reload
built on normal Swift dylibs leaks every version you have ever loaded.

Plain C and **Embedded Swift** images have no runtime-registered metadata, so they do unload:
dyld's image count goes back down after `dlclose`. So cordis-swift is split in two:

| | Language | Talks through |
|---|---|---|
| **Host** (`Cordis`) | full Swift, Foundation, `@MainActor` | Swift API |
| **Plugins** (`CordisKit`) | Embedded Swift, no Foundation | the C ABI in [`cordis.h`](Sources/CCordis/include/cordis.h) |

`cordis-build` refuses to produce a plugin that contains a `__swift5_*` or `__objc_*` section,
and the host checks after every unload that the image is really gone. The integration tests
load and unload the same plugin 25 times and assert that dyld's image count returns to the
baseline every time.

No JavaScript and no WASM: a plugin call is a C function call (about 0.1 µs). A plugin that
traps or segfaults is unloaded and the app keeps running ([crash recovery](#crash-recovery)).
Plugins you don't trust can run in a sandboxed helper process instead, with the same API
([out-of-process plugins](#out-of-process-plugins)).

## Requirements

- macOS 26+ on Apple silicon (plugins target `arm64-apple-macos26`; override with `CORDIS_TARGET`).
- Xcode 26 / Swift 6.x for the host.
- A swift.org toolchain **with the Embedded Swift stdlib** for plugins (Xcode's toolchain does
  not ship it). Install one from [swift.org](https://www.swift.org/install/macos/) or with
  swiftly. `cordis-build` looks for one in this order:
  1. `$CORDIS_TOOLCHAIN`
  2. the newest toolchain in `~/.swiftly/toolchains`
  3. the newest `~/Library/Developer/Toolchains/*.xctoolchain` (versioned names first)
  4. `/Library/Developer/Toolchains/swift-latest.xctoolchain`

  Swift 6.2 and 6.3.2 are both tested; 6.3.2 matches Xcode 26.5.

## Quick start

### 1. Write a plugin

A plugin is one or more Swift files with a type named `Plugin` that conforms to `CordisPlugin`.
Don't `import` anything: the build compiles your files, `CordisValue` and `CordisKit` into a
single module.

```swift
// Counter.swift
nonisolated(unsafe) var total: Int64 = 0

struct Plugin: CordisPlugin {
  static let manifest = Manifest(name: "Counter", version: "1.0.0", provides: ["counter"])

  static func apply(_ ctx: Context) throws(PluginError) {
    ctx.provide("counter") { method, args in
      switch method {
      case "increment":
        total += args.int ?? 1
        ctx.emit("counter/changed", .int(total))
        return .int(total)
      case "get": return .int(total)
      default: return ["error": .string("unknown method " + method)]
      }
    }
  }

  static func dispose() { total = 0 }
}
```

A consumer declares what it needs in `inject`. `apply` only runs once all of those services
exist, and the plugin is disposed as soon as any of them goes away:

```swift
// Greeter.swift
struct Plugin: CordisPlugin {
  static let manifest = Manifest(name: "Greeter", inject: ["counter"], provides: ["greeter"])

  static func apply(_ ctx: Context) throws(PluginError) {
    ctx.provide("greeter") { _, args in
      let n = ctx.call("counter", "increment").int ?? 0
      return .string("Hello, " + (args["name"].string ?? "world") + "! (#" + String(n) + ")")
    }
    ctx.on("greeter/ping") { payload in ctx.emit("greeter/pong", payload) }
  }
}
```

`Context` API: `call(service, method, args) -> Value`, `on(event) { Value in }`,
`emit(event, payload)`, `provide(service) { method, args -> Value }`,
`timer(milliseconds:repeats:) { }`, `log(message, level:)`, `dispose(handle)`.
Everything registered through `ctx` is released automatically when the plugin is disposed.
Throw a `PluginError` from `apply` to refuse activation.

### 2. Build it

```sh
Scripts/cordis-build --id counter --out build/libcounter.dylib Examples/Counter/Counter.swift
Scripts/cordis-build --id greeter --out build/libgreeter.dylib Examples/Greeter/Greeter.swift
```

```
cordis-build --id <plugin-id> --out <path.dylib> [--entry <Type>] [-D <FLAG>]... <sources...>
```

What it does:

1. Resolves an Embedded Swift toolchain (see [Requirements](#requirements)).
2. Generates the three `@_cdecl` exports for your `Plugin` type (`--entry` picks another type).
3. Compiles your sources plus `CordisValue` and `CordisKit` with
   `swiftc -enable-experimental-feature Embedded -wmo -O` into a module named
   `CordisPlugin_<id>_<hash>`, where the hash covers the sources, flags and toolchain. Every build
   is unique.
4. Links with plain `clang -dynamiclib`, `-dead_strip`, and an exported-symbols list, so only
   `cordis_plugin_manifest`, `cordis_plugin_apply` and `cordis_plugin_dispose` are visible.
   Each plugin's copy of the embedded runtime stays private to it.
5. Runs `otool -l` and **fails if the output has any `__swift5_*` or `__objc_*` section**.
6. Moves the result into place atomically, so file watchers never see a half-written dylib.

On an M3, one build took 3.4 to 6.7 s of wall time in our runs, and the Counter example is
144,232 bytes.

### 3. Load it

```swift
import Cordis

@MainActor func start() throws {
  let host = PluginHost()
  host.onEvent = { event in print(event) }       // logs, applied/disposed, unload reports, reload failures

  try host.load("build/libgreeter.dylib")        // pending(missing: ["counter"])
  try host.load("build/libcounter.dylib")        // counter applies, then greeter applies

  host.call("greeter", "greet", ["name": "Den"]) // "Hello, Den! (#1)"
  host.on("greeter/pong") { print($0) }
  host.emit("greeter/ping", "hi")

  let report = try host.unload("counter")        // greeter is disposed first (cascade)
  print(report.unmapped, report.cascaded)        // true ["greeter"]

  host.watch("build/libcounter.dylib")           // load again and hot-reload on every rebuild
}
```

## Host API

`PluginHost` is `@MainActor`. Plugins are only ever called on the main thread.

| API | Purpose |
|---|---|
| `init(crashMarkerPath:cacheDirectory:)` | Both have sensible defaults under `~/Library/Caches/cordis-swift/<process>/`. Pass `crashMarkerPath: nil` to skip installing signal handlers. |
| `provide(_ name:, _ handler: (method, args) -> Value) -> CordisHandle` | Host service. Plugins that inject `name` become applicable. |
| `call(_ service:, _ method:, _ args:) -> Value` | Call a host or plugin service. Failures come back as `{"error": "..."}`. |
| `on(_ event:, _ handler:) -> CordisHandle`, `emit(_:_:)` | Event bus shared by host and plugins. |
| `hasListeners(_ event:)` | True when the host or any plugin listens to the event. |
| `timer(milliseconds:repeats:_:) -> CordisHandle` | Main-queue timer. |
| `dispose(_ handle:)` | Remove any registration. Removing a service cascades to its dependents. |
| `load(_ path:, isolation:) throws -> PluginInfo` | Load a dylib and apply it when its injections exist. `isolation`: `.inProcess` (default) or `.process(sandbox:)`; reloads keep it. |
| `unload(_ id:) throws -> UnloadReport` | Dispose (with cascade), drop handles, `dlclose`, verify unmapped. |
| `reload(path:) -> ReloadResult` | Swap in the file's current build. `.unchanged`, `.reloaded`, or `.failed(reason:)`. |
| `watch(_ path:, isolation:)`, `unwatch(_:)` | Hot reload on file changes. |
| `plugins`, `plugin(_ id:)`, `serviceNames` | Introspection. `PluginState` is `.pending(missing:)`, `.active` or `.disabled(reason:)`. |
| `lastCrash: CrashRecord?`, `clearCrashRecord()` | Crash attribution (see below). |
| `onCrash`, `HostEvent.crashed`, `PluginHost.crashRecovery` | Crash recovery (see below). |
| `caller: String?` | The plugin a host service or host listener is serving right now (nil for host-initiated work). Gate host services per plugin with it instead of trusting an argument. |
| `authorize: ((plugin, PluginAccess) -> Bool)?` | Asked before a plugin calls any service, listens to or emits an event, or provides a service (in-process and out-of-process alike). A refused call returns `{"error": "permission denied: ..."}`, a refused listen or provide returns handle 0, a refused emit is dropped. |
| `helperExecutable`, `helperTimeout`, `helperFootprint(_:)` | Out-of-process plugins (see below). |
| `pruneCache()` | Delete cached dylib copies that are not loaded. |

### Lifecycle and dependency rules

- A loaded plugin is **pending** until every service in its `inject` list exists, then
  `cordis_plugin_apply` runs and it is **active**.
- When a service disappears (its provider was unloaded or disposed it, or the host disposed
  it), every active plugin that injects it is disposed **before** the provider finishes going
  away, recursively. Those plugins go back to pending and are applied again when the service
  returns. This is the cordis fork semantics.
- Unloading a plugin calls `cordis_plugin_dispose`, removes every listener, service and timer it
  registered, cascades to dependents, calls `dlclose`, and then checks both that dyld no longer
  lists the image and that `dladdr` no longer resolves an address inside it. The result is in
  `UnloadReport.unmapped`, along with the dyld image count before and after.
- If `apply` fails (the plugin throws `PluginError` or returns non-zero), its registrations are
  dropped, the image is unloaded, and the plugin becomes `.disabled(reason:)`.

### Hot reload

`watch(path)` watches the file's directory (build tools replace files rather than write them in
place) and debounces changes by 50 ms. When the file's hash changes, the host unloads the old
build (dependents are disposed), loads the new one (dependents are applied again), and emits
`.reloaded`. If the new build cannot be loaded or refuses to apply, the plugin stays
`.disabled(reason:)`, `.reloadFailed(path:reason:)` is emitted, and the next good build
recovers it.

Each dylib is copied to a **content-addressed cache** (`<cache>/<sha256-prefix>.dylib`) before
`dlopen`. Two builds therefore never collide in dyld, the source file can be overwritten while
it is loaded, and macOS's first-`dlopen` check of a new file is paid only once per build. That
check was measured at 290 to 720 ms per new file on the test machine, while reopening a file
dyld has already checked took under 1 ms.

### Crash recovery

Every call from the host into plugin code (a service call, an event, a timer, `apply`,
`dispose`, reading the manifest) goes through a small C guard that records a `_setjmp` frame and
the plugin image's `__TEXT` range. When `SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGTRAP` or `SIGFPE`
arrives on that thread, the handler checks where it happened:

- **Inside the plugin's own code** (a bounds check, a force unwrap, `fatalError`, a null write, a
  stack overflow), or inside a lock-free `libsystem_platform` routine such as `memcpy` that the
  plugin called directly: the interrupted context is redirected to a trampoline that jumps back
  to the guard. Returning from the handler (instead of jumping out of it) lets the kernel restore
  the signal mask and the alternate-stack state, so the guard needs no syscall per call.
- **Anywhere else** (host code, `malloc`, another thread): not recoverable, so the process
  crashes and the fault is attributed as below.

Recovery never skips host frames: every time host code calls into a plugin it pushes a new frame,
so only plugin frames lie between the innermost frame and a fault in that plugin.

The faulting plugin is then fenced off at once (its services return
`{"error": "plugin 'x' crashed (SIGTRAP)"}`, its listeners and timers stop) and torn down as soon
as no plugin code is left on the stack: plugins that inject its services are disposed normally,
its own `dispose` is skipped (its state can't be trusted), every registration is dropped and the
image is closed. It becomes `.disabled(reason: "crashed (SIGTRAP)")` and the host gets
`HostEvent.crashed(CrashReport)` and `onCrash`. Loading it again works. Memory the plugin had
allocated from `malloc` stays allocated.

Tests: each fault kind above (including a stack overflow and a wild `memcpy`) in a service, an
event listener, a timer and `apply`; 20 crashes in a row; a crash two plugins deep; the dependent
being disposed and re-applied; a real process with the crash marker installed surviving.
`PluginHost.crashRecovery = false` turns it off.

### Crash attribution

The host keeps a pointer to the id of the plugin whose code is currently running (the id and
build hash as one C string), swapped on every call into a plugin. It installs handlers for
`SIGSEGV`, `SIGBUS`, `SIGILL`, `SIGTRAP`, `SIGABRT` and `SIGFPE`. The handlers are plain C, use
only async-signal-safe calls, and run on an alternate stack. If a plugin was executing, the
handler writes `id \t build-hash \t signal` to the marker file, restores the previous handler (so
crash reporters still run), and re-raises.

On the next start, `PluginHost.lastCrash` reports that plugin. Loading the **same build** throws
`PluginHostError.crashedBuild`, and the plugin is shown as disabled. Loading a **new build** of
the same plugin id clears the record. The tests crash a child process on purpose with both a
null write (`SIGSEGV`) and a Swift trap (`SIGTRAP`) to check this.

## Out-of-process plugins

`load(path, isolation: .process(sandbox: true))` runs the plugin in its own
`cordis-plugin-helper` process. The plugin binary and its API are unchanged: the helper hands it
the usual `cordis_host` table, and each entry forwards to the host over a Unix socket
([CordisWire](Sources/CordisWire/Wire.swift): length-prefixed CordisValue frames).

- **Calls nest both ways.** A host service call waits for the answer while serving the helper's
  own requests (calls, registrations, emits), and the helper does the same, so
  host -> plugin -> host -> plugin chains work, including a plugin calling its own service.
- **Events and timer ticks are sent without waiting**, in order, so a slow plugin doesn't stall
  the host. The helper still has to answer each within `helperTimeout` (5 s by default).
- **A crash or a hang only ends the helper.** EOF, a non-zero exit, or a missed timeout kills the
  helper and goes through the same path as an in-process fault (`HostEvent.crashed`, dependents
  disposed, `.disabled`).
- **Sandbox.** With `sandbox: true` the helper enters the "pure computation" sandbox right after
  `dlopen`: no files, no network, no new processes or IPC. The plugin reaches the world only
  through host services, and `caller` tells the host which plugin is asking.
- **Hot reload** keeps the isolation: a new build gets a new helper.

Ship the helper next to the app's executable (or in `Contents/Helpers`), or build your own: it is
one line, `cordisHelperMain(CommandLine.arguments)` from the `CordisHelper` library.

Cost, measured with `cordis-bench remote` (below): about 9 µs per call against about 0.1 µs in
process, 2.5 ms to start a helper and apply its plugin, and 1.2 to 1.9 MB of physical footprint
per helper. Use it for plugins you don't trust, not for hot paths.

## The ABI (v1)

The whole contract is [`Sources/CCordis/include/cordis.h`](Sources/CCordis/include/cordis.h).
Plugins can be written in C as well.

- **Values** cross the boundary as `cordis_bytes` (`{data, len}`) holding the
  [`CordisValue`](Sources/CordisValue/Codec.swift) binary encoding: null, bool, int64, double,
  string, bytes, array, and ordered object.
- **Host table** (`cordis_host`), passed to `cordis_plugin_apply`: `log`, `call`, `on`, `emit`,
  `provide`, `timer`, `dispose`, plus `abi_version` and an opaque `host_ctx`. Every plugin gets
  its own table, so the host knows who registered what.
- **Plugin exports**: `cordis_plugin_manifest()` returns
  `{"id", "name", "version", "inject": [..], "provides": [..], "abi": 1}`.
  `cordis_plugin_apply(host)` returns 0 on success, and `cordis_plugin_dispose()` releases
  plugin state.
- **Ownership**: every `cordis_bytes` returned across the boundary is `malloc`'d by the producer
  and `free`'d by the receiver. Arguments are borrowed for the duration of the call.
- **Threading**: main thread only, in both directions.
- **Errors**: services return `{"error": "<message>"}`.

## Benchmarks

### Crash recovery guard and out-of-process calls

Same Counter plugin, release builds, an M-series Mac that was busy with other builds
(load average 9 to 22), three runs each. `old` is v0.1.2 (no guard), `new` is this version:

```sh
cordis-bench bench  libcounter.dylib 1000000 100                          # in-process
cordis-bench remote libcounter.dylib .build/release/cordis-plugin-helper 20000 10
```

| Measurement | v0.1.2 | this version |
|---|---|---|
| host -> plugin call, `counter.get()` | 135.9 / 167.0 / 144.5 ns | 86.7 / 100.0 / 91.7 ns |
| host -> plugin call, `counter.echo({url, tab, flags})` | 742.8 / 850.3 / 721.8 ns | 723.1 / 749.3 / 792.9 ns |
| host -> helper call, `counter.get()` (sandboxed helper) | – | 9.08 / 9.07 / 9.30 µs |
| host -> helper call, `counter.echo({url, tab, flags})` | – | 10.60 / 9.12 / 9.87 µs |
| host -> helper call, `echo` of a 35,785-byte array | – | 240.4 / 239.6 / 242.8 µs |
| start helper + manifest + apply + unload | – | 2.81 / 2.51 / 2.53 ms |
| helper `phys_footprint`, 1 plugin, sandboxed | – | 1,802,600 / 1,900,904 / 1,900,904 B |
| 10 helpers, mean footprint each | – | 1,209,480 / 1,202,921 / 1,211,113 B |

The guarded call is not slower than v0.1.2's call: the guard replaced two Swift calls that swapped
the crash tag around every call.

### v0.1 baseline

Measured for v0.1. Machine: Apple M3, macOS 26.5, host built with Swift 6.3.2 (`-c release`), plugin built by
`cordis-build` with the swift.org 6.3.2 toolchain. The command, which builds the Counter example
and runs 1,000,000 calls and 100 load/unload cycles:

```sh
Scripts/bench            # = cordis-build Counter + swift build -c release + cordis-bench bench <dylib> 1000000 100
```

Three consecutive runs. Another build was running on the machine at the same time, so the
spread is real noise:

| Measurement | Run 1 | Run 2 | Run 3 |
|---|---|---|---|
| host → plugin call, `counter.get()` (encode, call, decode, free) | 193.6 ns/op | 234.3 ns/op | 275.2 ns/op |
| host → plugin call, `counter.echo(int)` | 189.3 ns/op | 222.1 ns/op | 307.9 ns/op |
| host → plugin call, `counter.echo({url, tab, flags})` | 1050.6 ns/op | 1342.5 ns/op | 1748.5 ns/op |
| baseline: host → host Swift closure, same call shape | 52.5 ns/op | 68.7 ns/op | 89.0 ns/op |
| load + apply + 1 call + unload (cached build) | 677.9 µs | 885.0 µs | 1115.9 µs |
| images unmapped after unload | 100/100 | 100/100 | 100/100 |
| dyld image count before → after 100 cycles | 350 → 350 | 350 → 350 | 350 → 350 |
| `phys_footprint` delta across 100 cycles | +360,448 B | +360,448 B | +360,448 B |

About the footprint delta: `leaks --atExit` on the same benchmark reports
`0 leaks for 0 total leaked bytes`, and dyld's image count is unchanged. In a separate run of
10, 100 and 1000 cycles, the deltas were 294,912, 327,680 and 655,360 bytes. That growth is
strongly sublinear (10× the cycles, about 2× the delta), which fits allocator or dyld bookkeeping
retention better than a per-plugin leak. It is not fully explained yet.

## Limitations

- **No Foundation, AppKit or SwiftUI in plugins.** Embedded Swift has no Objective-C interop, no
  existentials (`any P`), and no runtime reflection. Plugins can use the Swift stdlib (String,
  Array, Dictionary, classes, closures, generics, typed throws) and C APIs.
- **UI is described, not drawn, by plugins.** A plugin sends data (Values) to host services, and
  the host app turns that into UI. In den, the browser owns the views and plugins describe
  them.
- **Main thread only.** A plugin that calls the host from another thread traps.
- **Global state in plugins** needs `nonisolated(unsafe)`. Reset it in `dispose`, because a
  plugin can be applied again without being reloaded.
- **In-process plugins are not sandboxed.** They run with the app's privileges, and a plugin that
  corrupts the heap (or faults inside `malloc`) still takes the process down; recovery covers
  faults in the plugin's own code. Run untrusted plugins with `.process(sandbox: true)`.
- One provider per service name. A second `provide` of the same name returns handle 0 and logs
  an error.
- Only arm64 dylibs are built by default.

## Design decisions

These were made while building the port and are open to change:

- **The plugin id comes from `cordis-build --id`**, not from the source. The build is the single
  source of truth, and the id also names the module.
- **`cordis.h` includes `<stdlib.h>`**, so Embedded Swift gets `malloc`/`free` from the ABI
  module. This is a compatible extension, and the ABI is still v1. The manifest also gains an
  optional `"abi"` key.
- Plugins can only dispose handles they own. The host can dispose any handle.
- The crash marker records the last crash only.
- `CordisKit` is also a normal SwiftPM target, but only so that `swift build` type-checks the SDK.
  Real plugins always go through `cordis-build`.

## Layout

```
Sources/CCordis/include/cordis.h   the plugin ABI (C)
Sources/CordisValue/               Value + binary codec, Foundation-free, shared with plugins
Sources/CordisKit/                 Embedded Swift plugin SDK
Sources/Cordis/                    host runtime (PluginHost)
Sources/CCordisHost/               async-signal-safe crash attribution and recovery guards (C)
Sources/CordisWire/                framed messages between a host and a plugin helper
Sources/CordisHelper/              the helper's runtime (cordisHelperMain); CCordisHelper: sandbox
Sources/cordis-plugin-helper/      the helper executable
Sources/cordis-bench/              benchmark + crash helper
Scripts/cordis-build               plugin build script
Examples/Counter, Examples/Greeter provider + consumer
Tests/CordisTests/                 integration tests (build real plugins with cordis-build)
```

Run the tests with `swift test`. The integration tests build the examples and fixtures with
`cordis-build`, so they need an Embedded Swift toolchain.

## Credits

cordis-swift is a port of **[cordis](https://github.com/cordiverse/cordis)** by
[Shigma](https://github.com/shigma), the meta-framework behind Koishi. The service, inject and
fork model and the "everything is a plugin" philosophy come from there. cordis is MIT licensed,
© Shigma.

## License

[MIT](LICENSE) © 2026 Abhi and cordis-swift contributors.
