#include "cordis_host_support.h"

#include <dlfcn.h>
#include <fcntl.h>
#include <mach-o/dyld.h>
#include <mach-o/getsect.h>
#include <mach-o/loader.h>
#include <pthread.h>
#include <setjmp.h>
#include <signal.h>
#include <stdatomic.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <sys/ucontext.h>
#include <unistd.h>

static const int kSignals[] = {SIGSEGV, SIGBUS, SIGILL, SIGTRAP, SIGABRT, SIGFPE};
#define kSignalCount (sizeof(kSignals) / sizeof(kSignals[0]))

static _Atomic(const char *) g_current = NULL;
static pthread_t g_current_thread;  // the thread that set g_current (plugins run on one thread)
static char g_marker[1024];
static struct sigaction g_previous[kSignalCount];
static atomic_bool g_installed = false;

// MARK: - Recovery frames

typedef struct guard_frame {
  sigjmp_buf env;
  struct guard_frame *prev;
  cordis_guard_image image;
  pthread_t thread;
} guard_frame;

static guard_frame *volatile g_top = NULL;
static atomic_bool g_enabled = true;
static volatile uintptr_t g_last_pc = 0;
// libsystem_platform's __TEXT: memcpy/memmove/memset/strlen and friends. They take no locks, so a
// fault inside one called directly by plugin code is as recoverable as a fault in the plugin.
static cordis_guard_image g_platform = {0, 0};

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

static bool in_image(cordis_guard_image im, uintptr_t a) { return a >= im.lo && a < im.hi; }

static void fault_registers(void *uctx, uintptr_t *pc, uintptr_t *lr) {
  *pc = 0;
  *lr = 0;
  ucontext_t *uc = (ucontext_t *)uctx;
  if (!uc || !uc->uc_mcontext) return;
#if defined(__arm64__)
  *pc = (uintptr_t)__darwin_arm_thread_state64_get_pc(uc->uc_mcontext->__ss);
  *lr = (uintptr_t)__darwin_arm_thread_state64_get_lr(uc->uc_mcontext->__ss);
#elif defined(__x86_64__)
  *pc = (uintptr_t)uc->uc_mcontext->__ss.__rip;
#endif
}

/// Jumps back into the innermost guard when this fault is the plugin's own (see the header).
static void try_recover(int sig, void *uctx) {
  if (!atomic_load_explicit(&g_enabled, memory_order_relaxed)) return;
  guard_frame *f = g_top;
  if (!f || !pthread_equal(f->thread, pthread_self()) || f->image.hi == 0) return;
  uintptr_t pc, lr;
  fault_registers(uctx, &pc, &lr);
  bool own = in_image(f->image, pc) || (in_image(g_platform, pc) && in_image(f->image, lr));
  if (!own) return;
  g_last_pc = pc;
  siglongjmp(f->env, sig);
}

static void on_crash(int sig, siginfo_t *info, void *uctx) {
  (void)info;
  try_recover(sig, uctx);
  const char *tag = atomic_load_explicit(&g_current, memory_order_relaxed);
  // Attribute only a fault on the thread running the plugin (a background thread crashing while
  // a plugin runs on the main thread is not that plugin's fault).
  if (tag && g_marker[0] && pthread_equal(g_current_thread, pthread_self())) {
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

  g_platform = cordis_guard_image_of((const void *)&memmove);

  // Alternate stack so stack overflows in plugin code are still attributed (and recovered).
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
  if (tag) g_current_thread = pthread_self();
  return atomic_exchange_explicit(&g_current, tag, memory_order_relaxed);
}

const char *cordis_crash_current(void) { return atomic_load_explicit(&g_current, memory_order_relaxed); }

// MARK: - Guards

void cordis_guard_set_enabled(bool enabled) { atomic_store(&g_enabled, enabled); }
bool cordis_guard_enabled(void) { return atomic_load(&g_enabled); }
uintptr_t cordis_guard_last_pc(void) { return g_last_pc; }

cordis_guard_image cordis_guard_image_of(const void *address) {
  cordis_guard_image im = {0, 0};
  Dl_info info;
  if (!address || dladdr(address, &info) == 0 || !info.dli_fbase) return im;
  const struct mach_header_64 *mh = (const struct mach_header_64 *)info.dli_fbase;
  if (mh->magic != MH_MAGIC_64) return im;
  unsigned long size = 0;
  uint8_t *text = getsegmentdata(mh, "__TEXT", &size);
  if (!text || size == 0) return im;
  im.lo = (uintptr_t)text;
  im.hi = (uintptr_t)text + size;
  return im;
}

// Each guard: push a frame, set the crash tag, call, pop. Locals read after a jump are set before
// sigsetjmp and never modified afterwards, so they need no volatile.
#define GUARD_BEGIN                                       \
  guard_frame f;                                          \
  f.prev = g_top;                                         \
  f.image = image;                                        \
  f.thread = pthread_self();                              \
  const char *previous_tag = cordis_crash_swap_current(tag); \
  int sig = sigsetjmp(f.env, 1);                          \
  if (sig == 0) {                                         \
    g_top = &f;

#define GUARD_END                          \
  }                                        \
  g_top = f.prev;                          \
  (void)cordis_crash_swap_current(previous_tag); \
  return sig;

int cordis_guard_service(cordis_service_fn fn, void *userdata, cordis_bytes method, cordis_bytes args,
                         const char *tag, cordis_guard_image image, cordis_bytes *result) {
  result->data = NULL;
  result->len = 0;
  GUARD_BEGIN
  *result = fn(userdata, method, args);
  GUARD_END
}

int cordis_guard_event(cordis_event_fn fn, void *userdata, cordis_bytes payload, const char *tag,
                       cordis_guard_image image) {
  GUARD_BEGIN
  fn(userdata, payload);
  GUARD_END
}

int cordis_guard_apply(cordis_plugin_apply_fn fn, const cordis_host *host, const char *tag,
                       cordis_guard_image image, int32_t *rc) {
  *rc = -1;
  GUARD_BEGIN
  *rc = fn(host);
  GUARD_END
}

int cordis_guard_dispose(cordis_plugin_dispose_fn fn, const char *tag, cordis_guard_image image) {
  GUARD_BEGIN
  fn();
  GUARD_END
}

int cordis_guard_manifest(cordis_plugin_manifest_fn fn, const char *tag, cordis_guard_image image,
                          cordis_bytes *result) {
  result->data = NULL;
  result->len = 0;
  GUARD_BEGIN
  *result = fn();
  GUARD_END
}
