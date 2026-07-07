/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "GlowInspectorView+Guides.h"
#import "GlowInspectorView_Private.h"
#import <KeyframelessKit/KKOSCGuideBridge.h>
#import <KeyframelessKit/KKOSCGuideStrategy.h>
#import <KeyframelessKit/KKResizeCursor.h>
#import <KeyframelessKit/KKTimelineInspectorView+Guide.h>
#import <KeyframelessKit/KKTimelineLanesView.h>
#import <KeyframelessKit/KKTimingGuide.h>
#import <KeyframelessKit/KKTimingStage.h>

// Snap tolerance (px) within which the viewer drag counts as / snaps to the
// glowing target.
static const double kGlowOSCGuideTargetSnap = 30.0;

// The Radius lane's current [X, Y] constant from the live guide timeline - the
// value the interactive viewer drag starts from.
static NSArray<NSNumber *> *
GlowGuideCurrentRadiusValues(KKTimelineLanesView *lanes) {
  for (KKLane *lane in lanes.currentTimeline.lanes) {
    if ([lane.label isEqualToString:@"Radius"] && lane.keyposes.count > 0) {
      KKKeyPose *kp = lane.keyposes.firstObject;
      if (kp.values.count >= 1) {
        double x = kp.values[0].doubleValue;
        double y = kp.values.count >= 2 ? kp.values[1].doubleValue : x;
        return @[ @(x), @(y) ];
      }
    }
  }
  return @[ @(kGlowM1Radius), @(kGlowM1Radius) ];
}

// A single-keypose Radius timeline at `values` - the live value the interactive
// OSC drag applies (aspect-linked px, mirroring availableLanes).
static KKTimeline *
GlowGuideTimelineWithRadiusValues(NSArray<NSNumber *> *values) {
  KKTimeline *tl = [KKTimeline timeline];
  KKLane *radiusLane = [KKLane laneWithLabel:@"Radius"];
  radiusLane.enabled = YES;
  radiusLane.valueType = KKLaneValueTypeFloat;
  radiusLane.componentMin = @[ @0.0, @0.0 ];
  radiusLane.componentMax = @[ @500.0, @500.0 ];
  radiusLane.aspectLinkable = YES;
  radiusLane.aspectLinked = YES;
  radiusLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:values] ];
  tl.lanes = @[ radiusLane ];
  return tl;
}

@implementation GlowInspectorView (BasicTimingGuide)

