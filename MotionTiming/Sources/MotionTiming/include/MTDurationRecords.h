/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#ifndef MT_DURATION_RECORDS_H
#define MT_DURATION_RECORDS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef enum { MTEasingSmooth = 0, MTEasingLinear, MTEasingEaseIn, MTEasingEaseOut } MTEasing;
typedef enum {
    MTAddedMotionNone = 0,
    MTAddedMotionWave,
    MTAddedMotionWiggle,
    MTAddedMotionHandheld
} MTAddedMotion;

/// A scalar key pose and the duration entering that pose.
typedef struct {
    double time;
    double value;
    double duration;
    bool useAvailableTime; // Retains duration while filling the preceding gap.
    uint64_t linkID; // Host-persisted identity; zero means unlinked.
    size_t previousIndex; // Transient association result; SIZE_MAX means unmatched.
    bool matchEndpoints; // Shared lane setting, repeated so legacy array blobs remain valid.
    MTEasing easing; // Incoming transition; zero preserves legacy smoothstep.
    MTAddedMotion addedMotion; // Outgoing modulation owned by this keypose.
} MTDurationRecord;

/// Associates current records with previous records and carries durations and timing mode
/// through exact-time matches, unambiguous value matches, and finally
/// chronological matches. New records receive defaultDuration and fixed-duration mode. Times and
/// values must be finite, times must be sorted strictly increasingly, and
/// durations/defaultDuration must be finite and nonnegative. Empty inputs are
/// valid. Output is unchanged when validation or allocation fails.
///
/// Value matching is intentionally limited to unique values among the
/// unmatched records. Crossing records with identical values have no stable
/// host identity and are therefore inherently ambiguous.
bool MTReconcileDurations(const MTDurationRecord *previous,
                          size_t previousCount,
                          const MTDurationRecord *current,
                          size_t currentCount,
                          double defaultDuration,
                          MTDurationRecord *output);

#ifdef __cplusplus
}
#endif
#endif
