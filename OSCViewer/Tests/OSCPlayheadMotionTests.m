/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "OSCPlayheadMotion.h"
#import <assert.h>
#import <math.h>
#import <stdio.h>

// A viewer nobody is playing: the first tick has nothing to compare against,
// and repeated ticks on the same frame stay stopped however long they run, so
// the controls never blink off while the playhead sits still.
static void stoppedPlayhead(void) {
  OSCPlayheadMotion motion = {0};
  assert(!OSCPlayheadMotionUpdate(&motion, 2.5, 100));
  assert(!OSCPlayheadMotionUpdate(&motion, 2.5, 100.01));
  assert(!OSCPlayheadMotionUpdate(&motion, 2.5, 100.2));
  assert(!OSCPlayheadMotionUpdate(&motion, 2.5, 160));
}

// A parked playhead whose time wobbles below a frame is still parked. Without
// this the state latches: every tick looks like an advance, and the controls
// never come back.
static void subFrameWobble(void) {
  OSCPlayheadMotion motion = {0};
  assert(!OSCPlayheadMotionUpdate(&motion, 2.5, 100));
  for (int tick = 1; tick <= 40; ++tick) {
    double wobble = 2.5 + (tick % 2 ? 1 : -1) * OSCPlayheadStepSeconds * 0.4;
    assert(!OSCPlayheadMotionUpdate(&motion, wobble, 100 + tick * 0.05));
  }
  // A real frame step past the tolerance still registers.
  assert(OSCPlayheadMotionUpdate(&motion, 2.5 + 1 / 30.0, 103));
}

// Pointer activity drops the baseline, so the very next tick reports stopped
// even mid-playback: a control being reached for has to be on screen, and this
// is the recovery path when the host stops ticking after a stop.
static void resetOnActivity(void) {
  OSCPlayheadMotion motion = {0};
  assert(!OSCPlayheadMotionUpdate(&motion, 1.0, 100));
  assert(OSCPlayheadMotionUpdate(&motion, 1.5, 100.5));
  OSCPlayheadMotionReset(&motion);
  assert(!OSCPlayheadMotionUpdate(&motion, 2.0, 100.6));
  assert(!OSCPlayheadMotionUpdate(&motion, 2.0, 100.7));
  // Playback carries on from there: the next advance hides again.
  assert(OSCPlayheadMotionUpdate(&motion, 2.5, 100.8));
}

// Playback: each tick brings a new time, so the playhead reads as moving from
// the first advance onwards.
static void advancingPlayhead(void) {
  OSCPlayheadMotion motion = {0};
  assert(!OSCPlayheadMotionUpdate(&motion, 0, 100));
  for (int frame = 1; frame <= 60; ++frame)
    assert(OSCPlayheadMotionUpdate(&motion, frame / 30.0, 100 + frame / 30.0));
}

// Playback as the host actually ticks it: some frames get a second draw tick
// a few milliseconds later carrying the same time. Traced in Motion at 60fps
// with those pairs 6 to 13ms apart. The window has to ride over them, or the
// controls flash on mid-playback.
static void sameFrameTickPairs(void) {
  OSCPlayheadMotion motion = {0};
  assert(!OSCPlayheadMotionUpdate(&motion, 0, 100));
  for (int frame = 1; frame <= 120; ++frame) {
    double seconds = frame / 60.0;
    double wall = 100 + seconds;
    assert(OSCPlayheadMotionUpdate(&motion, seconds, wall));
    assert(OSCPlayheadMotionUpdate(&motion, seconds, wall + 0.013));
  }
}

// A stall shorter than the window keeps reporting moving: playback ticks are
// not evenly spaced, and a gap of a few frames must not flash the controls on.
// Once the window elapses the playhead reads as stopped again.
static void stallWindow(void) {
  OSCPlayheadMotion motion = {0};
  assert(!OSCPlayheadMotionUpdate(&motion, 0, 100));
  assert(OSCPlayheadMotionUpdate(&motion, 0.5, 100.5));
  assert(OSCPlayheadMotionUpdate(&motion, 0.5, 100.5 + OSCPlayheadIdleSeconds - 0.01));
  assert(!OSCPlayheadMotionUpdate(&motion, 0.5, 100.5 + OSCPlayheadIdleSeconds + 0.01));
  assert(!OSCPlayheadMotionUpdate(&motion, 0.5, 200));
  // Playing again from the same stopped frame moves once more.
  assert(OSCPlayheadMotionUpdate(&motion, 0.6, 200.03));
}

// Any change counts, not just a forward step: a loop wrap and a backwards
// scrub both move the playhead.
static void backwardsJump(void) {
  OSCPlayheadMotion motion = {0};
  assert(!OSCPlayheadMotionUpdate(&motion, 4, 100));
  assert(OSCPlayheadMotionUpdate(&motion, 0, 100.01));
  assert(OSCPlayheadMotionUpdate(&motion, 3.9, 100.02));
}

// An unusable tick time reports stopped and leaves the baseline alone, so a
// missing signal shows the controls instead of hiding them, and the tick after
// it is judged against the last real time rather than against the gap.
static void unusableTime(void) {
  OSCPlayheadMotion motion = {0};
  assert(!OSCPlayheadMotionUpdate(&motion, 7, 100));
  assert(!OSCPlayheadMotionUpdate(&motion, NAN, 100.01));
  assert(!OSCPlayheadMotionUpdate(&motion, INFINITY, 100.02));
  assert(!OSCPlayheadMotionUpdate(&motion, 7, 100.03));
  assert(OSCPlayheadMotionUpdate(&motion, 7.1, 100.04));
  // A garbage wall clock is ignored the same way, state intact.
  assert(!OSCPlayheadMotionUpdate(&motion, 7.2, NAN));
  assert(OSCPlayheadMotionUpdate(&motion, 7.2, 100.05));
}

// The clock the control feeds the update: monotonic and in seconds.
static void monotonicClock(void) {
  double first = OSCPlayheadMotionNow();
  double second = OSCPlayheadMotionNow();
  assert(isfinite(first) && first > 0);
  assert(second >= first && second - first < 1);
}

int main(void) {
  stoppedPlayhead();
  subFrameWobble();
  resetOnActivity();
  advancingPlayhead();
  sameFrameTickPairs();
  stallWindow();
  backwardsJump();
  unusableTime();
  monotonicClock();
  printf("OSCPlayheadMotionTests passed\n");
  return 0;
}
