/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Variant of `KKPillBar` that renders each input *compound* (an array of
/// labels) as one grouped pill capsule - a single rounded track with
/// internal segments - and packs multiple compounds horizontally with a
/// small gap between. Used for the modulation popover's "Applies to" row
/// where each lane is a compound (its label + per-component sub-pills) so
/// `[Radius] [Crop | W | H | X | Y]` fits in less horizontal space than
/// spelling each segment out as its own pill.
///
/// Overflow is handled with the same horizontal scroll + edge-fade
/// shadows as `KKPillBar`. Toggling fires `onToggled(compoundIdx, segIdx,
/// isOn)`; click-drag sweeps a single compound (matching KKPillBar's
/// gesture model, brackets via onDragBegin/End).
@interface KKCompoundPillBar : NSView

- (instancetype)initWithCompounds:
    (NSArray<NSArray<NSString *> *> *)compoundLabels;

/// Per-compound state arrays (each inner array's count must equal the
/// matching compound's label count).
@property(nonatomic, copy) NSArray<NSArray<NSNumber *> *> *states;

/// Per-compound warning flags (same shape as `states`); a segment that is on
/// AND flagged renders in the warning tint (used to mark soloed lanes).
@property(nonatomic, copy, nullable)
    NSArray<NSArray<NSNumber *> *> *warningStates;

@property(nonatomic, copy, nullable) void (^onToggled)
    (NSInteger compoundIdx, NSInteger segmentIdx, BOOL isOn);
/// Option-click on a segment fires this instead of the normal toggle.
@property(nonatomic, copy, nullable) void (^onOptionToggled)
    (NSInteger compoundIdx, NSInteger segmentIdx);
/// When YES, a drag-sweep started in one capsule continues painting into
/// neighbouring capsules at the same target state. NO (default) keeps each
/// capsule's sweep self-contained, so the "applies to" row is unchanged.
@property(nonatomic) BOOL crossCapsuleSweep;

/// Per-compound index sets of segments excluded from drag-sweep (they still
/// toggle on a plain click). Used to keep group-master segments out of the
/// lane-filter sweep. nil = nothing excluded (default).
@property(nonatomic, copy, nullable) NSArray<NSIndexSet *> *dragExcludedIndices;
@property(nonatomic, copy, nullable) void (^onDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onDragEnd)(void);

/// Screen rect of one compound's pill (for a guide spotlight that targets a
/// single control). NSZeroRect if the index is out of range or off-screen.
- (NSRect)screenRectForCompoundIndex:(NSInteger)compoundIdx;

@end

NS_ASSUME_NONNULL_END
