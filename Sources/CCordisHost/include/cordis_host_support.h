// Host-side helpers that must be plain C: crash attribution and recovery run inside signal handlers.
#ifndef CORDIS_HOST_SUPPORT_H
#define CORDIS_HOST_SUPPORT_H

#include <stdbool.h>
#include <stdint.h>
#include "cordis.h"

// Installs SIGSEGV/SIGBUS/SIGILL/SIGTRAP/SIGABRT/SIGFPE handlers (idempotent; the marker path is
// replaced on every call). When a signal arrives while a plugin is executing on the thread that
// entered it, and the fault can't be recovered (see cordis_guard_*), the handler writes
// "<tag>\t<signal>\n" to marker_path, restores the previous handler and re-raises.
void cordis_crash_install(const char *marker_path);

// Sets the tag of the plugin currently executing (NULL = host code) and returns the previous one.
// The tag must stay valid until it is swapped out. Main thread only; async-signal-safe to read.
const char *cordis_crash_swap_current(const char *tag);

// Test hook: returns the current tag.
const char *cordis_crash_current(void);

// MARK: - Crash recovery (guarded calls into plugin code)
//
// Every host -> plugin transition goes through one of the cordis_guard_* calls. Each pushes a
// recovery frame (sigsetjmp) naming the plugin image's __TEXT range [lo, hi), sets the crash tag,
// calls the plugin and pops the frame. If a fault signal arrives on the same thread while that
// frame is the innermost one, and recovery is enabled, and the faulting instruction is inside the
// plugin image (or inside a lock-free libsystem_platform routine such as memcpy that the plugin
// called directly), the handler jumps back to the frame and the guard returns the signal number.
// Only plugin frames lie between the frame and the fault (every host re-entry into a plugin pushes
// a new frame, and a fault in host code is never recovered), so no host state is skipped.
// Anything else (a fault in the host, in malloc, on another thread) crashes as before.
//
// Each guard returns 0 when the plugin returned normally, else the signal that was recovered.

typedef struct cordis_guard_image {
  uintptr_t lo;
  uintptr_t hi;
} cordis_guard_image;

// Turns recovery on or off for the whole process (off: every fault crashes, as before).
void cordis_guard_set_enabled(bool enabled);
bool cordis_guard_enabled(void);

// The __TEXT range of the image containing `address` (zeroes if none).
cordis_guard_image cordis_guard_image_of(const void *address);

int cordis_guard_service(cordis_service_fn fn, void *userdata, cordis_bytes method, cordis_bytes args,
                         const char *tag, cordis_guard_image image, cordis_bytes *result);
int cordis_guard_event(cordis_event_fn fn, void *userdata, cordis_bytes payload, const char *tag,
                       cordis_guard_image image);
int cordis_guard_apply(cordis_plugin_apply_fn fn, const cordis_host *host, const char *tag,
                       cordis_guard_image image, int32_t *rc);
int cordis_guard_dispose(cordis_plugin_dispose_fn fn, const char *tag, cordis_guard_image image);
int cordis_guard_manifest(cordis_plugin_manifest_fn fn, const char *tag, cordis_guard_image image,
                          cordis_bytes *result);

// The faulting instruction address of the last recovered fault (diagnostics).
uintptr_t cordis_guard_last_pc(void);

#endif
