/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class KKJoyrideController, KKJoyrideStep;

/// One reusable "drag a control onto a glowing target" guide step — the
/// OSC-Basics flow, factored out so any plugin/OSC builds it from a few
/// blocks instead of re-implementing the press/target/message/snap/advance
/// wiring.
///
/// Flow: the control glows with `clickMessage` and no target. If
/// `dragMessage` is non-nil, the amber target stays hidden until the user
/// presses; on press it appears and the message swaps in place (same step —
/// the press flows straight into the drag). If `dragMessage` is nil the
/// target shows immediately and the message never changes. The gesture is
/// captured (clicks/drags can't pass the XPC overlay) and fed to the
/// `begin`/`dragTo`/`end` blocks; the step advances — or completes, if it's
/// the last step — when `hitOnRelease` is YES at mouse-up.
///
/// Control-specific behaviour (which control, how a screen point maps to a
/// value, what "on target" means) lives entirely in the blocks; everything
/// generic (press latch, pill gating, message swap, spotlight refresh,
/// advance/dismiss gate keyed to `stepIndex`) lives here. Works for the
/// in-viewer OSC handle, a mini-canvas point/crop handle, a popover slider,
/// etc.
@interface KKJoyrideDragStep : NSObject

+ (KKJoyrideStep *)stepForGuide:(KKJoyrideController *)guide
                        atIndex:(NSInteger)stepIndex
                         isLast:(BOOL)isLast
                   clickMessage:(NSString *)clickMessage
                    dragMessage:(nullable NSString *)dragMessage
                       circular:(BOOL)circular
                       spotRect:(NSRect (^)(void))spotRect
                     targetRect:(NSRect (^)(void))targetRect
                          begin:(void (^)(NSPoint screenPoint))begin
                         dragTo:(void (^)(NSPoint screenPoint))dragTo
                            end:(void (^)(void))end
                   hitOnRelease:(BOOL (^)(NSPoint screenPoint))hitOnRelease;

@end

/// Screen-space magnetic snap: `targetRect`'s centre when `p` is within
/// `tolerance` points of it, else `p`. The common case for handle/dot drags.
extern NSPoint KKJoyrideSnapToTarget(NSPoint p, NSRect targetRect,
                                     CGFloat tolerance);

NS_ASSUME_NONNULL_END
