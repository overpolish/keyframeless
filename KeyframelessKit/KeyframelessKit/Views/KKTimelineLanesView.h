/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKTimingStage.h>

NS_ASSUME_NONNULL_BEGIN

/// Plugin-agnostic timeline lane editor. Plugin provides available lane
/// templates (KKLane with valueType/ranges, no keyposes); view handles opt-in
/// pills, hold value editors, and the static-values popover. Used as shared
/// content for both Basic and Advanced inspector tabs.
@interface KKTimelineLanesView : NSView

- (instancetype)initWithAvailableLanes:(NSArray<KKLane *> *)availableLanes
                              timeline:(KKTimeline *)timeline
    NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// Push an updated timeline from outside (e.g. parameterChanged:).
/// Does not fire onTimelineMutated.
- (void)applyTimeline:(KKTimeline *)timeline;

/// YES when at least one available lane is not yet opted in.
@property(nonatomic, readonly) BOOL hasUnoptedLanes;

/// Open the static-values popover anchored to the given view.
- (void)showStaticValuesPopoverFromView:(NSView *)anchor;

/// Fired on every timeline mutation triggered by user interaction.
@property(nonatomic, copy, nullable) void (^onTimelineMutated)
    (KKTimeline *updated);

@end

NS_ASSUME_NONNULL_END
