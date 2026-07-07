/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

@class KKTimeline;

NS_ASSUME_NONNULL_BEGIN

/// Pure timeline transforms backing the presets feature (no view state). All
/// take the live clip duration explicitly so they stay testable and reusable.

/// Remap the preset's full time extent onto `[start, end]` (normalized by its
/// own min/max, so it fits regardless of authoring duration), then pin locked
/// transition gaps to their seconds for `clipDurSec` while flexible holds
/// absorb the remainder. `clipDurSec <= 0` (or nothing locked) skips the
/// rebalance.
FOUNDATION_EXPORT KKTimeline *KKPresetTimelineRemapped(KKTimeline *preset,
                                                       double start, double end,
                                                       double clipDurSec);

/// Merge the preset into `current` so its (remapped + rebalanced) animation
/// occupies `[p, end]`: each lane keeps its keyposes before `p`, then appends
/// the preset's. Only the preset's ENABLED lanes merge (disabled/unused lanes
/// leave the current lane untouched); preset-only lanes are added; redundant
/// flat-hold keyposes at the seam are collapsed. `current` nil = remap only.
FOUNDATION_EXPORT KKTimeline *
KKPresetTimelineMergedAtFraction(KKTimeline *preset,
                                 KKTimeline *_Nullable current, double p,
                                 double end, double clipDurSec);

/// Capture each MOVING gap's real duration (seconds) as `lockedSeconds` and
/// leave flat/hold gaps flexible (0) - so a saved preset reproduces its
/// transition feel at a fixed wall-clock length while holds stretch.
/// `clipDurSec <= 0` returns the timeline unchanged.
FOUNDATION_EXPORT KKTimeline *KKPresetTimelineAutoLocked(KKTimeline *timeline,
                                                         double clipDurSec);

NS_ASSUME_NONNULL_END
