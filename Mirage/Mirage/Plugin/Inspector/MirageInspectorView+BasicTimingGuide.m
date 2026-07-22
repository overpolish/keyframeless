/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "MirageInspectorView+Guides.h"
#import "MirageInspectorView_Private.h"
#import <KeyframelessKit/KKOSCGuideBridge.h>
#import <KeyframelessKit/KKOSCGuideStrategy.h>
#import <KeyframelessKit/KKResizeCursor.h>
#import <KeyframelessKit/KKTimelineInspectorView+Guide.h>
#import <KeyframelessKit/KKTimelineLanesView.h>
#import <KeyframelessKit/KKTimingGuide.h>
#import <KeyframelessKit/KKTimingStage.h>

// Object-space tolerance within which the drag snaps to / counts as on the
// glowing target.
static const double kMirageOSCGuideTargetSnap = 0.04;

// Plasma's point handle is keyed by its GLSL uniform name (the lane identity
// the mini-viewer OSC binds to), not its display name. So the seed lane + every
// lookup use @"uCenter"; "Center" is only what the user reads.
static NSString *const kMirageGuideCenterLabel = @"uCenter";
static NSString *const kMirageGuideScaleLabel = @"uScale";

// Build a single-keypose Center timeline at object-space (objX, objY) - the
// live value the interactive OSC drag applies.
static KKTimeline *MirageGuideOriginTimeline(double objX, double objY) {
  KKTimeline *tl = [KKTimeline timeline];
  KKLane *lane = [KKLane laneWithLabel:kMirageGuideCenterLabel];
  lane.enabled = YES;
  lane.valueType = KKLaneValueTypeGeneric;
  lane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0
                                       values:@[ @(objX), @(objY) ]] ];
  tl.lanes = @[ lane ];
  return tl;
}

static NSPoint MirageGuideCurrentOrigin(KKTimelineLanesView *lanes) {
  for (KKLane *lane in lanes.currentTimeline.lanes) {
    if ([lane.label isEqualToString:kMirageGuideCenterLabel] &&
        lane.keyposes.count > 0) {
      KKKeyPose *kp = lane.keyposes.firstObject;
      if (kp.values.count >= 2)
        return NSMakePoint(kp.values[0].doubleValue, kp.values[1].doubleValue);
    }
  }
  return NSMakePoint(0.5, 0.5);
}

static BOOL MirageGuideOriginNearTarget(NSPoint p) {
  CGPoint t = MirageGuideTargetObjectPosition();
  return hypot(p.x - t.x, p.y - t.y) < kMirageOSCGuideTargetSnap;
}

@implementation MirageInspectorView (BasicTimingGuide)

// Mirage's timing-guide data: it teaches the Center lane (Plasma's `#point`
// handle), with Scale (Plasma's ring) as the second Advanced-seed lane. The
// inspector-level bridges (play button, tabs, scrub, play-accent, preview) come
// pre-wired from -makeTimingGuideConfig; only the plugin data + the viewer rect
// (from Mirage's OSC bridge) are filled here. Installed as the inspector's
// timingGuideConfigProvider in -init.
- (KKTimingGuideConfig *)_timingGuideConfig {
  KKTimingGuideConfig *cfg = [self makeTimingGuideConfig];
  // Identity = the GLSL uniform (what the mini-viewer OSC binds to); the human
  // name shows in the step copy.
  cfg.primaryLabel = kMirageGuideCenterLabel;
  cfg.primaryDisplayLabel = @"Center";
  // OSCs to keep visible while this guide runs (the rest are hidden). Keyed by
  // the uniform, matching the OSC element key.
  cfg.oscKeepLabels = @[ kMirageGuideCenterLabel ];
  cfg.primaryComponentCount = 2;
  cfg.primaryValueType = KKLaneValueTypeGeneric;
  cfg.primarySeedValues = @[ @0.5, @0.5 ];
  // Second lane in the Advanced seed, so the per-property timeline + marquee
  // multi-select are taught across two rows. Scale is a non-featured lane (not
  // in the Origin-only keypose mini-viewer), so seeding it can't disturb the
  // featured Origin handle.
  cfg.secondaryLabel = kMirageGuideScaleLabel;
  cfg.secondaryDisplayLabel = @"Scale";
  cfg.secondaryValueType = KKLaneValueTypeFloat;
  // Scale is a scalar in [1, 8]; seed it mid-range.
  cfg.secondarySeedValues = @[ @4.0 ];
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
    return MirageSharedOSCGuideBridge().estimatedViewerScreenRect;
  };
  cfg.oscGuideBridge = ^KKOSCGuideBridge * {
    return MirageSharedOSCGuideBridge();
  };
  // The pill step disables Scale (not Origin), so the keypose mini-viewer
  // (which shows only the featured Origin lane) stays populated for the later
  // steps. Keyed by the uniform, matching the lane identity.
  cfg.oscDisableLabel = kMirageGuideScaleLabel;
  // The OSC-shape strategy: how a viewer drag maps to the 2D Origin value and
  // back (pure math; the shared guide owns the copy). Origin is a point, so
  // values box as NSValue.
  __weak KKTimelineLanesView *weakLanes = self.basicLanesView;
  __weak typeof(self) weakSelf = self;
  cfg.oscGuideStrategy = ^KKOSCGuideStrategy * {
    KKOSCGuideStrategy *s = [[KKOSCGuideStrategy alloc] init];
    s.currentValue = ^id {
      return [NSValue valueWithPoint:MirageGuideCurrentOrigin(weakLanes)];
    };
    s.setLiveValue = ^(id v) {
      NSPoint p = [v pointValue];
      MirageSetGuidePosition(p.x, p.y); // OSC handle tracks the drag
    };
    s.valueForScreenPoint = ^id(NSPoint pt) {
      double x = 0.5, y = 0.5;
      MirageGuidePositionForScreenPoint(pt, &x, &y);
      return [NSValue valueWithPoint:NSMakePoint(x, y)];
    };
    s.applyValue = ^(id v) {
      NSPoint p = [v pointValue];
      MirageSetGuidePosition(p.x, p.y);
      KKTimelineLanesView *lanes = weakLanes;
      // Edit the Center keypose nearest the playhead, preserving the other
      // seeded keyposes (the viewer drag teaches editing one pose, not wiping
      // the animation). Falls back to a single-keypose lane only if the current
      // timeline somehow has no Center lane.
      KKTimeline *tl = KKTimelineSettingValuesNearestFraction(
          lanes.currentTimeline, kMirageGuideCenterLabel,
          lanes.playheadFraction, @[ @(p.x), @(p.y) ]);
      if (!tl)
        tl = MirageGuideOriginTimeline(p.x, p.y);
      [lanes applyTimeline:tl];
      __strong typeof(weakSelf) strong = weakSelf;
      if (strong.onTimelineMutated)
        strong.onTimelineMutated(tl);
    };
    s.valueOnTarget = ^BOOL(id v) {
      return MirageGuideOriginNearTarget([v pointValue]);
    };
    s.snapValue = ^id(id v) {
      NSPoint p = [v pointValue];
      if (MirageGuideOriginNearTarget(p)) {
        CGPoint t = MirageGuideTargetObjectPosition();
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
