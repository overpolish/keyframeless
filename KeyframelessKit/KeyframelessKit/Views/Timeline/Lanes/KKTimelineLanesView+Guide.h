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
/// Boundary / Gap easing) - used by guide steps that need the popover gone
/// before the next step's target becomes interactive. No-op if nothing is
/// open.
- (void)guideCloseContentPopover;

/// Close every lane popover (content / manage / lane-filter) - used at guide
/// start so a popover the user left open isn't sitting over the guide. No-op
/// for any that aren't open.
- (void)guideCloseAllPopovers;

/// The constant popover's remembered category tab (the one it reopens on), or
/// nil. A guide saves this so it can restore the user's tab on completion after
/// forcing a known starting tab to teach category navigation.
- (nullable NSString *)guideRememberedConstantCategory;

/// Screen rect of the render-mode pill's segment for `mode` (Off/Filmstrip/
/// Onion) in the currently-open boundary value popover, or NSZeroRect if no
/// such popover / pill is shown. The mini-viewer guide spotlights this so the
/// user can tap the mode it's teaching.
- (NSRect)guideRenderModePillScreenRectForMode:(KKMiniViewerRenderMode)mode;

/// Fired after a gap-easing popover opens (settle delay applied so the
/// segment editor is in a window and laid out). The guide grabs the
/// KKSegmentEditView reference to resolve curve-pill rects.
@property(nonatomic, copy, nullable) void (^onGapPopoverWillOpen)
    (NSView *content, KKSegmentEditView *editor);

/// Fired alongside the host's curve-pick callback (so production behaviour
/// is unaffected). Guide-only.
@property(nonatomic, copy, nullable) void (^onGapPopoverCurveChanged)
    (NSInteger curveType);

/// The lanes the user has currently hidden via the lane-filter bar. The guide
/// host snapshots this before it takes over the timeline so it can be restored
/// afterwards.
- (NSSet<NSString *> *)guideLaneFilterHiddenLabels;

/// Make every lane visible for the duration of a guide (clears any solo), so a
/// guide's steps aren't fighting a user-hidden lane.
- (void)guideShowAllLanes;

/// Restore a previously-snapshotted hidden set once the guide hands the
/// timeline back. No-op safe if the labels no longer exist.
- (void)guideRestoreLaneFilterHidden:(NSSet<NSString *> *)hidden;

/// Screen rect of the Advanced lane-filter bar (for the guide's spotlight), or
/// `NSZeroRect` if it isn't visible (fewer than two animated lanes, or not on
/// the Advanced tab).
- (NSRect)guideLaneFilterBarScreenRect;

/// Snapshot the user's floating-editor position, size and compact choice, then
/// force a deterministic expanded layout for the guide. Idempotent per run.
- (void)guideBeginEditorLayoutOverride;

/// Restore the exact editor layout captured by
/// `guideBeginEditorLayoutOverride`. Safe when no override is active.
- (void)guideEndEditorLayoutOverride;

@end

NS_ASSUME_NONNULL_END
