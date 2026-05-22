/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Plugin-agnostic inspector-toolbar buttons used alongside
/// `KKTimelineBasicView` / Advanced. Each is a tiny icon view that draws an
/// SF Symbol tinted by accent / disabled state and fires a callback on
/// click — host plugins wire the callbacks to playback, loop, constants,
/// detach-window, etc. No timeline-internal state lives here.

/// Shared "reset to default" button: the gray `arrow.counterclockwise`
/// affordance every parameter row uses (lane value rows, the motion-blur
/// popover, etc.). Returns a fresh button each call (a view can't be shared
/// across rows) configured identically — `bordered`=NO, accessory-gray tint,
/// `hidden`=YES initially. The caller wires nothing else: it just shows the
/// button when off-default and lays it out (15×15, trailing-most by
/// convention).
FOUNDATION_EXPORT NSButton *KKResetToDefaultButton(id target, SEL action);

/// Toggle button (accent when `on`). Loop / repeat icon.
@interface KKLoopButton : NSView
@property(nonatomic) BOOL on;
@property(nonatomic, copy, nullable) void (^onToggled)(BOOL isOn);
@end

/// Momentary tap button. Play/pause icon (accent while `playing`).
@interface KKPlayButton : NSView
@property(nonatomic) BOOL playing;
@property(nonatomic, copy, nullable) void (^onTapped)(void);
@end

/// "Reset zoom (fit)" button: accent while `zoomed` is YES, gray at fit.
@interface KKResetZoomButton : NSView
@property(nonatomic) BOOL zoomed;
@property(nonatomic, copy, nullable) void (^onTapped)(void);
@end

/// "Constants" button: icon + label, opens the static-values popover.
@interface KKConstantsButton : NSView
@property(nonatomic, copy, nullable) void (^onTapped)(void);
@end

/// "Clear selection" button: accent while `enabled` (>=1 item selected),
/// gray-dim at 0. Click is no-op when disabled. Used by Advanced where the
/// timeline can be full and there's no empty area to click for deselect.
@interface KKClearSelectionButton : NSView
@property(nonatomic) BOOL enabled;
@property(nonatomic, copy, nullable) void (^onTapped)(void);
@end

/// "Detach window" button: accent while `on` (a detached window exists).
@interface KKDetachButton : NSView
@property(nonatomic) BOOL on;
@property(nonatomic, copy, nullable) void (^onTapped)(void);
@end

/// "Onion-skin" toggle (accent when `on`). Filmstrip icon — turns on the
/// per-keypose filmstrip layout inside the keypose value popover's
/// mini-canvas (host renders each KP's source frame side-by-side).
@interface KKOnionSkinButton : NSView
@property(nonatomic) BOOL on;
@property(nonatomic, copy, nullable) void (^onToggled)(BOOL isOn);
@end

NS_ASSUME_NONNULL_END
