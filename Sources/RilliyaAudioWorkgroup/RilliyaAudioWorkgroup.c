// SPDX-License-Identifier: Apache-2.0

#include "include/RilliyaAudioWorkgroup.h"

#include <AudioToolbox/AudioWorkInterval.h>
#include <errno.h>
#include <os/workgroup.h>
#include <stdlib.h>
#include <string.h>

struct RilliyaAudioWorkgroup {
  os_workgroup_interval_t interval;
  os_workgroup_join_token_s token;
  bool joined;
};

RilliyaAudioWorkgroup *rilliya_audio_workgroup_create(const char *name) {
  if (name == NULL) {
    return NULL;
  }
  os_workgroup_interval_t interval =
      AudioWorkIntervalCreate(name, OS_CLOCK_MACH_ABSOLUTE_TIME, NULL);
  if (interval == NULL) {
    return NULL;
  }
  RilliyaAudioWorkgroup *workgroup = calloc(1, sizeof(RilliyaAudioWorkgroup));
  if (workgroup == NULL) {
    os_release(interval);
    return NULL;
  }
  workgroup->interval = interval;
  workgroup->joined = false;
  return workgroup;
}

void rilliya_audio_workgroup_destroy(RilliyaAudioWorkgroup *workgroup) {
  if (workgroup == NULL) {
    return;
  }
  rilliya_audio_workgroup_leave(workgroup);
  os_release(workgroup->interval);
  free(workgroup);
}

int rilliya_audio_workgroup_join(RilliyaAudioWorkgroup *workgroup) {
  if (workgroup == NULL) {
    return EINVAL;
  }
  if (workgroup->joined) {
    return EALREADY;
  }
  int result = os_workgroup_join(workgroup->interval, &workgroup->token);
  if (result == 0) {
    workgroup->joined = true;
  }
  return result;
}

void rilliya_audio_workgroup_leave(RilliyaAudioWorkgroup *workgroup) {
  if (workgroup == NULL || !workgroup->joined) {
    return;
  }
  workgroup->joined = false;
  os_workgroup_leave(workgroup->interval, &workgroup->token);
}

bool rilliya_audio_workgroup_is_joined(const RilliyaAudioWorkgroup *workgroup) {
  return workgroup != NULL && workgroup->joined;
}

int rilliya_audio_workgroup_interval_start(
    RilliyaAudioWorkgroup *workgroup, uint64_t start, uint64_t deadline) {
  if (workgroup == NULL) {
    return EINVAL;
  }
  // Starting an interval from a thread that never joined traps instead of reporting an error,
  // so the membership check has to happen here rather than in the kernel.
  if (!workgroup->joined) {
    return EPERM;
  }
  return os_workgroup_interval_start(workgroup->interval, start, deadline, NULL);
}

int rilliya_audio_workgroup_interval_finish(RilliyaAudioWorkgroup *workgroup) {
  if (workgroup == NULL) {
    return EINVAL;
  }
  if (!workgroup->joined) {
    return EPERM;
  }
  return os_workgroup_interval_finish(workgroup->interval, NULL);
}
