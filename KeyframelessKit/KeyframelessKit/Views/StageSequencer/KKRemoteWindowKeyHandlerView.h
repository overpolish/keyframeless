/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Installs a local NSEvent monitor while attached to a window that
/// intercepts spacebar keydowns (toggle playback) and Cmd-Z / Cmd-Shift-Z
/// (undo / redo) and forwards them to host callbacks. Used by the
/// sequencer's detached "timing remote" window so these keystrokes hit the
/// host instead of being forwarded as a beep.
@interface KKRemoteWindowKeyHandlerView : NSView
@property(nonatomic, copy, nullable) void (^onTogglePlayback)(void);
@property(nonatomic, copy, nullable) void (^onUndo)(void);
@property(nonatomic, copy, nullable) void (^onRedo)(void);
@property(nonatomic, strong, nullable) id eventMonitor;
@end

NS_ASSUME_NONNULL_END
