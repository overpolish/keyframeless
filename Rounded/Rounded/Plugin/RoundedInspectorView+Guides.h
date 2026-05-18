/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "RoundedInspectorView.h"

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

/// Runs the intro and OSC guides back-to-back on a single controller — the
/// concrete example of one guide crossing inspector → OSC. Starts on a clean
/// timeline; restores the previous one via onTimelineMutated when the guide
/// completes or is skipped.
- (void)restartFullWalkthroughGuide;

/// Seeds a clean Radius-constant timeline and runs the 5-step constants
/// guide (Constants button → mini-canvas radius handle → zoom/pan →
/// double-click reset → slider to 80). Restores the previous timeline via
/// onTimelineMutated when the guide completes or is skipped.
- (void)restartConstantsGuide;

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

@end

NS_ASSUME_NONNULL_END
