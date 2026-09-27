// cordis-swift plugin ABI, version 1.
// Plugins are Embedded Swift (or C) dylibs. They talk to the host only through this table,
// which lets the host fully unload them with dlclose().
//
// Memory: every cordis_bytes returned across the boundary is malloc'd by the producer and
// free()'d by the receiver. Arguments passed into a call are borrowed for the call's duration.
// Threading: the host calls into plugins on the main thread only.
// Values: payloads are CordisValue binary encodings (see Sources/CordisValue/Codec.swift).

#ifndef CORDIS_H
#define CORDIS_H

#include <stdint.h>
#include <stddef.h>
#include <stdbool.h>

#define CORDIS_ABI_VERSION 1

typedef struct {
  const uint8_t *data;
  size_t len;
} cordis_bytes;

typedef uint64_t cordis_handle;

typedef void (*cordis_event_fn)(void *userdata, cordis_bytes payload);

// Returns a malloc'd encoded Value. Errors are returned as an object {"error": "<message>"}.
typedef cordis_bytes (*cordis_service_fn)(void *userdata, cordis_bytes method, cordis_bytes args);

typedef struct cordis_host {
  uint32_t abi_version;
  void *host_ctx;

  void (*log)(void *host_ctx, int32_t level, cordis_bytes utf8);

  // Call a method on a service provided by the host or another plugin.
  cordis_bytes (*call)(void *host_ctx, cordis_bytes service, cordis_bytes method, cordis_bytes args);

  cordis_handle (*on)(void *host_ctx, cordis_bytes event, cordis_event_fn fn, void *userdata);
  void (*emit)(void *host_ctx, cordis_bytes event, cordis_bytes payload);

  // Provide a service. Plugins that inject it are applied once it exists and disposed when it goes away.
  cordis_handle (*provide)(void *host_ctx, cordis_bytes service, cordis_service_fn fn, void *userdata);

  cordis_handle (*timer)(void *host_ctx, uint64_t milliseconds, bool repeat, cordis_event_fn fn, void *userdata);

  // Dispose one registration early. Everything left is disposed automatically when the plugin unloads.
  void (*dispose)(void *host_ctx, cordis_handle handle);
} cordis_host;

// Exported by every plugin:
//   cordis_bytes cordis_plugin_manifest(void);
//     malloc'd encoded object: {"id": string, "name": string, "version": string,
//                               "inject": [string], "provides": [string]}
//   int32_t cordis_plugin_apply(const cordis_host *host);   // 0 on success
//   void cordis_plugin_dispose(void);                        // release plugin-owned state

typedef cordis_bytes (*cordis_plugin_manifest_fn)(void);
typedef int32_t (*cordis_plugin_apply_fn)(const cordis_host *host);
typedef void (*cordis_plugin_dispose_fn)(void);

#endif
