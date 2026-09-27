// Host-side helpers that must be plain C: crash attribution runs inside signal handlers.
#ifndef CORDIS_HOST_SUPPORT_H
#define CORDIS_HOST_SUPPORT_H

#include <stdint.h>

// Installs SIGSEGV/SIGBUS/SIGILL/SIGTRAP/SIGABRT/SIGFPE handlers (idempotent; the marker path is
// replaced on every call). When a signal arrives while a plugin is executing, the handler writes
// "<tag>\t<signal>\n" to marker_path, restores the previous handler and re-raises.
void cordis_crash_install(const char *marker_path);

// Sets the tag of the plugin currently executing (NULL = host code) and returns the previous one.
// The tag must stay valid until it is swapped out. Main thread only; async-signal-safe to read.
const char *cordis_crash_swap_current(const char *tag);

// Test hook: returns the current tag.
const char *cordis_crash_current(void);

#endif
