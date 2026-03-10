/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Cocoa/Cocoa.h>

/// User data marker stamped on CGEvents posted by KKEventForwardingView,
/// allowing callers to distinguish simulated events from real ones.
static const int64_t kSimulatedEventMarker = 0x53494D; // "SIM"

/// Intercepts mouse clicks and re-posts them as CGEvents so the underlying
/// host app view (hidden beneath this overlay) can receive them.
@interface KKEventForwardingView : NSView
@property(nonatomic, copy) void (^onMouseDown)(NSEvent *event);
@end
