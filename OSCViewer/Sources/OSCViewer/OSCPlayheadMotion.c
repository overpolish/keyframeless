/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#include "OSCPlayheadMotion.h"

#include <math.h>
#include <time.h>

bool OSCPlayheadMotionUpdate(OSCPlayheadMotion *motion, double seconds, double wall) {
  if (!motion || !isfinite(seconds) || !isfinite(wall)) return false;
  if (!motion->seen) {
    // Nothing to compare against yet, and a wall stamp here would read as an
    // advance for the rest of the window: stay stopped until a time changes.
    motion->seen = true;
    motion->seconds = seconds;
    motion->advanceWall = -INFINITY;
    return false;
  }
  if (fabs(seconds - motion->seconds) >= OSCPlayheadStepSeconds) {
    motion->seconds = seconds;
    motion->advanceWall = wall;
  }
  return (wall - motion->advanceWall) < OSCPlayheadIdleSeconds;
}

void OSCPlayheadMotionReset(OSCPlayheadMotion *motion) {
  if (motion) *motion = (OSCPlayheadMotion){0};
}

double OSCPlayheadMotionNow(void) {
  // CLOCK_UPTIME_RAW is monotonic and does not advance while the machine is
  // asleep, so a sleep across two ticks cannot read as a long stall.
  return (double)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9;
}
