#include "cordis_host_support.h"

#include <fcntl.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

static const int kSignals[] = {SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE};
#define kSignalCount (sizeof(kSignals) / sizeof(kSignals[0]))

static _Atomic(const char *) g_current = NULL;
static char g_marker[1024];
static struct sigaction g_previous[kSignalCount];
static atomic_bool g_installed = false;

static size_t cstrlen(const char *s) {
  size_t n = 0;
  while (s[n]) n++;
  return n;
}

static void write_signal_number(int fd, int sig) {
  char buf[12];
  int i = (int)sizeof(buf);
  unsigned v = (unsigned)sig;
  do {
    buf[--i] = (char)('0' + v % 10);
    v /= 10;
  } while (v && i > 0);
  (void)write(fd, buf + i, sizeof(buf) - (size_t)i);
}

static void on_crash(int sig, siginfo_t *info, void *uctx) {
  (void)info;
  (void)uctx;
  const char *tag = atomic_load_explicit(&g_current, memory_order_relaxed);
  if (tag && g_marker[0]) {
    int fd = open(g_marker, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (fd >= 0) {
      (void)write(fd, tag, cstrlen(tag));
      (void)write(fd, "\t", 1);
      write_signal_number(fd, sig);
      (void)write(fd, "\n", 1);
      (void)fsync(fd);
      (void)close(fd);
    }
  }
  // Chain: put the previous disposition back and re-raise so crash reporters still see it.
  for (size_t i = 0; i < kSignalCount; i++) {
    if (kSignals[i] == sig) {
      sigaction(sig, &g_previous[i], NULL);
      break;
    }
  }
  raise(sig);
}

void cordis_crash_install(const char *marker_path) {
  size_t n = marker_path ? strlen(marker_path) : 0;
  if (n >= sizeof(g_marker)) n = sizeof(g_marker) - 1;
  if (n) memcpy(g_marker, marker_path, n);
  g_marker[n] = 0;

  bool expected = false;
  if (!atomic_compare_exchange_strong(&g_installed, &expected, true)) return;

  // Alternate stack so stack overflows in plugin code are still attributed.
  stack_t ss;
  ss.ss_size = 64 * 1024;
  ss.ss_sp = malloc(ss.ss_size);
  ss.ss_flags = 0;
  if (ss.ss_sp) sigaltstack(&ss, NULL);

  for (size_t i = 0; i < kSignalCount; i++) {
    struct sigaction sa;
    memset(&sa, 0, sizeof(sa));
    sa.sa_sigaction = on_crash;
    sa.sa_flags = SA_SIGINFO | SA_ONSTACK;
    sigemptyset(&sa.sa_mask);
    sigaction(kSignals[i], &sa, &g_previous[i]);
  }
}

const char *cordis_crash_swap_current(const char *tag) {
  return atomic_exchange_explicit(&g_current, tag, memory_order_relaxed);
}

const char *cordis_crash_current(void) { return atomic_load_explicit(&g_current, memory_order_relaxed); }
