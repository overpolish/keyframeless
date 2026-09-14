/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKLaneChecklistView.h"

NS_ASSUME_NONNULL_BEGIN

/// The lane-visibility filter's checkable list - same chrome as the Animated
/// "manage" dropdown (category pill nav + search + one flat row per lane).
/// Checked = visible; option-clicking a row solos it (drawn warning-tinted).
/// Toggling emits `(label, isOn)`; soloing emits the label - both map onto
/// `KKLaneFilterModel`'s per-label mutators. Chrome (search/pill/sizing/
/// `popover`/`fittingHeight`) is inherited from `_KKLaneChecklistView`.
@interface KKLaneFilterChecklistView : _KKLaneChecklistView

- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes
                visibleLabels:(NSSet<NSString *> *)visible
                 soloedLabels:(NSSet<NSString *> *)soloed
                minimumHeight:(CGFloat)minimumHeight;

@property(nonatomic, copy, nullable) void (^onToggled)
    (NSString *label, BOOL isOn);
@property(nonatomic, copy, nullable) void (^onSolo)(NSString *label);

/// Refresh the checkbox + solo state of every row after the model mutates (a
/// solo cascades across rows).
- (void)reloadVisibleLabels:(NSSet<NSString *> *)visible
               soloedLabels:(NSSet<NSString *> *)soloed;

/// Replace the row set entirely (multi-owner hosts re-scope to a different
/// layer's lanes when the companion layer list switches selection) and re-fit.
- (void)reloadLanes:(NSArray<KKLane *> *)lanes
      visibleLabels:(NSSet<NSString *> *)visible
       soloedLabels:(NSSet<NSString *> *)soloed;

@end

NS_ASSUME_NONNULL_END
