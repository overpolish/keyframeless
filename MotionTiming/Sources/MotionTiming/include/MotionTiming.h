/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#ifndef MOTION_TIMING_H
#define MOTION_TIMING_H
#include <stdbool.h>
#include <stddef.h>
#include "MTDurationRecords.h"
#ifdef __cplusplus
extern "C" {
#endif

/// All components of a destination share arrival and transition duration.
/// Times are seconds on the caller's clip-relative clock, never frame indices.
/// The first destination is the initial state; its duration is ignored.
typedef struct {
    double arrival;
    double duration;
    const double *values;
    MTEasing easing;
    MTAddedMotion addedMotion; // Modulation owned by this destination's outgoing interval.
    const double *modulationMins; // Optional per-component zero-centred range.
    const double *modulationMaxs;
    size_t modulationRangeCount;
} MTDestination;

/// Holds the preceding destination until arrival-duration, then smoothly
/// transitions. Durations longer than the gap are capped to that gap; zero
/// duration cuts at arrival. Before/after the sequence, endpoint values hold.
/// Destinations must have finite, nonnegative times/durations, strictly
/// increasing arrivals, and componentCount finite values each. Returns false
/// for invalid input and leaves output untouched. No allocation or host state.
/// Outgoing addedMotion uses fixed legacy intensity/frequency=1 and deterministic
/// per-component seed variation. Motion covers the full gap; joins touching
/// motion use the legacy 0.42-span Hermite blend and pass through each key exactly.
/// Optional modulation ranges have modulationRangeCount entries in both arrays;
/// they supply quarter-range amplitude when a component value is zero.
/// Output must not overlap the input values.
bool MTSample(const MTDestination *destinations, size_t count,
              size_t componentCount, double seconds, double *output);
#ifdef __cplusplus
}
#endif
#endif
