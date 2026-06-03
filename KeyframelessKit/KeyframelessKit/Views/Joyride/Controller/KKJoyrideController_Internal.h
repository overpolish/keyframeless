/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Spotlight + tooltip bubble overlay rendered inside KKJoyrideController's
/// floating panel. The controller owns the panel; this view handles all drawing
/// and exposes screen-space rects for the global event monitor to hit-test.
@interface _KKJoyrideOverlayView : NSView

- (instancetype)initWithTargetView:(nullable NSView *)target
                           message:(nullable NSString *)msg
    NS_DESIGNATED_INITIALIZER;
- (instancetype)initWithFrame:(NSRect)frameRect NS_UNAVAILABLE;
- (instancetype)initWithCoder:(NSCoder *)coder NS_UNAVAILABLE;

/// Returns the spotlight rect in the overlay's own coordinate system.
- (NSRect)spotRectInSelf;
/// Spotlight rect (with padding) in screen coordinates. NSZeroRect when no
/// target.
- (NSRect)screenSpotRect;
/// Configure a dynamic screen-space spotlight. Call from the controller only.
- (void)setScreenRectBlock:(nullable NSRect (^)(void))block
                  circular:(BOOL)circular;
/// When set, the cutout is a capsule from the primary spot to this secondary
/// rect.
- (void)setPillToScreenRectBlock:(nullable NSRect (^)(void))block;
/// When YES the global monitor skips XPC forwarding for clicks inside the
/// spotlight (the click passes through to the app below via
/// ignoresMouseEvents).
@property(nonatomic) BOOL spotlightPassThrough;
/// Action (Skip/Done) button rect in screen coordinates. NSZeroRect when
/// hidden.
- (NSRect)screenActionRect;
/// Next button rect in screen coordinates. NSZeroRect when hidden.
- (NSRect)screenNextRect;

/// Tooltip text. Setting it redraws the bubble in place.
@property(nonatomic, copy, nullable) NSString *message;
/// Pin the overlay to its last spotlight and stop the pulse timer so a
/// dismiss fade renders in place rather than jumping to the centred fallback.
- (void)freezeForDismiss;
/// 1-based step index; 0 means no counter.
@property(nonatomic) NSInteger step;
/// Total step count; 0 means no counter. When step == totalSteps the button
/// shows "Done" instead of "Skip".
@property(nonatomic) NSInteger totalSteps;
/// Fired when the user taps Skip (abort) or Done (final step complete).
@property(nonatomic, copy, nullable) void (^onSkip)(void);
/// Fired when the user taps Next. Only shown when this block is non-nil.
@property(nonatomic, copy, nullable) void (^onNext)(void);
/// When NO the dim background is suppressed - only the bubble is drawn.
@property(nonatomic) BOOL drawsBackground;

@end

NS_ASSUME_NONNULL_END
