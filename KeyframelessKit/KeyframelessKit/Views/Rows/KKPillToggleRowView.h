/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKPillToggleRowView : NSView

@property(nonatomic, copy) NSArray<NSNumber *> *states;
/// Optional, parallel to `states`. A pill that is on AND flagged here renders
/// in the warning tint instead of the accent (used to mark a soloed lane). nil/
/// empty = no warning pills (every other consumer is unaffected).
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *warningStates;
@property(nonatomic, copy, nullable) void (^onToggled)
    (NSInteger index, BOOL isOn);
/// Option-click on a pill fires this with the pill index INSTEAD of the normal
/// toggle/sweep. nil = option-click behaves like a normal click (so the tab bar
/// and other pills are unchanged). Used by the lane filter to solo a lane.
@property(nonatomic, copy, nullable) void (^onOptionToggled)(NSInteger index);
/// During a drag-sweep, when the cursor leaves this row's pills, the window-
/// space point + the sweep's target state are forwarded here so a container
/// (KKCompoundPillBar) can continue the paint into a neighbouring capsule. nil
/// = the sweep stays within this row (default).
@property(nonatomic, copy, nullable) void (^onSweepToWindowPoint)
    (NSPoint windowPoint, BOOL targetOn);

/// Pills excluded from drag-sweep: still toggle on a plain click, but a drag
/// never starts on them nor paints over them (used to keep a group's master
/// pill out of the lane-filter sweep). nil/empty = every pill sweeps (default).
@property(nonatomic, copy, nullable) NSIndexSet *dragExcludedIndices;

/// Pill index at a point in this view's coordinate space, or NSNotFound. Used
/// by the container to hit-test a forwarded cross-capsule sweep point.
/// (`setState: atIndex:` already sets a pill without firing onToggled.)
- (NSInteger)pillIndexAtViewPoint:(NSPoint)point;
/// Bracket a click/drag-sweep so the consumer coalesces every per-pill
/// `onToggled` in between into a single undo entry. Fires once on mouseDown
/// and once on mouseUp (even for a plain click). Not used in radioMode.
@property(nonatomic, copy, nullable) void (^onDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onDragEnd)(void);
/// When YES, clicking the already-active pill is a no-op (radio group
/// behaviour).
@property(nonatomic) BOOL radioMode;
/// When YES, draws a single track background across all pills so they read as
/// one grouped control (segmented-control style). Active pill renders as an
/// inset highlight inside the track.
@property(nonatomic) BOOL grouped;

- (instancetype)initWithLabels:(NSArray<NSString *> *)labels;
- (instancetype)initWithIcons:(NSArray<NSImage *> *)icons;
- (instancetype)initWithLabels:(NSArray<NSString *> *)labels
                         icons:(NSArray<NSImage *> *)icons;

- (void)setState:(BOOL)on atIndex:(NSInteger)index;

/// Screen rect of the pill at `index`. Used by joyride guides to cutout a
/// single segment of a grouped tab/radio bar. NSZeroRect if out of range or
/// not in a window.
- (NSRect)guidePillScreenRectAtIndex:(NSInteger)index;

@end

NS_ASSUME_NONNULL_END
