/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "MeshInspectorView.h"

@class KKTimingGuideConfig;

NS_ASSUME_NONNULL_BEGIN

/// Mesh's timing-guide config (the plugin data the shared KKTimingGuide
/// runs on). The walkthrough choreography + lifecycle all live in the kit
/// (`KKTimelineInspectorView (Guide)` + `KKTimingGuide`); this category only
/// supplies the per-plugin labels / seed values / viewer rect. Installed as the
/// inspector's `timingGuideConfigProvider` in -init.
@interface MeshInspectorView (BasicTimingGuide)
- (KKTimingGuideConfig *)_timingGuideConfig;
@end

NS_ASSUME_NONNULL_END
