/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KKSegmentEditView.h>
#import <KeyframelessKit/KKTimelineAdvancedView.h>
#import <KeyframelessKit/KKTimelineBasicView.h>
#import <KeyframelessKit/KKTimelineLanesView.h>

NS_ASSUME_NONNULL_BEGIN

/// Guide-specific surface on the lanes view: things a Joyride controller
/// needs (screen rects of menu items, access to the embedded basic graph)
/// that don't belong on the everyday API.
@interface KKTimelineLanesView (Guide)

/// Screen rect of the row for `label` inside the currently-open Manage
/// popover ("+" footer dropdown). `NSZeroRect` if no popover is open or no
/// such row exists. Used by joyride steps that cutout a specific item.
- (NSRect)guideManagePopoverItemScreenRectForLabel:(NSString *)label;

/// The embedded basic-mode motion graph (in/out toggles, boundary diamonds,
/// gap clicks). Always present. Exposed so guide code can talk to it without
/// reaching through the private popovers header.
@property(nonatomic, readonly, nullable) KKTimelineBasicView *basicGraph;

/// The embedded advanced-mode sequencer (lane rows, keyposes, intervals).
/// Always present (only visible when active tab = Advanced + ≥1 lane
/// animatable). Exposed for guide steps that target advanced UI.
@property(nonatomic, readonly, nullable) KKTimelineAdvancedView *advancedGraph;

/// Close whatever lane-content popover is currently open (Constants /
/// Boundary / Gap easing) — used by guide steps that need the popover gone
/// before the next step's target becomes interactive. No-op if nothing is
/// open.
- (void)guideCloseContentPopover;

/// Fired after a gap-easing popover opens (settle delay applied so the
/// segment editor is in a window and laid out). The guide grabs the
/// KKSegmentEditView reference to resolve curve-pill rects.
@property(nonatomic, copy, nullable) void (^onGapPopoverWillOpen)
    (NSView *content, KKSegmentEditView *editor);

/// Fired alongside the host's curve-pick callback (so production behaviour
/// is unaffected). Guide-only.
@property(nonatomic, copy, nullable) void (^onGapPopoverCurveChanged)
    (NSInteger curveType);

@end

NS_ASSUME_NONNULL_END
