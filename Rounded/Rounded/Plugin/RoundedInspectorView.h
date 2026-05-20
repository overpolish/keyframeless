/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <KeyframelessKit/KeyframelessKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Rounded's plugin-specific timeline inspector. Subclasses the generic
/// `KKTimelineInspectorView` (which owns the play/loop/reset toolbar, tab
/// bar, content area, detach plumbing and live-push setters) and adds only
/// the Rounded shader + tour hooks: the Radius/Crop mini-canvas renderer,
/// the joyride autostart and per-instance tour configuration.
///
/// The guide entry points (`restartIntroGuide` / `restartOSCGuide` /
/// `restartFullWalkthroughGuide` / `oscGuideActive`) live on the
/// `RoundedInspectorView (Guides)` category — import
/// `RoundedInspectorView+Guides.h` to call them.
@interface RoundedInspectorView : KKTimelineInspectorView

/// Returns the screen rect of THIS effect instance's FCP header row (from
/// its own logo banner), so the OSC guide's final step anchors to the
/// correct effect with multiple instances. Set by the plugin; nil →
/// floating tip.
@property(nonatomic, copy, nullable) NSRect (^effectHeaderRectProvider)(void);

/// When YES, the OSC guide's drag step only advances once the value
/// actually reaches the target; when NO (default) any drag/release
/// advances. Lets different interactive guides enforce completion. Set
/// before `restartOSCGuide`.
@property(nonatomic) BOOL oscGuideRequireTargetHit;

/// Invoked when a guide is fully completed (reached its final step), NOT
/// on skip/dismiss. Set per-guide in its `onStart`; used to persist
/// "completed".
@property(nonatomic, copy, nullable) void (^onGuideCompleted)(void);

@end

NS_ASSUME_NONNULL_END
