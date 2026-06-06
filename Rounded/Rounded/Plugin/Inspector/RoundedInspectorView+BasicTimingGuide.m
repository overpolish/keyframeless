/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "RoundedInspectorView+Guides.h"
#import "RoundedInspectorView_Private.h"
#import <KeyframelessKit/KKOSCGuideBridge.h>
#import <KeyframelessKit/KKOSCGuideStrategy.h>
#import <KeyframelessKit/KKTimelineInspectorView+Guide.h>
#import <KeyframelessKit/KKTimelineLanesView.h>
#import <KeyframelessKit/KKTimingGuide.h>
#import <KeyframelessKit/KKTimingStage.h>

// Tolerance (radius units) within which the drag snaps to / counts as on the
// glowing target.
static const double kRoundedOSCGuideTargetSnap = 4.0;

// Build a single-keypose Radius timeline at `radius` - the live value the
// interactive OSC drag applies.
static KKTimeline *RoundedGuideTimelineWithRadius(double radius) {
  KKTimeline *tl = [KKTimeline timeline];
  KKLane *radiusLane = [KKLane laneWithLabel:@"Radius"];
  radiusLane.enabled = YES;
  radiusLane.valueType = KKLaneValueTypeFloat;
  radiusLane.componentMin = @[ @0.0 ];
  radiusLane.componentMax = @[ @100.0 ];
  radiusLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0
                                             values:@[ @(radius) ]] ];
  tl.lanes = @[ radiusLane ];
  return tl;
}

static double RoundedGuideCurrentRadius(KKTimelineLanesView *lanes) {
  for (KKLane *lane in lanes.currentTimeline.lanes) {
    if ([lane.label isEqualToString:@"Radius"] && lane.keyposes.count > 0) {
      KKKeyPose *kp = lane.keyposes.firstObject;
      if (kp.values.count > 0)
        return [kp.values.firstObject doubleValue];
    }
  }
  return 20.0;
}

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
  // Mini-viewer guide: four visibly distinct radii (sharp -> fully rounded) so
  // the filmstrip / onion-skin frames are clearly different.
  cfg.miniViewerSeedValues =
      @[ @[ @5.0 ], @[ @35.0 ], @[ @70.0 ], @[ @100.0 ] ];
  cfg.viewerScreenRect = ^NSRect {
    return RoundedSharedOSCGuideBridge().estimatedViewerScreenRect;
  };
  cfg.oscGuideBridge = ^KKOSCGuideBridge * {
    return RoundedSharedOSCGuideBridge();
  };
  // The pill step disables Crop (not Radius), so the keypose mini-canvas (which
  // shows only the featured Radius lane) stays populated for the later steps.
  cfg.oscDisableLabel = @"Crop";
  // The OSC-shape strategy: how a viewer drag maps to the Radius value and back
  // (pure math; the shared guide owns the copy). Radius is scalar, so values
  // box as NSNumber.
  __weak KKTimelineLanesView *weakLanes = self.basicLanesView;
  __weak typeof(self) weakSelf = self;
  cfg.oscGuideStrategy = ^KKOSCGuideStrategy * {
    KKOSCGuideStrategy *s = [[KKOSCGuideStrategy alloc] init];
    s.captureAnchorAtScreen = ^(NSPoint pt) {
      RoundedOSCCaptureGuideAnchorAtScreen(pt);
    };
    s.currentValue = ^id {
      return @(RoundedGuideCurrentRadius(weakLanes));
    };
    s.setLiveValue = ^(id v) {
      RoundedSetGuideRadius([v doubleValue]); // OSC handle tracks the drag
    };
    s.valueForScreenPoint = ^id(NSPoint pt) {
      return @(RoundedGuideRadiusForScreenPoint(pt));
    };
    s.applyValue = ^(id v) {
      double radius = [v doubleValue];
      RoundedSetGuideRadius(radius);
      KKTimelineLanesView *lanes = weakLanes;
      KKTimeline *tl = RoundedGuideTimelineWithRadius(radius);
      [lanes applyTimeline:tl];
      __strong typeof(weakSelf) strong = weakSelf;
      if (strong.onTimelineMutated)
        strong.onTimelineMutated(tl);
    };
    s.valueOnTarget = ^BOOL(id v) {
      return fabs([v doubleValue] - kOSCGuideTargetRadius) <
             kRoundedOSCGuideTargetSnap;
    };
    s.snapValue = ^id(id v) {
      return (fabs([v doubleValue] - kOSCGuideTargetRadius) <
              kRoundedOSCGuideTargetSnap)
                 ? @(kOSCGuideTargetRadius)
                 : v;
    };
    s.requireTargetHit = YES;
    return s;
  };
  return cfg;
}

@end
