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

@property(nonatomic, copy, nullable) void (^onToggled)
    (NSInteger compoundIdx, NSInteger segmentIdx, BOOL isOn);
@property(nonatomic, copy, nullable) void (^onDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onDragEnd)(void);

@end

NS_ASSUME_NONNULL_END
