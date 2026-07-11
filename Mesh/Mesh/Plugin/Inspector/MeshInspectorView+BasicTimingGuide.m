/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "MeshInspectorView+Guides.h"
#import "MeshInspectorView_Private.h"
#import <KeyframelessKit/KKOSCGuideBridge.h>
#import <KeyframelessKit/KKOSCGuideStrategy.h>
#import <KeyframelessKit/KKResizeCursor.h>
#import <KeyframelessKit/KKTimelineInspectorView+Guide.h>
#import <KeyframelessKit/KKTimelineLanesView.h>
#import <KeyframelessKit/KKTimingGuide.h>
#import <KeyframelessKit/KKTimingStage.h>

// Object-space tolerance within which the drag snaps to / counts as on the
// glowing target.
static const double kMeshOSCGuideTargetSnap = 0.04;

// Build a single-keypose Origin timeline at object-space (objX, objY) - the
// live value the interactive OSC drag applies.
static KKTimeline *MeshGuideOriginTimeline(double objX, double objY) {
  KKTimeline *tl = [KKTimeline timeline];
  KKLane *lane = [KKLane laneWithLabel:@"Origin"];
  lane.enabled = YES;
  lane.valueType = KKLaneValueTypeGeneric;
  lane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0
                                       values:@[ @(objX), @(objY) ]] ];
  tl.lanes = @[ lane ];
  return tl;
}

static NSPoint MeshGuideCurrentOrigin(KKTimelineLanesView *lanes) {
  for (KKLane *lane in lanes.currentTimeline.lanes) {
    if ([lane.label isEqualToString:@"Origin"] && lane.keyposes.count > 0) {
      KKKeyPose *kp = lane.keyposes.firstObject;
      if (kp.values.count >= 2)
        return NSMakePoint(kp.values[0].doubleValue, kp.values[1].doubleValue);
    }
  }
  return NSMakePoint(0.5, 0.5);
}

static BOOL MeshGuideOriginNearTarget(NSPoint p) {
  CGPoint t = MeshGuideTargetObjectPosition();
  return hypot(p.x - t.x, p.y - t.y) < kMeshOSCGuideTargetSnap;
}

@implementation MeshInspectorView (BasicTimingGuide)

// Mesh's timing-guide data: it teaches the Origin lane (with Scale as the
// second Advanced-seed lane). The inspector-level bridges (play button, tabs,
// scrub, play-accent, preview) come pre-wired from -makeTimingGuideConfig; only
// the plugin data + the viewer rect (from Mesh's OSC bridge) are filled here.
// Installed as the inspector's timingGuideConfigProvider in -init.
- (KKTimingGuideConfig *)_timingGuideConfig {
  KKTimingGuideConfig *cfg = [self makeTimingGuideConfig];
  cfg.primaryLabel = @"Origin";
  // OSCs to keep visible while this guide runs (the rest are hidden).
  cfg.oscKeepLabels = @[ @"Origin" ];
  cfg.primaryComponentCount = 2;
  cfg.primaryValueType = KKLaneValueTypeGeneric;
  cfg.primarySeedValues = @[ @0.5, @0.5 ];
  // Second lane in the Advanced seed, so the per-property timeline + marquee
  // multi-select are taught across two rows. Scale is a non-featured lane (not
  // in the Origin-only keypose mini-viewer), so seeding it can't disturb the
  // featured Origin handle.
  cfg.secondaryLabel = @"Scale";
  cfg.secondaryValueType = KKLaneValueTypeFloat;
  cfg.secondarySeedValues = @[ @100.0, @100.0 ];
  // Destination the constants step drags Origin to (off-centre from the seeded
  // centre, normalized 0..1).
  cfg.primaryTargetValues = @[ @0.7, @0.35 ];
  // A different spot for the keypose-edit drag so the handle visibly moves.
  cfg.keyposeTargetValues = @[ @0.3, @0.62 ];
  // Mini-viewer guide: four corner positions so the pattern visibly moves
  // around the frame across the filmstrip / onion-skin frames.
  cfg.miniViewerSeedValues =
      @[ @[ @0.3, @0.3 ], @[ @0.7, @0.3 ], @[ @0.7, @0.7 ], @[ @0.3, @0.7 ] ];
  cfg.viewerScreenRect = ^NSRect {
    return MeshSharedOSCGuideBridge().estimatedViewerScreenRect;
  };
  cfg.oscGuideBridge = ^KKOSCGuideBridge * {
    return MeshSharedOSCGuideBridge();
  };
  // The pill step disables Scale (not Origin), so the keypose mini-viewer
  // (which shows only the featured Origin lane) stays populated for the later
  // steps.
  cfg.oscDisableLabel = @"Scale";
  // The OSC-shape strategy: how a viewer drag maps to the 2D Origin value and
  // back (pure math; the shared guide owns the copy). Origin is a point, so
  // values box as NSValue.
  __weak KKTimelineLanesView *weakLanes = self.basicLanesView;
  __weak typeof(self) weakSelf = self;
  cfg.oscGuideStrategy = ^KKOSCGuideStrategy * {
    KKOSCGuideStrategy *s = [[KKOSCGuideStrategy alloc] init];
    s.currentValue = ^id {
      return [NSValue valueWithPoint:MeshGuideCurrentOrigin(weakLanes)];
    };
    s.setLiveValue = ^(id v) {
      NSPoint p = [v pointValue];
      MeshSetGuidePosition(p.x, p.y); // OSC handle tracks the drag
    };
    s.valueForScreenPoint = ^id(NSPoint pt) {
      double x = 0.5, y = 0.5;
      MeshGuidePositionForScreenPoint(pt, &x, &y);
      return [NSValue valueWithPoint:NSMakePoint(x, y)];
    };
    s.applyValue = ^(id v) {
      NSPoint p = [v pointValue];
      MeshSetGuidePosition(p.x, p.y);
      KKTimelineLanesView *lanes = weakLanes;
      KKTimeline *tl = MeshGuideOriginTimeline(p.x, p.y);
      [lanes applyTimeline:tl];
      __strong typeof(weakSelf) strong = weakSelf;
      if (strong.onTimelineMutated)
        strong.onTimelineMutated(tl);
    };
    s.valueOnTarget = ^BOOL(id v) {
      return MeshGuideOriginNearTarget([v pointValue]);
    };
    s.snapValue = ^id(id v) {
      NSPoint p = [v pointValue];
      if (MeshGuideOriginNearTarget(p)) {
        CGPoint t = MeshGuideTargetObjectPosition();
        return [NSValue valueWithPoint:NSMakePoint(t.x, t.y)];
      }
      return v;
    };
    // The Origin handle's hover cursor (same as the real OSC's
    // KKPointMoveCursor), presented through the pass-through overlay.
    s.cursorForScreenPoint = ^NSCursor *(NSPoint pt) {
      return KKPointMoveCursor();
    };
    s.requireTargetHit = YES;
    return s;
  };
  return cfg;
}

@end
