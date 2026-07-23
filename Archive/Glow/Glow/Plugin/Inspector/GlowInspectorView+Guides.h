/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "GlowInspectorView.h"

@class KKTimingGuideConfig;

NS_ASSUME_NONNULL_BEGIN

/// Glow's timing-guide config (the plugin data the shared KKTimingGuide runs
/// on). The walkthrough choreography + lifecycle live in the kit
/// (`KKTimelineInspectorView (Guide)` + `KKTimingGuide`); this category only
/// supplies the per-plugin label / seed values. Glow has a single Radius lane
/// and no OSC guide bridge, so the viewer-drag step degrades to a narrated
/// pass-through. Installed as the inspector's `timingGuideConfigProvider`.
@interface GlowInspectorView (BasicTimingGuide)
- (KKTimingGuideConfig *)_timingGuideConfig;
@end

NS_ASSUME_NONNULL_END
