// SPDX-License-Identifier: Apache-2.0

#ifndef RILLIYA_AUDIO_WORKGROUP_H
#define RILLIYA_AUDIO_WORKGROUP_H

#include <stdbool.h>
#include <stdint.h>

/// Audio work intervals are unavailable to Swift: `AudioWorkIntervalCreate` and the
/// `os_workgroup_*` calls are marked `__SWIFT_UNAVAILABLE` and `OS_REFINED_FOR_SWIFT`, so this
/// shim exists only to reach them.
///
/// It also guards two calls that abort the process rather than returning an error:
/// `os_workgroup_interval_start` traps when the calling thread is not a member, and a thread that
/// exits while still joined trips a libdispatch cleanup handler.
typedef struct RilliyaAudioWorkgroup RilliyaAudioWorkgroup;

/// Creates an audio work interval for a thread cadence that is independent of any device callback.
///
/// Returns NULL when the interval cannot be created.
RilliyaAudioWorkgroup *rilliya_audio_workgroup_create(const char *name);

/// Releases the interval. The joining thread must have left first.
void rilliya_audio_workgroup_destroy(RilliyaAudioWorkgroup *workgroup);

/// Joins the calling thread to the workgroup.
///
/// Returns 0 on success, otherwise an `errno` value. A thread may join one workgroup only;
/// joining twice reports `EALREADY`.
int rilliya_audio_workgroup_join(RilliyaAudioWorkgroup *workgroup);

/// Leaves the workgroup from the thread that joined it.
///
/// This must run before that thread exits. Doing nothing when the thread never joined.
void rilliya_audio_workgroup_leave(RilliyaAudioWorkgroup *workgroup);

/// Reports whether the workgroup currently has a joined thread.
bool rilliya_audio_workgroup_is_joined(const RilliyaAudioWorkgroup *workgroup);

/// Opens one work cycle, both timestamps in `mach_absolute_time` units.
///
/// Returns 0 on success, `EPERM` when no thread has joined, otherwise an `errno` value.
int rilliya_audio_workgroup_interval_start(
  RilliyaAudioWorkgroup *workgroup, uint64_t start, uint64_t deadline);

/// Closes the work cycle opened by `rilliya_audio_workgroup_interval_start`.
///
/// Returns 0 on success, `EPERM` when no thread has joined, otherwise an `errno` value.
int rilliya_audio_workgroup_interval_finish(RilliyaAudioWorkgroup *workgroup);

#endif
