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

/// "Detach window" button: accent while `on` (a detached window exists).
@interface KKDetachButton : NSView
@property(nonatomic) BOOL on;
@property(nonatomic, copy, nullable) void (^onTapped)(void);
@end

NS_ASSUME_NONNULL_END
