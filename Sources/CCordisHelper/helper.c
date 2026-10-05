#include "cordis_helper_support.h"

#include <libproc.h>
#include <sandbox.h>
#include <string.h>
#include <sys/resource.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wdeprecated-declarations"
int cordis_helper_sandbox(char *error, int size) {
  char *err = NULL;
  if (sandbox_init(kSBXProfilePureComputation, SANDBOX_NAMED, &err) == 0) return 0;
  if (error && size > 0) {
    strncpy(error, err ? err : "sandbox_init failed", (size_t)size - 1);
    error[size - 1] = 0;
  }
  if (err) sandbox_free_error(err);
  return -1;
}
#pragma clang diagnostic pop

unsigned long long cordis_helper_footprint(int pid) {
  struct rusage_info_v4 info;
  if (proc_pid_rusage(pid, RUSAGE_INFO_V4, (rusage_info_t *)&info) != 0) return 0;
  return info.ri_phys_footprint;
}
