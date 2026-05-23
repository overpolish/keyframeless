/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KKTimelineBasicView.h>

NS_ASSUME_NONNULL_BEGIN

/// Guide-specific surface on the basic motion graph: screen-rect lookups and
/// extra user-interaction callbacks that a Joyride controller needs.
@interface KKTimelineBasicView (Guide)

/// Screen rect that encloses both the phase label ("In" / "Out") and its
/// checkbox, suitable as a joyride cutout. phase: 0=In, 1=Out. NSZeroRect
/// if the basic graph isn't on screen or `phase` is out of range.
- (NSRect)guidePhaseToggleScreenRectForPhase:(NSInteger)phase;

/// Fired AFTER the user toggles the In/Out checkbox via the existing
/// internal handler. phase: 0=In, 1=Out. Guide-only — production code uses
/// onTimelineMutated to observe the resulting change.
@property(nonatomic, copy, nullable) void (^onPhaseToggled)
    (NSInteger phase, BOOL on);

/// Screen rect (inset by a few pts) of the boundary diamond at `idx`,
/// where idx is 1=In-start, 2=Hold-start, 3=Hold-end, 4=Out-end. Matches
/// the visible diamond model; returns NSZeroRect if the basic graph isn't
/// laid out or the diamond isn't currently visible (e.g. idx=1 with In
/// disabled).
- (NSRect)guideDiamondScreenRectForIndex:(NSInteger)idx;

/// Fired at the start of the diamond-tap → boundary popover request path
/// (before the host shows the popover). idx matches the diamond model
/// (1-4). Guide-only.
@property(nonatomic, copy, nullable) void (^onDiamondTapped)(NSInteger idx);

/// Screen rect of the section gap (the dashed line between two diamonds
/// where a click opens the easing popover). section: 1=In, 2=Hold, 3=Out.
/// NSZeroRect if not laid out or the section isn't currently visible
/// (e.g. In with In disabled).
- (NSRect)guideGapScreenRectForSection:(NSInteger)section;

/// Fired at the start of _openGapPopoverForSection: (before the popover is
/// requested). section: 1=In, 2=Hold, 3=Out.
@property(nonatomic, copy, nullable) void (^onGapTapped)(NSInteger section);

/// Screen X for a clip time in seconds — for guide steps that draw a glow
/// target at a specific time. NaN if no graph is laid out or
/// `clipDurationSeconds` is unknown.
- (CGFloat)guideScreenXForTimeSeconds:(double)seconds;

/// Screen rect of diamond `idx` (1-4) at a hypothetical time — for a glow
/// target showing where the diamond would land. Only meaningful for the
/// draggable diamonds (2 = Hold-start, 3 = Hold-end). NSZeroRect otherwise.
- (NSRect)guideDiamondScreenRectAtTimeSeconds:(double)seconds
                                   forDiamond:(NSInteger)idx;

/// Drive a diamond drag from a guide's spotlightMouseDown/Dragged/Up. Same
/// path the real mouse drag takes (onDragBegin/Mutated/End fire, undo group
/// brackets correctly). Begin returns NO if `idx` isn't draggable (only 2
/// and 3 are) or the phase is off.
- (BOOL)guideBeginDragDiamondAtIndex:(NSInteger)idx
                       atScreenPoint:(NSPoint)screenPoint;
- (void)guideDragDiamondToScreenPoint:(NSPoint)screenPoint;
- (void)guideEndDiamondDrag;

/// Current time (seconds) of diamond `idx` — for the guide's hit-on-release
/// check. NaN if unknown.
- (double)guideCurrentDiamondTimeSecondsForIndex:(NSInteger)idx;

@end

NS_ASSUME_NONNULL_END
