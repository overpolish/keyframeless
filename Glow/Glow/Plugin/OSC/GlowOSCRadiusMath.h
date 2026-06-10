/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

@class KKTimeline;

NS_ASSUME_NONNULL_BEGIN

/// Push the timeline into the framework's process-snapshot store, read by the
/// OSC ticks (FxParameterRetrievalAPI is nil there). Set from the plugin's
/// parameterChanged: (via KKHandleTimelineParamChanged) + a cold-boot seed in
/// createView:.
void GlowSetTimelineSnapshot(KKTimeline *_Nullable timeline);
void GlowSetFrameDurationSeconds(double frameDurSec);

/// The Radius lane's [X, Y] value at a visual playhead fraction, falling back
/// to the M1 default when the lane is absent.
NSArray<NSNumber *> *GlowOSCRadiusValuesAtFraction(double frac);

/// Whether the snapshot's Radius lane is aspect-linked (X==Y). Default YES.
BOOL GlowOSCRadiusAspectLinked(void);

/// Whether a lane's on-screen control should show at a fraction (constant
/// lane = always; animated = only on a keypose).
BOOL GlowOSCLaneVisibleAtFraction(NSString *label, double frac);

NS_ASSUME_NONNULL_END
