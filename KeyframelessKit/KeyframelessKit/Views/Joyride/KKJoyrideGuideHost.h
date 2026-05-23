/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKJoyrideController.h>
#import <KeyframelessKit/KKJoyrideLanesBinder.h>

@class KKTimeline;
@class KKTimelineLanesView;

NS_ASSUME_NONNULL_BEGIN

/// One-per-guide owner that absorbs the boilerplate around running a guide
/// against a KKTimelineLanesView:
///   - allocs the KKJoyrideController + KKJoyrideLanesBinder per run,
///   - saves the inspector's pre-guide timeline + applies a seed,
///   - on completion fires `onGuideCompleted` when the final step was
///     reached, tears down the binder, restores the saved timeline, and
///     releases the controller on the next runloop tick (avoiding the
///     "deallocate from inside onComplete" trap),
///   - exposes the live controller + binder mid-run so the steps builder
///     can wire bindings against them.
///
/// Plugins set the timeline accessor / mutator / completion blocks once on
/// the host (typically in `-viewDidMoveToWindow`), then call `-runWithSeed:`
/// per guide. `-dismiss` ends any in-flight guide (e.g. when the inspector
/// view goes away).
@interface KKJoyrideGuideHost : NSObject

- (instancetype)initWithHostView:(NSView *)hostView
                       lanesView:(KKTimelineLanesView *)lanesView
    NS_DESIGNATED_INITIALIZER;
- (instancetype)init NS_UNAVAILABLE;

#pragma mark - Configuration (set once)

/// Returns the current timeline so the host can stash it before applying a
/// seed. Required.
@property(nonatomic, copy, nullable) KKTimeline * (^currentTimelineProvider)
    (void);

/// Applies a timeline to the inspector AND fires the inspector's own
/// `onTimelineMutated` host bridge. Called for the seed and for the saved
/// restore. Required.
@property(nonatomic, copy, nullable) void (^timelineApplier)
    (KKTimeline *timeline);

/// Fired (if non-nil) when a run ends with the final step reached — i.e. the
/// user completed the guide rather than skipping. Plugin uses this to mark
/// the guide seen, advance an onboarding tally, etc.
@property(nonatomic, copy, nullable) void (^onGuideCompleted)(void);

#pragma mark - Per-run config

/// Applied to the controller each `-runWithSeed:` call. Default NO.
@property(nonatomic) BOOL forwardsGestures;

#pragma mark - Running

/// Dismisses any in-flight run, then starts a new one:
///   1. saves the current timeline + applies the seed (via -prepareWithSeed:),
///   2. allocs a fresh controller + binder, calls `buildSteps` with them,
///   3. starts the controller with the returned steps.
/// On completion (or dismiss), the binder is torn down, the saved timeline
/// is restored via `timelineApplier`, and the controller is released on the
/// next runloop tick.
///
/// `extraOnComplete` (optional) runs synchronously inside the onComplete
/// block, after the "did-complete" detection and before binder teardown —
/// use it for guide-specific cleanup (e.g. resetting a plugin OSC step).
///
/// Save+restore is opt-in via `seedBlock`: nil = "don't touch the current
/// timeline" (the autostart pattern, where the user is supposed to keep
/// any state they create during the guide).
- (void)runWithSeed:(nullable KKTimeline * (^)(void))seedBlock
         buildSteps:(NSArray<KKJoyrideStep *> * (^)(
                        KKJoyrideController *guide,
                        KKJoyrideLanesBinder *binder))buildSteps
    extraOnComplete:(nullable void (^)(void))extraOnComplete;

/// Save current timeline + apply seed, without starting a guide. Use when
/// the guide needs an async warm-up between seed and start (e.g. an
/// AppleScript zoom-to-fit that must run before the overlay exists, so the
/// host-app focus steal happens before the overlay can be pulled behind).
/// Call -runBuildSteps:extraOnComplete: when the warm-up settles.
- (void)prepareWithSeed:(KKTimeline *)seed;

/// Allocs the controller + binder, calls `buildSteps`, starts the guide.
/// On completion the saved timeline (if any) is restored. Pair with
/// `-prepareWithSeed:` after an async warm-up; otherwise prefer
/// `-runWithSeed:buildSteps:extraOnComplete:` which does both in one call.
- (void)runBuildSteps:(NSArray<KKJoyrideStep *> * (^)(
                          KKJoyrideController *guide,
                          KKJoyrideLanesBinder *binder))buildSteps
      extraOnComplete:(nullable void (^)(void))extraOnComplete;

/// In-viewer OSC guides: applies `seed`, then runs the host-viewer
/// zoom-to-fit warm-up before starting the guide. The zoom (`+[KKHostInfo
/// zoomHostViewerToFit]`, an AppleScript that steals host-app focus) runs on a
/// background queue so the focus steal happens BEFORE the overlay exists;
/// after the host has had time to resize the viewer, the seed is re-applied to
/// force a re-render at the final geometry, then `buildSteps`/`extraOnComplete`
/// run via -runBuildSteps:. Encapsulates the settle timing every OSC guide
/// needs. Set any plugin OSC state (step index, guide-active flag) before
/// calling.
- (void)runOSCGuideWithSeed:(KKTimeline *)seed
                 buildSteps:(NSArray<KKJoyrideStep *> * (^)(
                                KKJoyrideController *guide,
                                KKJoyrideLanesBinder *binder))buildSteps
            extraOnComplete:(nullable void (^)(void))extraOnComplete;

/// "Show once" autostart: does nothing unless the host view is in a window,
/// `precondition` (if non-nil) returns YES, and `seenKey` is not yet set in
/// NSUserDefaults; otherwise defers to the main queue, re-checks the same
/// conditions, and calls `start`. The caller owns setting `seenKey` (typically
/// in the guide's completion handler), so this only reads it.
- (void)autostartOnceWithSeenKey:(NSString *)seenKey
                    precondition:(nullable BOOL (^)(void))precondition
                           start:(void (^)(void))start;

/// Dismisses the in-flight guide, if any. Triggers the full onComplete
/// path (binder teardown, timeline restore, controller release).
- (void)dismiss;

#pragma mark - Live state (mid-run)

@property(nonatomic, readonly, nullable) KKJoyrideController *currentGuide;
@property(nonatomic, readonly, nullable) KKJoyrideLanesBinder *currentBinder;
@property(nonatomic, readonly) BOOL isActive;

@end

NS_ASSUME_NONNULL_END
