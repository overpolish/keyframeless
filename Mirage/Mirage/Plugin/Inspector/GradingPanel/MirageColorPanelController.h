/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKTimeline.h>
#import <KeyframelessKit/KKTimelineLanesView.h>

NS_ASSUME_NONNULL_BEGIN

/// Shows the Color panel beside an open value-editing popover, for shaders
/// that declare `// #color-surface`.
///
/// Companion to MirageBrowserController and observes the same popover
/// notifications, but its panel is draggable and remembers where the user left
/// it - the browser is a list you glance at, this is a panel you work in while
/// dragging controls in the inspector.
@interface MirageColorPanelController : NSObject

- (instancetype)initWithLanesView:(KKTimelineLanesView *)lanesView;

/// Whether the loaded shader opted in.
///
/// PUSHED on every timeline apply so a recompile that adds or drops the
/// directive takes effect at once. It is not the only source of truth though:
/// the controller also RESOLVES this from the lanes view when a popover opens,
/// because -applyTimeline: has not necessarily run by then - on a cold FCP boot
/// it demonstrably has not, which is why the panel used to miss the first
/// popover after launch.
@property(nonatomic) BOOL surfaceEnabled;

/// Persist a timeline the puck has edited, and bracket a drag so its burst of
/// writes collapses into ONE undo entry. Wired by the inspector to the same chain
/// the mini-viewer handles use.
@property(nonatomic, copy, nullable) void (^onTimelineMutated)(KKTimeline *updated);
@property(nonatomic, copy, nullable) void (^onDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onDragEnd)(void);

/// Re-read the shader's surface spec and re-derive the puck. Called from
/// -applyTimeline: so a recompile updates the ring and labels without the panel
/// having to be closed and reopened.
- (void)timelineDidChange;

/// Tear down observers and hide. Called from the inspector's dealloc, matching
/// how the browser controller is retired.
- (void)invalidate;

@end

NS_ASSUME_NONNULL_END
