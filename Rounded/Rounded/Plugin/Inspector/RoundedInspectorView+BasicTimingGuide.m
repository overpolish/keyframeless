/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "RoundedInspectorView+Guides.h"
#import "RoundedInspectorView_Private.h"
#import <KeyframelessKit/KKOSCGuideBridge.h>
#import <KeyframelessKit/KKTimelineInspectorView+Guide.h>
#import <KeyframelessKit/KKTimelineLanesView.h>
#import <KeyframelessKit/KKTimingGuide.h>
#import <KeyframelessKit/KKTimingStage.h>

@implementation RoundedInspectorView (BasicTimingGuide)

// Rounded's timing-guide data: it teaches Radius (with Crop as the second
// Advanced-seed lane). The inspector-level bridges (play button, tabs, scrub,
// play-accent, preview) come pre-wired from -makeTimingGuideConfig; only the
// plugin data + the viewer rect (from Rounded's OSC bridge) are filled here.
// Installed as the inspector's timingGuideConfigProvider in -init.
- (KKTimingGuideConfig *)_timingGuideConfig {
  KKTimingGuideConfig *cfg = [self makeTimingGuideConfig];
  cfg.primaryLabel = @"Radius";
  cfg.secondaryLabel = @"Crop";
  // OSCs to keep visible while this guide runs (the rest are hidden).
  cfg.oscKeepLabels = @[ @"Radius" ];
  cfg.primaryComponentCount = 1;
  cfg.primaryValueType = KKLaneValueTypeFloat;
  cfg.primarySeedValues = @[ @20.0 ];
  // Destination the constants step drags the Radius dot to.
  cfg.primaryTargetValues = @[ @40.0 ];
  // A different value for the keypose-edit drag so the dot visibly moves.
  cfg.keyposeTargetValues = @[ @70.0 ];
  cfg.secondaryValueType = KKLaneValueTypeCrop;
  cfg.secondarySeedValues = @[ @1.0, @1.0, @0.0, @0.0 ];
  cfg.viewerScreenRect = ^NSRect {
    return RoundedSharedOSCGuideBridge().estimatedViewerScreenRect;
  };
  return cfg;
}

@end
