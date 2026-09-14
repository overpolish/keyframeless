/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "MirageInspectorView.h"

@class KKTimingGuideConfig;

NS_ASSUME_NONNULL_BEGIN

/// Mirage's timing-guide config (the plugin data the shared KKTimingGuide
/// runs on). The walkthrough choreography + lifecycle all live in the kit
/// (`KKTimelineInspectorView (Guide)` + `KKTimingGuide`); this category only
/// supplies the per-plugin labels / seed values / viewer rect. Installed as the
/// inspector's `timingGuideConfigProvider` in -init.
@interface MirageInspectorView (BasicTimingGuide)
- (KKTimingGuideConfig *)_timingGuideConfig;
@end

/// Private selectors implemented by the rack-selection category and consumed
/// by the plugin's guide lifecycle wiring. Kept out of BasicTimingGuide so
/// Clang does not expect that category's implementation to define them.
@interface MirageInspectorView (GuideRackSelectionDeclarations)
- (void)_guidePrepareDefaultRackSelection;
- (void)_guideRestoreRackSelection;
@end

NS_ASSUME_NONNULL_END
