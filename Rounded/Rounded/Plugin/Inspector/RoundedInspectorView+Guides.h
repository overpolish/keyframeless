/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "RoundedInspectorView.h"

@class KKTimeline;
@class KKJoyrideGuideHost;

NS_ASSUME_NONNULL_BEGIN

/// Intro / OSC / full-walkthrough Joyride orchestration for the inspector.
/// Split out of RoundedInspectorView.m purely for file size; the public
/// guide entry points (restartIntroGuide, restartOSCGuide,
/// restartFullWalkthroughGuide, oscGuideActive) are declared on the main
/// interface in RoundedInspectorView.h.
@interface RoundedInspectorView (Guides)

/// Clears all lanes, resets the "intro seen" flag, and runs the built-in
/// 3-step onboarding guide. Restores the previous timeline via
/// onTimelineMutated when the guide completes or is skipped.
- (void)restartIntroGuide;

/// Seeds a clean Radius-only timeline and runs the 3-step OSC guide.
/// Restores the previous timeline via onTimelineMutated when the guide
/// completes or is skipped.
- (void)restartOSCGuide;

/// Runs the intro and OSC guides back-to-back on a single controller - the
/// concrete example of one guide crossing inspector → OSC. Starts on a clean
/// timeline; restores the previous one via onTimelineMutated when the guide
/// completes or is skipped.
- (void)restartFullWalkthroughGuide;

/// YES once the OSC guide overlay is on screen (after its zoom-to-fit +
/// settle warm-up). Drives the help button's loading spinner.
@property(nonatomic, readonly) BOOL oscGuideActive;

/// Runs the built-in 3-step inspector onboarding guide on a fresh
/// controller. Called from -viewDidMoveToWindow on first appearance.
- (void)_startIntroGuide;

/// First-appearance autostart: if no lanes exist and the intro hasn't been
/// seen, kick off the intro guide on the next runloop turn. Called from
/// -viewDidMoveToWindow (no-op when there's no window).
- (void)_maybeAutostartIntroGuide;

/// Shared lazy guide host, implemented in the main +Guides.m. The per-guide
/// category files (Constants / BasicTiming / AdvancedTiming) drive it.
- (KKJoyrideGuideHost *)_guideHost;

/// Radius-constant seed timeline for the constants guide; implemented in
/// +Guides.m, used by the +ConstantsGuide category.
- (KKTimeline *)_constantsGuideSeedTimeline;

@end

// Per-guide entry points, each implemented in its own category file
// (RoundedInspectorView+{Constants,BasicTiming,AdvancedTiming}Guide.m).

/// Seeds a clean Radius-constant timeline and runs the 5-step constants guide
/// (Constants button → mini-canvas radius handle → zoom/pan → double-click
/// reset → slider to 80). Restores the previous timeline when done/skipped.
@interface RoundedInspectorView (ConstantsGuide)
- (void)restartConstantsGuide;
@end

/// Seeds an empty timeline and runs the Basic Timing guide (open the
/// animated-property dropdown → add Crop → add Radius → toggle In transition).
/// Restores the previous timeline when done/skipped.
@interface RoundedInspectorView (BasicTimingGuide)
- (void)restartBasicTimingGuide;
@end

/// Seeds a Crop+Radius timeline with start/end keyposes on both, then runs the
/// Advanced Timing guide (Advanced tab → cmd-click Crop lane → value popover →
/// drag a Radius pill). Restores the previous timeline + tab when done.
@interface RoundedInspectorView (AdvancedTimingGuide)
- (void)restartAdvancedTimingGuide;
@end

NS_ASSUME_NONNULL_END
