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

#pragma mark - Mini-viewer (inside static-values popover)

/// Fires on any zoom or pan of the mini-viewer.
+ (instancetype)miniViewerViewTransformChanged;
/// Fires only when the user pans the mini-viewer (drag / two-finger scroll).
+ (instancetype)miniViewerPanned;
/// Fires only when the user zooms the mini-viewer (wheel / pinch).
+ (instancetype)miniViewerZoomed;
+ (instancetype)miniViewerViewReset;
/// Fires when a mini-viewer double-click is consumed by the delegate (e.g.
/// Magic Move toggling a keypose corner/smooth) rather than resetting the view.
+ (instancetype)miniViewerDoubleClickHandled;
/// Fires when the boundary popover's render-mode pill changes the mode. `mode`
/// is a KKMiniViewerRenderMode (0 = Off, 1 = Filmstrip, 2 = Onion); < 0 = any.
+ (instancetype)renderModeChanged:(NSInteger)mode;
/// Fires when the user clicks an inactive filmstrip cell (navigates to that
/// keypose). Filmstrip mode only.
+ (instancetype)filmstripCellActivated;

/// Fires when the user Option-clicks a handle in the mini-viewer to hide it
/// (the in-canvas equivalent of the viewer opt-click-hide).
+ (instancetype)miniViewerOptHide;

#pragma mark - Inspector

/// Play-button toggle, driven by raw taps (`-notifyPlaybackToggleTapped`), not
/// any poll-inferred play state. Arms on the first tap during the step, fires
/// on the second. Use this for a "click play, then click again to pause" step:
/// the click is unambiguous, so it never flickers under FCP's bursty
/// currentTime the way an inferred play state would inside a guide.
+ (instancetype)playToggleEdge;

/// Fires when the Advanced toolbar's Dynamic display toggle is clicked (either
/// direction - the step just wants the user to try it).
+ (instancetype)dynamicToggled;

#pragma mark - Combinators

/// Arms when `self` fires while the step is active; advances only after
/// `next` later fires (also while the step is still active). Use for the
/// "tap diamond, wait for popover to actually open" pattern where the next
/// step's target rect isn't live until the popover settles.
- (instancetype)thenWaitFor:(KKJoyrideTrigger *)next;

@end

NS_ASSUME_NONNULL_END
