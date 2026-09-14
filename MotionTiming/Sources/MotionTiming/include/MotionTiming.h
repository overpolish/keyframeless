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
    bool customMotion; // When true, use motionAmount and motionSpeed below.
    double motionAmount; // Motion intensity; must be finite and nonnegative when custom.
    double motionSpeed; // Motion frequency multiplier; must be finite and positive when custom.
    // Opt in to explicit component options; omitted fields use the defaults below.
    bool customMotionComponents;
    uint32_t motionSeed;
    bool motionLinked;
    uint32_t motionComponentMask; // Low bits select components; zero selects none.
} MTDestination;

/// Holds the preceding destination until arrival-duration, then smoothly
/// transitions. Durations longer than the gap are capped to that gap; zero
/// duration cuts at arrival. Before/after the sequence, endpoint values hold.
/// Destinations must have finite, nonnegative times/durations, strictly
/// increasing arrivals, and componentCount finite values each. Returns false
/// for invalid input and leaves output untouched. No allocation or host state.
/// Outgoing addedMotion uses intensity/frequency=1 unless customMotion is true,
/// in which case motionAmount and motionSpeed control intensity and frequency.
/// Motion runs during the hold, with a 0.42-span Hermite handoff into the
/// plain transition. Available-time transitions have no hold and no added motion.
/// Joins touching motion pass through each key exactly; zero-duration cuts stay exact.
/// Optional modulation ranges have modulationRangeCount entries in both arrays;
/// they supply quarter-range amplitude when a component value is zero.
/// Output must not overlap the input values.
bool MTSample(const MTDestination *destinations, size_t count,
              size_t componentCount, double seconds, double *output);
#ifdef __cplusplus
}
#endif
#endif