// Glow's timing-guide data: it teaches the single Radius lane. The
// inspector-level bridges (play button, tabs, scrub, play-accent, preview) come
// pre-wired from -makeTimingGuideConfig; Glow supplies the lane label +
// seed/target values, plus the OSC guide bridge/strategy that makes the viewer
// "drag the ring" step interactive (the ring's screen↔value math).
- (KKTimingGuideConfig *)_timingGuideConfig {
  KKTimingGuideConfig *cfg = [self makeTimingGuideConfig];
  cfg.primaryLabel = @"Radius";
  // The only OSC to keep visible while the guide runs.
  cfg.oscKeepLabels = @[ @"Radius" ];
  // Radius is a 2-component [X, Y] float (aspect-linked); the guide drives
  // both.
  cfg.primaryComponentCount = 2;
  // The real Radius lane is aspect-linked, so the ring drag follows the uniform
  // (distance-based) path. Without this the seed lane defaults unlinked and the
  // mini-viewer ring trails the cursor by a constant ~0.707 gap.
  cfg.primaryAspectLinked = YES;
  cfg.primaryValueType = KKLaneValueTypeFloat;
  cfg.primarySeedValues = @[ @100.0, @100.0 ];
  // Seed a second lane (Noise Amount) so the Advanced guide has two lanes - the
  // lane-filter button then appears and its open-the-filter /
  // uncheck-a-property steps make sense. The category keys mirror the real
  // lanes so the filter checklist shows the actual Core/Noise grouping the user
  // sees outside the guide.
  cfg.primaryCategoryKey = @"Core";
  cfg.secondaryLabel = @"Amount";
  cfg.secondaryValueType = KKLaneValueTypeFloat;
  cfg.secondarySeedValues = @[ @50.0 ];
  cfg.secondaryCategoryKey = @"Noise";
  // Destination the constants step drags the radius to, and a different value
  // for the keypose-edit drag so the change is visible.
  cfg.primaryTargetValues = @[ @250.0, @250.0 ];
  cfg.keyposeTargetValues = @[ @400.0, @400.0 ];
  // Mini-viewer guide: four visibly distinct radii (tight -> large halo) so the
  // filmstrip / onion-skin frames are clearly different.
  cfg.miniViewerSeedValues = @[
    @[ @30.0, @30.0 ], @[ @120.0, @120.0 ], @[ @250.0, @250.0 ],
    @[ @420.0, @420.0 ]
  ];

  // Interactive viewer "drag the ring" step: the shared bridge owns the
  // screen↔canvas affine + spotlight; the strategy is the ring-shape math (how
  // a viewer drag maps to the Radius value and back). Glow has a single OSC, so
  // no oscDisableLabel.
  cfg.viewerScreenRect = ^NSRect {
    return GlowSharedOSCGuideBridge().estimatedViewerScreenRect;
  };
  cfg.oscGuideBridge = ^KKOSCGuideBridge * {
    return GlowSharedOSCGuideBridge();
  };
  __weak KKTimelineLanesView *weakLanes = self.basicLanesView;
  __weak typeof(self) weakSelf = self;
  cfg.oscGuideStrategy = ^KKOSCGuideStrategy * {
    KKOSCGuideStrategy *s = [[KKOSCGuideStrategy alloc] init];
    s.captureAnchorAtScreen = ^(NSPoint pt) {
      GlowOSCCaptureGuideAnchorAtScreen(pt);
    };
    s.currentValue = ^id {
      return GlowGuideCurrentRadiusValues(weakLanes);
    };
    s.setLiveValue = ^(id v) {
      GlowSetGuideRadiusValues(v); // the ring tracks the drag
    };
    s.valueForScreenPoint = ^id(NSPoint pt) {
      return GlowGuideRadiusValuesForScreenPoint(pt);
    };
    s.applyValue = ^(id v) {
      GlowSetGuideRadiusValues(v);
      KKTimelineLanesView *lanes = weakLanes;
      KKTimeline *tl = GlowGuideTimelineWithRadiusValues(v);
      [lanes applyTimeline:tl];
      __strong typeof(weakSelf) strong = weakSelf;
      if (strong.onTimelineMutated)
        strong.onTimelineMutated(tl);
    };
    s.valueOnTarget = ^BOOL(id v) {
      NSArray<NSNumber *> *vals = v;
      return vals.count >= 1 &&
             fabs(vals[0].doubleValue - kGlowOSCGuideTargetRadius) <
                 kGlowOSCGuideTargetSnap;
    };
    s.snapValue = ^id(id v) {
      NSArray<NSNumber *> *vals = v;
      if (vals.count >= 1 &&
          fabs(vals[0].doubleValue - kGlowOSCGuideTargetRadius) <
              kGlowOSCGuideTargetSnap)
        return @[ @(kGlowOSCGuideTargetRadius), @(kGlowOSCGuideTargetRadius) ];
      return v;
    };
    // The exact angle-based resize cursor the ring shows on real hover (mirrors
    // KKRingOSC -updateCursorForMouseX:positionY:: atan2 in canvas space about
    // the clip centre), so the guide drag feels identical to a native ring
    // drag.
    s.cursorForScreenPoint = ^NSCursor *(NSPoint pt) {
      KKOSCGuideBridge *b = GlowSharedOSCGuideBridge();
      CGPoint tr = b.currentCanvasTopRight, bl = b.currentCanvasBottomLeft;
      double cx = 0, cy = 0;
      if (!b.geometryValid || ![b screenToCanvas:pt outX:&cx outY:&cy])
        return nil;
      double centerX = (tr.x + bl.x) * 0.5;
      double centerY = (tr.y + bl.y) * 0.5;
      return KKResizeCursorForAngle(atan2(cy - centerY, cx - centerX));
    };
    s.requireTargetHit = YES;
    return s;
  };
  return cfg;
}

@end
