/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class KKMiniCanvasView;

/// Routes scroll + pinch to a mini-canvas while a guide is running.
///
/// During a guide the overlay panel sits over the popover, so the popover's
/// own scroll/responder zoom-pan path doesn't fire. With the controller's
/// `forwardsGestures` (panel not ignoring events) scroll AND magnify reach
/// app-wide `NSEvent` monitors - this object installs local+global monitors
/// for both and forwards them to the canvas's public
/// `-applyScrollEvent:` / `-applyMagnifyEvent:` while `activeWhen` is YES and
/// the pointer is over the canvas. Plugin-agnostic: any guide over a
/// `KKMiniCanvasView` gets zoom/pan + pinch for free.
///
/// Note: the magnify monitors are the actual pinch carrier - never drop them
/// as "dead"; they only look dead before `forwardsGestures`.
@interface KKMiniCanvasGuideScroll : NSObject

- (instancetype)initWithCanvas:(KKMiniCanvasView *)canvas
                    activeWhen:(BOOL (^)(void))activeWhen
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

/// Install the monitors (idempotent - replaces any existing).
- (void)install;
/// Remove the monitors. Also runs on dealloc.
- (void)teardown;

@end

NS_ASSUME_NONNULL_END
