/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs a local NSEvent monitor while attached to a window that
/// intercepts spacebar keydowns and fires `onTogglePlayback`. Used by the
/// sequencer's detached "timing remote" window so spacebar toggles host
/// playback instead of being forwarded as a beep.
@interface KKRemoteWindowKeyHandlerView : NSView
@property(nonatomic, copy, nullable) void (^onTogglePlayback)(void);
@property(nonatomic, strong, nullable) id eventMonitor;
@end

NS_ASSUME_NONNULL_END
