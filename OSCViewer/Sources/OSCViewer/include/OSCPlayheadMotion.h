/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#include <stdbool.h>

// Whether the playhead is moving, inferred from the draw tick's own time.
//
// The host tells an on-screen control nothing about transport state:
// FxOnScreenControlAPI offers coordinate conversion, canvas metrics, the
// backing scale and the cursor, and no invalidate call. So the time handed to
// each draw tick is the only signal, and a redraw cannot be requested to
// correct a stale answer.
//
// A tick whose time differs from the previous one stamps the wall clock, and
// the playhead counts as moving until that stamp goes stale. Any change counts,
// including a backwards jump from a loop wrap or a scrub, so this reports "the
// playhead is moving", not "the host is playing"; the two are not
// distinguishable here.
//
// The window exists because two draw ticks can land inside one frame, where
// the second carries an unchanged time and would otherwise read as a stop and
// flash the controls on mid-playback. Traced in Motion at 60fps, advancing
// ticks step by 16.7ms and those same-frame pairs arrive 6 to 13ms apart, so
// this keeps an order of magnitude of margin over the pairs and still covers
// three frames at 24fps. It is deliberately shorter than the archived playhead
// poller's 0.3s: that value fed a scrubber display, while this one is how long
// a stopped viewer waits for its controls.
//
// The bias suits a control that cannot redraw itself: an unusable time leaves
// the state alone and reports stopped, so missing information shows the
// controls rather than hiding them until the next tick happens to arrive.
static const double OSCPlayheadIdleSeconds = 0.15;

// How far the time must move to count as an advance. A parked playhead does
// not always repeat one exact time: the host redraws the canvas with whatever
// timescale that tick carries, so the same frame can arrive as neighbouring
// rational values, and treating that as motion latches "moving" for good.
// A real step is one frame, 8.3ms at 120fps and more below that, so this sits
// well under a frame and well over the rounding noise of a low timescale.
static const double OSCPlayheadStepSeconds = 0.004;

typedef struct {
  double seconds;     // the last usable tick time
  double advanceWall; // wall clock when that time last changed
  bool seen;          // whether a usable tick has arrived at all
} OSCPlayheadMotion;

// Folds one tick into `motion` and returns whether the playhead is moving.
// `seconds` is the tick's time and `wall` a monotonic clock in seconds; a
// non-finite `seconds` is ignored. The first usable tick establishes the
// baseline and reports stopped, having nothing to compare against.
bool OSCPlayheadMotionUpdate(OSCPlayheadMotion *motion, double seconds, double wall);

// Drops the baseline, so the next tick reports stopped again. Pointer activity
// calls this: the inference is only worth having while nobody is reaching for
// the control, and a control the user is pointing at must be visible whatever
// the state says.
void OSCPlayheadMotionReset(OSCPlayheadMotion *motion);

// The monotonic clock the update expects, in seconds.
double OSCPlayheadMotionNow(void);
