/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKJoyrideController.h>
#import <KeyframelessKit/KKJoyrideLanesBinder.h>

@class KKTimeline;
@class KKTimingGuideConfig;

NS_ASSUME_NONNULL_BEGIN

/// Shared, plugin-agnostic walkthrough of the mini viewer (the per-keypose
/// preview embedded in the boundary value popover). Teaches: open it by
/// clicking a keypose, what it shows, zoom/pan/reset, and the three render
/// modes (Off / Filmstrip / Onion) plus filmstrip cell navigation.
///
/// Like `KKTimingGuide`, the choreography + localized copy live here once; a
/// plugin adopts it by handing in a `KKTimingGuideConfig` whose `primaryLabel`
/// names the property to animate and whose `miniViewerSeedValues` give the
/// distinct keypose values (so Filmstrip/Onion show visibly different frames).
/// Runs in the Advanced tab against a seeded multi-keypose lane.
@interface KKMiniViewerGuide : NSObject

/// Seed: the primary lane, animatable, with one keypose per
/// `config.miniViewerSeedValues` entry spread evenly across the clip.
+ (KKTimeline *)seedTimelineForConfig:(KKTimingGuideConfig *)config;

/// Builds the mini-viewer steps and installs their advance bindings on
/// `binder`. Returns the ordered step array to hand back from `buildSteps`.
+ (NSArray<KKJoyrideStep *> *)stepsForGuide:(KKJoyrideController *)guide
                                     binder:(KKJoyrideLanesBinder *)binder
                                     config:(KKTimingGuideConfig *)config;

@end

NS_ASSUME_NONNULL_END
