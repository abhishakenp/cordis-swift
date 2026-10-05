// cordis-bench: micro-benchmarks for the plugin host, plus a crash helper used by the tests.
//
//   cordis-bench bench <libcounter.dylib> [calls=1000000] [cycles=100]
//   cordis-bench crash <plugin.dylib> <marker-path> <service> <method> [recover]
import Cordis
import Darwin
import Foundation

func footprint() -> UInt64 {
  var info = task_vm_info_data_t()
  var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
  let kr = withUnsafeMutablePointer(to: &info) {
    $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
      task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
    }
  }
  return kr == KERN_SUCCESS ? info.phys_footprint : 0
}

func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

func fail(_ msg: String) -> Never {
  FileHandle.standardError.write(Data("cordis-bench: \(msg)\n".utf8))
  exit(2)
}

@MainActor
func bench(_ path: String, calls: Int, cycles: Int) {
  let host = PluginHost(crashMarkerPath: nil)
  host.onEvent = { _ in }
  do { try host.load(path) } catch { fail("load failed: \(error)") }
  guard host.plugin("counter")?.state == .active else { fail("counter plugin is not active") }

  // Warm up, then time host -> plugin round trips (encode args, call, decode result, free).
  for _ in 0..<10_000 { _ = host.call("counter", "get") }
  var t0 = now()
  var sink: Int64 = 0
  for _ in 0..<calls { sink &+= host.call("counter", "get").int ?? 0 }
  let getNs = Double(now() - t0) / Double(calls)

  t0 = now()
  for i in 0..<calls { sink &+= host.call("counter", "echo", .int(Int64(i))).int ?? 0 }
  let echoNs = Double(now() - t0) / Double(calls)

  let payload: Value = ["url": "https://example.com/some/page", "tab": 42, "flags": [true, false]]
  t0 = now()
  for _ in 0..<calls { if case .object = host.call("counter", "echo", payload) { sink &+= 1 } }
  let objNs = Double(now() - t0) / Double(calls)

  // Baseline: the same call shape against a host-provided Swift closure.
  host.provide("native") { _, args in args }
  t0 = now()
  for i in 0..<calls { sink &+= host.call("native", "echo", .int(Int64(i))).int ?? 0 }
  let nativeNs = Double(now() - t0) / Double(calls)

  _ = try? host.unload("counter")

  // Load/unload cycles: footprint and dyld image count before and after.
  let images0 = Int(_dyld_image_count())
  // One untimed cycle so one-time allocations (dyld caches, dictionaries) are not counted as leaks.
  _ = try? host.load(path)
  _ = try? host.unload("counter")
  let mem0 = footprint()
  var unmapped = 0
  t0 = now()
  for _ in 0..<cycles {
    do { try host.load(path) } catch { fail("load failed: \(error)") }
    _ = host.call("counter", "increment")
    if let r = try? host.unload("counter"), r.unmapped { unmapped += 1 }
  }
  let cycleUs = Double(now() - t0) / Double(cycles) / 1000
  let mem1 = footprint()
  let images1 = Int(_dyld_image_count())

  func f(_ x: Double) -> String { String(format: "%.1f", x) }
  print("host -> plugin call, counter.get()            : \(f(getNs)) ns/op  (\(calls) calls)")
  print("host -> plugin call, counter.echo(int)        : \(f(echoNs)) ns/op")
  print("host -> plugin call, counter.echo(3-key obj)  : \(f(objNs)) ns/op")
  print("host -> host closure, native.echo(int)        : \(f(nativeNs)) ns/op  (baseline)")
  print("load+apply+call+unload cycle                  : \(f(cycleUs)) us/cycle (\(cycles) cycles)")
  print("images unmapped after unload                  : \(unmapped)/\(cycles)")
  print("dyld image count before/after cycles          : \(images0) -> \(images1)")
  print(
    "phys_footprint before/after cycles            : \(mem0) -> \(mem1) bytes (delta \(Int64(mem1) - Int64(mem0)) bytes)"
  )
  if sink == 42 { print("") }  // keep `sink` alive
}

@MainActor
func crash(_ path: String, marker: String, service: String, method: String, recover: Bool) {
  PluginHost.crashRecovery = recover
  let host = PluginHost(crashMarkerPath: marker)
  host.onEvent = { _ in }
  do { try host.load(path) } catch { fail("load failed: \(error)") }
  let result = host.call(service, method, 1)
  print("survived: \(result)")
  print("state: \(String(describing: host.plugin("crasher")?.state))")
}

let args = CommandLine.arguments
switch args.dropFirst().first {
case "bench":
  guard args.count >= 3 else { fail("usage: cordis-bench bench <libcounter.dylib> [calls] [cycles]") }
  let calls = args.count > 3 ? Int(args[3]) ?? 1_000_000 : 1_000_000
  let cycles = args.count > 4 ? Int(args[4]) ?? 100 : 100
  MainActor.assumeIsolated { bench(args[2], calls: calls, cycles: cycles) }
case "crash":
  guard args.count >= 6 else { fail("usage: cordis-bench crash <dylib> <marker> <service> <method> [recover]") }
  MainActor.assumeIsolated {
    crash(args[2], marker: args[3], service: args[4], method: args[5], recover: args.count > 6 && args[6] == "recover")
  }
default:
  fail("usage: cordis-bench bench|crash ...")
}
