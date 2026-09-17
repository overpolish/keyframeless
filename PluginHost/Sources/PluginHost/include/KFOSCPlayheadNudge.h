/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>

NS_ASSUME_NONNULL_BEGIN

/// Brings the viewer's on-screen controls back after playback or a scrub,
/// without any input from the user.
///
/// The control hides its elements while the playhead moves, but it cannot
/// invalidate itself: `FxOnScreenControlAPI` has no such call, and the host
/// issues no draw tick once the playhead parks, so a hidden control stays
/// hidden until something else makes the host redraw. This is the same
/// situation the inspector's own settings face, and the same fix: write a
/// nonce to the hidden scratch parameter and the host re-renders, which
/// re-invokes `drawOSC`, whose own inference then sees a parked playhead.
///
/// One write per stop, not per tick, and only when at least one control is
/// switched on. The write charges a single undo entry; no parameter type or
/// flag exempts it, so it is wrapped in a named group to keep that entry
/// legible rather than anonymous.
///
/// This rides the inspector clock rather than owning a timer, so it runs while
/// the effect's inspector is present, which is also when the controls are on
/// screen.
@interface KFOSCPlayheadNudge : NSObject
/// `visibilityParameters` are the effect's on-screen control toggles; with
/// none of them on, a redraw would change nothing and the undo entry would be
/// pure noise, so the nudge stays silent.
- (instancetype)initWithManager:(id<PROAPIAccessing>)manager
           visibilityParameters:(nullable NSArray<NSNumber *> *)visibilityParameters;
/// Folds one clock tick in, writing the nonce when the playhead has just
/// settled. The caller owns the action scope.
- (void)tickInAction:(id<FxCustomParameterActionAPI_v4>)action;
/// Testing seam: the same fold against a supplied monotonic clock, in seconds.
/// Returns YES when this tick wrote the nonce.
- (BOOL)tickInAction:(id<FxCustomParameterActionAPI_v4>)action wall:(NSTimeInterval)wall;
@end

NS_ASSUME_NONNULL_END
