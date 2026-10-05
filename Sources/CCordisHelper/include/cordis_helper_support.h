// C helpers for cordis-plugin-helper (the process that hosts an out-of-process plugin).
#ifndef CORDIS_HELPER_SUPPORT_H
#define CORDIS_HELPER_SUPPORT_H

// Enters the "pure computation" sandbox: no file system, no network, no new IPC. Descriptors that
// are already open (the socket to the host, stdout/stderr) keep working. Returns 0 on success,
// else -1 and writes the reason into `error` (up to `size` bytes).
int cordis_helper_sandbox(char *error, int size);

// Physical footprint of process `pid` in bytes (0 when unknown). Used by benchmarks.
unsigned long long cordis_helper_footprint(int pid);

#endif
