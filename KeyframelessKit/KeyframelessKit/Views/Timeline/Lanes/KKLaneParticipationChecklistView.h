/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "KKLaneChecklistView.h"

NS_ASSUME_NONNULL_BEGIN

/// The gap popover's "Applies to" checklist - the Animated dropdown's content
/// (category pill nav + search + one checkable row per property) embedded
/// inside the curve / modulation popover instead of a horizontal pill bar, so
/// it scales to many properties and groups without a horizontal-scroll bar.
/// Unlike the lane filter there is no solo / warning tint: checked = the
/// property animates in this phase (a real, non-destructive `holdsFlat`
/// toggle). Hosted embedded (fixed width + capped internal scroll) via
/// `_KKLaneChecklistView`.
@interface KKLaneParticipationChecklistView : _KKLaneChecklistView

- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes
                checkedLabels:(NSSet<NSString *> *)checked
                        width:(CGFloat)width
                maxBodyHeight:(CGFloat)maxBodyHeight;

@property(nonatomic, copy, nullable) void (^onToggled)
    (NSString *label, BOOL isOn);

/// Refresh every row's checkbox after the model mutates externally (cmd-Z).
- (void)reloadCheckedLabels:(NSSet<NSString *> *)checked;

/// Replace the row set entirely (multi-owner hosts re-scope to a different
/// layer's lanes when the companion layer list switches selection) and re-fit.
- (void)reloadLanes:(NSArray<KKLane *> *)lanes
      checkedLabels:(NSSet<NSString *> *)checked;

@end

NS_ASSUME_NONNULL_END
