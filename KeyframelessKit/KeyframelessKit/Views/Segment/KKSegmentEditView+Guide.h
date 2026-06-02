/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KKSegmentEditView.h>

NS_ASSUME_NONNULL_BEGIN

/// Guide-only surface on the segment editor: screen rect of a specific
/// curve pill, so a Joyride step can cutout (e.g.) the Spring pill.
@interface KKSegmentEditView (Guide)

/// Screen rect of the curve pill at `curveType` (matches the editor's
/// curveType enum: Linear=0, EaseIn=1, EaseOut=2, EaseInOut=3, Elastic=4,
/// Bounce=5 for transitions; KKHoldEffect values for holds). NSZeroRect if
/// not laid out or `curveType` is out of range.
- (NSRect)guideCurvePillScreenRectForCurve:(NSInteger)curveType;

@end

NS_ASSUME_NONNULL_END
