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

/// The current timeline state. KVO-unsafe; read only from the main queue.
@property(nonatomic, readonly) KKTimeline *currentTimeline;

/// YES when at least one available lane is not yet opted in.
@property(nonatomic, readonly) BOOL hasUnoptedLanes;

/// Fired on every timeline mutation triggered by user interaction.
@property(nonatomic, copy, nullable) void (^onTimelineMutated)
    (KKTimeline *updated);

/// The footer row view that contains the "Add properties…" dropdown trigger.
/// Useful as a joyride spotlight target.
@property(nonatomic, readonly) NSView *footerView;

/// Returns the lane row view for the given label, or nil if not opted in.
- (nullable NSView *)laneRowViewForLabel:(NSString *)label;

/// When set, fired (with a short delay for popover-entrance animation) after
/// the manage popover appears. Receives the row view for
/// managePopoverSpotlightLabel (or the first available lane if nil).
@property(nonatomic, copy, nullable) void (^onManagePopoverWillOpen)
    (NSView *spotlightTargetRow);

/// Fired when the manage popover closes for any reason.
@property(nonatomic, copy, nullable) void (^onManagePopoverClosed)(void);

/// Fired when the user opts in a lane via the manage popover toggle.
/// Not fired by external applyTimeline: calls.
@property(nonatomic, copy, nullable) void (^onLaneOptedIn)(NSString *label);

/// Label to spotlight inside the manage popover when onManagePopoverWillOpen
/// fires. Defaults to nil — first available lane alphabetically is used.
@property(nonatomic, copy, nullable) NSString *managePopoverSpotlightLabel;

@end

/// Popover presentation (manage + static-values). Split out of
/// KKTimelineLanesView.m for file size; implemented in
/// KKTimelineLanesView+Popovers.m.
@interface KKTimelineLanesView (Popovers)

/// Open the static-values popover anchored to the given view.
- (void)showStaticValuesPopoverFromView:(NSView *)anchor;

/// Close the manage popover if it is currently open.
- (void)closeManagePopover;

@end

NS_ASSUME_NONNULL_END
