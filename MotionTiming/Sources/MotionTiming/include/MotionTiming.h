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
} MTDestination;

/// Holds the preceding destination until arrival-duration, then smoothly
/// transitions. Durations longer than the gap are capped to that gap; zero
/// duration cuts at arrival. Before/after the sequence, endpoint values hold.
/// Destinations must have finite, nonnegative times/durations, strictly
/// increasing arrivals, and componentCount finite values each. Returns false
/// for invalid input and leaves output untouched. No allocation or host state.
/// Output must not overlap the input values.
bool MTSample(const MTDestination *destinations, size_t count,
              size_t componentCount, double seconds, double *output);
#ifdef __cplusplus
}
#endif
#endif
