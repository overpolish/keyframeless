/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKTimingStage.h>

NS_ASSUME_NONNULL_BEGIN

/// Which gap popover is requesting plugin-supplied extra rows.
typedef NS_ENUM(NSInteger, KKGapPopoverPhase) {
  /// Per-interval gap between two adjacent keyposes with DIFFERENT
  /// endpoints (transition; curve/intensity popover, Advanced graph).
  KKGapPopoverPhaseAdvanced = 0,
  /// Basic "In" phase - first interval(s) participating in the In ramp.
  KKGapPopoverPhaseBasicIn = 1,
  /// Basic "Out" phase - last interval(s) participating in the Out ramp.
  KKGapPopoverPhaseBasicOut = 2,
  /// Hold-modulation popover (same-valued endpoints in Advanced, or the
  /// flat middle of Basic). The gap contributes no translational motion
  /// of its own - modulation adds jitter only. Plugin extras that depend
  /// on a heading along a path (e.g. rotate-with-motion) should disable
  /// themselves for this phase.
  KKGapPopoverPhaseHoldModulation = 3,
};

/// Mutator passed to plugin-supplied extra-row blocks. Caller supplies an
/// inner block that mutates a writable interval. The framework dispatches:
///   - Advanced: runs once against the specific interval being edited.
///   - Basic In/Out: runs once per participating lane's phase interval, so
///     a plugin-supplied toggle applies uniformly across the phase.
typedef void (^KKGapIntervalMutator)(
    void (^_Nonnull mutate)(KKInterval *_Nonnull));

/// Reader counterpart to KKGapIntervalMutator. Returns the currently-live
/// interval the popover represents. Bindings in extras rows call this on
/// every popoverDidRefresh to pick up cmd-Z'd state.
typedef KKInterval *_Nullable (^KKGapIntervalReader)(void);

NS_ASSUME_NONNULL_END
