/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// Declarative match against one signal coming through KKJoyrideLanesBinder.
/// Pass to the binder's bind methods as the advance / dismiss condition for a
/// step. Opaque to plugin code; the binder reads the internal type tag via
/// KKJoyrideTrigger_Internal.h.
@interface KKJoyrideTrigger : NSObject

#pragma mark - Lanes view: manage popover

+ (instancetype)managePopoverWillOpen;
+ (instancetype)managePopoverClosed;
/// Fires on opt-in of any lane when label is nil, or only the named lane.
+ (instancetype)laneOptedIn:(nullable NSString *)label;

#pragma mark - Lanes view: static-values (constants) popover

+ (instancetype)staticValuesPopoverWillOpen;
+ (instancetype)staticValuesPopoverClosed;
/// `label` nil = any. Fires once per drag (after `onStaticValueDragEnded`).
+ (instancetype)staticValueDragEndedForLabel:(nullable NSString *)label;
/// Fires when the user types into the constant field for `label`/`component`
/// and the parsed display value lands within `tolerance` of `equals`.
+ (instancetype)constantFieldEditedLabel:(NSString *)label
                                component:(NSInteger)component
                                   equals:(double)target
                                tolerance:(double)tolerance;

#pragma mark - Lanes view: gap popover (basic timing)

+ (instancetype)gapPopoverWillOpen;
/// `curveType` < 0 = any.
+ (instancetype)gapPopoverCurveChanged:(NSInteger)curveType;

#pragma mark - Basic graph (basic timing)

+ (instancetype)phaseToggled:(NSInteger)phase on:(BOOL)on;
/// `idx` < 0 = any.
+ (instancetype)diamondTapped:(NSInteger)idx;
/// `section` < 0 = any.
+ (instancetype)gapTapped:(NSInteger)section;

#pragma mark - Mini-canvas (inside static-values popover)

+ (instancetype)miniCanvasViewTransformChanged;
+ (instancetype)miniCanvasViewReset;

#pragma mark - Inspector

+ (instancetype)playingChanged:(BOOL)playing;
/// Compound: fires when the user starts playback during the active step and
/// then stops it (pause edge). Survives FCP's spurious play=1 pushes within
/// the first 300ms — same gate the hand-rolled play guard used.
+ (instancetype)playPauseEdge;

#pragma mark - Combinators

/// Arms when `self` fires while the step is active; advances only after
/// `next` later fires (also while the step is still active). Use for the
/// "tap diamond, wait for popover to actually open" pattern where the next
/// step's target rect isn't live until the popover settles.
- (instancetype)thenWaitFor:(KKJoyrideTrigger *)next;

@end

NS_ASSUME_NONNULL_END
