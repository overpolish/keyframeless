/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "MagicMoveLocalized.h"
#import "MagicMoveMiniViewerRenderer.h"
#import "OSC.h"
#import "Plugin_Private.h"
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KeyframelessKit.h>
@import KeyframelessAI;

static NSString *const kMagicMoveIntroSeenKey = @"MagicMoveIntroSeen";

// Object-space distance within which the interactive Position drag snaps to /
// counts as on the glowing target.
static const double kMagicMoveGuideTargetSnap = 0.04;

// Build a single-keypose Position timeline at object (objX, objY) - the live
// value the interactive OSC drag applies (matches the Basic seed lane shape).
static KKTimeline *MagicMoveGuidePositionTimeline(double objX, double objY) {
  KKTimeline *tl = [KKTimeline timeline];
  KKLane *lane = [KKLane laneWithLabel:@"Position"];
  // Animatable so the Advanced graph shows a clickable keypose (the OSC guide's
  // opt-hide / peek steps open its mini-viewer).
  lane.enabled = YES;
  lane.valueType = KKLaneValueTypeGeneric;
  lane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0
                                       values:@[ @(objX), @(objY) ]] ];
  tl.lanes = @[ lane ];
  return tl;
}

static NSPoint MagicMoveGuideCurrentPosition(KKTimelineLanesView *lanes) {
  for (KKLane *lane in lanes.currentTimeline.lanes) {
    if ([lane.label isEqualToString:@"Position"] && lane.keyposes.count > 0) {
      KKKeyPose *kp = lane.keyposes.firstObject;
      if (kp.values.count >= 2)
        return NSMakePoint(kp.values[0].doubleValue, kp.values[1].doubleValue);
    }
  }
  return NSMakePoint(0.5, 0.5);
}

static BOOL MagicMovePositionNearTarget(NSPoint p) {
  CGPoint t = MagicMoveGuideTargetObjectPosition();
  return hypot(p.x - t.x, p.y - t.y) < kMagicMoveGuideTargetSnap;
}

/// MagicMove draws Position + Rotation on-screen controls, so it opts into the
/// inspector's "On-Screen Controls" visibility row (other plugins default off).
/// It also hosts the shared KKTimingGuide walkthroughs (Position lane).
/// MagicMove draws Position + Rotation on-screen controls, so it opts into the
/// inspector's "On-Screen Controls" visibility row. It also hosts the shared
/// KKTimingGuide walkthroughs (Position lane); all the guide lifecycle lives in
/// the kit base - this subclass only supplies the per-plugin config data.
@interface MagicMoveInspectorView : KKTimelineInspectorView
- (KKTimingGuideConfig *)_timingGuideConfig;
/// MagicMove-only "Shaping a Move" walkthrough (curve a Position keypose +
/// scale a Scale keypose, all in the mini viewer). Runs via the kit's
/// custom-advanced guide runner using -_timingGuideConfig's Position+Scale
/// seed.
- (void)restartShapingGuide;
@end

// YES if any Scale keypose has reached `pct`% - the "Shaping a Move" guide's
// scale-drag completion gate (the dragged end keypose will exceed it).
static BOOL MagicMoveGuideScaleAtLeast(KKTimelineLanesView *lanes, double pct) {
  for (KKLane *lane in lanes.currentTimeline.lanes) {
    if (![lane.label isEqualToString:@"Scale"])
      continue;
    for (KKKeyPose *kp in lane.keyposes)
      if (kp.values.count > 0 && kp.values[0].doubleValue >= pct)
        return YES;
  }
  return NO;
}

// Seed for "Shaping a Move": Position travels left -> right (so the added
// middle keypose, dragged up, makes a clear left-to-right arc); Scale flat at
// 100% until the user grows the end keypose. Both lanes animatable; the lanes
// view re-asserts canonical metadata (units/bounds) and appends the rest.
static KKTimeline *MagicMoveShapingSeed(void) {
  KKLane *pos = [KKLane laneWithLabel:@"Position"];
  pos.enabled = YES;
  pos.valueType = KKLaneValueTypeGeneric;
  pos.keyposes = @[
    [KKKeyPose keyposeAtTime:0.0 values:@[ @0.2, @0.5 ]], // left
    [KKKeyPose keyposeAtTime:1.0 values:@[ @0.8, @0.5 ]], // right
  ];
  KKLane *scale = [KKLane laneWithLabel:@"Scale"];
  scale.enabled = YES;
  scale.valueType = KKLaneValueTypeFloat;
  scale.keyposes = @[
    [KKKeyPose keyposeAtTime:0.0 values:@[ @100.0, @100.0 ]],
    [KKKeyPose keyposeAtTime:1.0 values:@[ @100.0, @100.0 ]],
  ];
  KKTimeline *tl = [KKTimeline timeline];
  tl.lanes = @[ pos, scale ]; // alphabetical = display order
  return tl;
}

// The "Shaping a Move" step array. Plugin-specific (Scale lane + the scale box
// handle drag are Magic Move's), built from the shared kit step machinery +
// guide hooks. Order: intro -> add mid Position keypose -> drag it up -> double
// click to curve -> click end Scale keypose -> drag a corner to ~200% -> play.
static NSArray<KKJoyrideStep *> *
MagicMoveShapingGuideSteps(KKJoyrideController *guide,
                           KKJoyrideLanesBinder *binder,
                           KKTimingGuideConfig *cfg) {
  KKTimelineLanesView *lanes = cfg.lanesView;
  __weak KKTimelineLanesView *weakLanes = lanes;
  __weak KKTimelineAdvancedView *weakAdv = lanes.advancedGraph;
  __weak KKJoyrideLanesBinder *weakBinder = binder;
  __weak KKJoyrideController *weakGuide = guide;

  const NSInteger ixIntro = 0, ixAdd = 1, ixDragUp = 2, ixCurve = 3,
                  ixScaleKP = 4, ixScaleDrag = 5, ixPlay = 6, ixDone = 7;
  (void)ixIntro;
  (void)ixDone;

  const double kAddFrac = 0.5;
  NSArray<NSNumber *> *kUpVals = @[ @0.5, @0.85 ]; // Position up (Y points up)
  const NSInteger kScaleCorner = 2;                // top-right handle
  NSArray<NSNumber *> *kScaleTargetVals = @[ @200.0, @200.0 ];
  const double kScaleHitPct = 180.0;
  __block BOOL watchScheduled = NO;

  KKJoyrideStep *sIntro = [KKJoyrideStep
      stepWithMessage:MMLoc(@"Two lanes here - <accent>Position</accent> and "
                            @"<accent>Scale</accent> - each with a keypose at "
                            @"the start and end.",
                            @"Shaping guide: intro to the two lanes.")
           targetView:^NSView * {
             return weakAdv;
           }];
  sIntro.showsNext = YES;

  KKJoyrideStep *sAdd = [KKJoyrideStep
      stepWithMessage:MMLoc(@"<kbd>⌘ click</kbd> the <accent>Position</accent> "
                            @"lane to add a keypose in the middle.",
                            @"Shaping guide: add a middle Position keypose.")
           targetView:nil];
  sAdd.spotlightCircular = NO;
  sAdd.targetScreenRect = ^NSRect {
    __strong KKTimelineAdvancedView *a = weakAdv;
    return a ? [a guideLaneRowScreenRectForLabel:@"Position"] : NSZeroRect;
  };
  sAdd.pillToScreenRect = ^NSRect {
    __strong KKTimelineAdvancedView *a = weakAdv;
    return a ? [a guideKeyposeScreenRectForLabel:@"Position"
                                      atFraction:kAddFrac]
             : NSZeroRect;
  };

  NSRect (^upTarget)(void) = ^NSRect {
    __strong KKMiniViewerView *c = weakBinder.latestMiniViewer;
    return c ? [c pointHandleScreenRectForValues:kUpVals] : NSZeroRect;
  };
  KKJoyrideStep *sUp = [KKJoyrideDragStep stepForGuide:guide
      atIndex:ixDragUp
      isLast:NO
      clickMessage:MMLoc(@"In the <accent>mini viewer</accent>, drag the "
                         @"keypose <warn>up</warn>.",
                         @"Shaping guide: drag the Position keypose up.")
      dragMessage:nil
      circular:YES
      spotRect:^NSRect {
        __strong KKMiniViewerView *c = weakBinder.latestMiniViewer;
        return c ? [c pointHandleScreenRect] : NSZeroRect;
      }
      targetRect:upTarget
      begin:^(NSPoint p) {
        __strong KKMiniViewerView *c = weakBinder.latestMiniViewer;
        NSRect spot = [c pointHandleScreenRect];
        [c beginPointHandleDragAtScreenPoint:NSIsEmptyRect(spot)
                                                 ? p
                                                 : NSMakePoint(NSMidX(spot),
                                                               NSMidY(spot))];
      }
      dragTo:^(NSPoint p) {
        [weakBinder.latestMiniViewer
            dragPointHandleToScreenPoint:KKJoyrideSnapToTarget(p, upTarget(),
                                                               9.0)];
      }
      end:^{
        [weakBinder.latestMiniViewer endPointHandleDrag];
      }
      hitOnRelease:^BOOL(NSPoint p) {
        NSRect t = upTarget();
        double dpx =
            NSIsEmptyRect(t) ? 1e9 : hypot(p.x - NSMidX(t), p.y - NSMidY(t));
        return dpx <= 16.0;
      }];

  KKJoyrideStep *sCurve = [KKJoyrideStep
      stepWithMessage:MMLoc(@"<accent>Double-click</accent> the keypose to "
                            @"<accent>curve</accent> the path.",
                            @"Shaping guide: double-click to curve the path.")
           targetView:nil];
  sCurve.spotlightCircular = YES;
  sCurve.targetScreenRect = ^NSRect {
    __strong KKMiniViewerView *c = weakBinder.latestMiniViewer;
    return c ? [c pointHandleScreenRect] : NSZeroRect;
  };

  KKJoyrideStep *sScaleKP = [KKJoyrideStep
      stepWithMessage:MMLoc(@"Now click the <accent>Scale</accent> keypose at "
                            @"the end.",
                            @"Shaping guide: click the end Scale keypose.")
           targetView:nil];
  sScaleKP.spotlightCircular = NO;
  sScaleKP.onEnter = ^{
    [weakLanes guideCloseContentPopover];
  };
  sScaleKP.targetScreenRect = ^NSRect {
    __strong KKTimelineAdvancedView *a = weakAdv;
    return a ? [a guideKeyposeScreenRectForLabel:@"Scale" atIndex:1]
             : NSZeroRect;
  };

  NSRect (^scaleSpot)(void) = ^NSRect {
    __strong KKMiniViewerView *c = weakBinder.latestMiniViewer;
    return c ? [c scaleHandleScreenRectAtIndex:kScaleCorner] : NSZeroRect;
  };
  NSRect (^scaleTarget)(void) = ^NSRect {
    __strong KKMiniViewerView *c = weakBinder.latestMiniViewer;
    return c ? [c scaleHandleScreenRectAtIndex:kScaleCorner
                                forScaleValues:kScaleTargetVals]
             : NSZeroRect;
  };
  KKJoyrideStep *sScale = [KKJoyrideDragStep stepForGuide:guide
      atIndex:ixScaleDrag
      isLast:NO
      clickMessage:MMLoc(@"Drag a <warn>corner</warn> out to about "
                         @"<accent>200%</accent>.",
                         @"Shaping guide: scale the keypose up to 200%.")
      dragMessage:nil
      circular:NO
      spotRect:scaleSpot
      targetRect:scaleTarget
      begin:^(NSPoint p) {
        __strong KKMiniViewerView *c = weakBinder.latestMiniViewer;
        NSRect spot = scaleSpot();
        [c beginPointHandleDragAtScreenPoint:NSIsEmptyRect(spot)
                                                 ? p
                                                 : NSMakePoint(NSMidX(spot),
                                                               NSMidY(spot))];
      }
      dragTo:^(NSPoint p) {
        [weakBinder.latestMiniViewer
            dragPointHandleToScreenPoint:KKJoyrideSnapToTarget(p, scaleTarget(),
                                                               12.0)];
      }
      end:^{
        [weakBinder.latestMiniViewer endPointHandleDrag];
      }
      hitOnRelease:^BOOL(NSPoint p) {
        return MagicMoveGuideScaleAtLeast(weakLanes, kScaleHitPct);
      }];

  KKJoyrideStep *sPlay = [KKJoyrideStep
      stepWithMessage:MMLoc(@"Press <symbol play.fill color=accent /> to watch "
                            @"it back.",
                            @"Shaping guide: play the animation back.")
           targetView:nil];
  sPlay.spotlightCircular = NO;
  sPlay.targetScreenRect = ^NSRect {
    NSRect play =
        cfg.playButtonScreenRect ? cfg.playButtonScreenRect() : NSZeroRect;
    NSRect viewer = cfg.viewerScreenRect ? cfg.viewerScreenRect() : NSZeroRect;
    if (NSIsEmptyRect(viewer))
      return play;
    if (NSIsEmptyRect(play))
      return viewer;
    return NSUnionRect(play, viewer);
  };
  sPlay.onEnter = ^{
    watchScheduled = NO;
    [weakLanes guideCloseContentPopover];
    if (cfg.scrubToFraction)
      cfg.scrubToFraction(0.0);
  };

  KKJoyrideStep *sDone = [KKJoyrideStep
      stepWithMessage:MMLoc(@"The <accent>mini viewer</accent> brings each "
                            @"keypose's frame to you - shape any pose without "
                            @"moving the playhead to find it.",
                            @"Shaping guide: closing benefit step.")
           targetView:^NSView * {
             return weakAdv;
           }];

  [binder bindStep:sAdd
           atIndex:ixAdd
         advanceOn:[KKJoyrideTrigger staticValuesPopoverWillOpen]
         dismissOn:nil];
  [binder bindStep:sCurve
           atIndex:ixCurve
         advanceOn:[KKJoyrideTrigger miniViewerDoubleClickHandled]
         dismissOn:nil];
  [binder bindStep:sScaleKP
           atIndex:ixScaleKP
         advanceOn:[KKJoyrideTrigger staticValuesPopoverWillOpen]
         dismissOn:nil];

  // Watch-back: the user's play tap schedules a single advance once the clip
  // has played all the way through. Delay = clip duration (+ a small buffer for
  // FCP's start latency) rather than a fixed beat, so the step moves on when
  // the animation finishes. No togglePlayback: FCP stops at the clip's out
  // point on its own, and toggling an already-stopped clip would restart it.
  binder.playToggleTapped = ^{
    __strong KKJoyrideController *g = weakGuide;
    if (!g || g.currentStepIndex != ixPlay || watchScheduled)
      return;
    watchScheduled = YES;
    __strong KKTimelineAdvancedView *a = weakAdv;
    double dur = (a && a.clipDurationSeconds > 0) ? a.clipDurationSeconds : 2.0;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)((dur + 0.4) * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          __strong KKJoyrideController *g2 = weakGuide;
          if (!g2 || g2.currentStepIndex != ixPlay)
            return;
          if (cfg.setPlayingAccent)
            cfg.setPlayingAccent(NO);
          [g2 advance];
        });
  };

  return @[ sIntro, sAdd, sUp, sCurve, sScaleKP, sScale, sPlay, sDone ];
}

@implementation MagicMoveInspectorView
- (BOOL)showsOSCVisibilityRow {
  return YES;
}

// First-appearance autostart of the "Introduction" (basic timing) guide. The
// config provider is installed here (lazily, once) so the kit's restart /
// autostart machinery can pull a fresh config when a guide starts.
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.isDetachedCopy)
    return;
  if (!self.timingGuideConfigProvider) {
    __weak typeof(self) weak = self;
    self.timingGuideConfigProvider = ^KKTimingGuideConfig * {
      __strong typeof(weak) s = weak;
      return s ? [s _timingGuideConfig] : nil;
    };
  }
  [self autostartIntroGuideOnceWithSeenKey:kMagicMoveIntroSeenKey];
}

// MagicMove's timing-guide data: it teaches the Position lane. The inspector
// bridges (play button, tabs, scrub, play-accent, preview) come pre-wired from
// -makeTimingGuideConfig; only the plugin data + the viewer rect (from the OSC
// bridge, unioned into the watch-back cutout) are filled here.
- (KKTimingGuideConfig *)_timingGuideConfig {
  KKTimingGuideConfig *cfg = [self makeTimingGuideConfig];
  cfg.primaryLabel = @"Position";
  // OSCs to keep visible while this guide runs (the rest are hidden).
  cfg.oscKeepLabels = @[ @"Position" ];
  cfg.primaryComponentCount = 2;
  cfg.primaryValueType = KKLaneValueTypeGeneric;
  cfg.primarySeedValues = @[ @0.5, @0.5 ];
  // Second lane in the Advanced seed (mirrors Rounded's Radius + Crop), so the
  // per-property timeline + marquee multi-select are taught across two rows.
  // Scale is a non-featured lane (not in the Position-only keypose
  // mini-viewer), so seeding it can't disturb the featured Position handles.
  cfg.secondaryLabel = @"Scale";
  cfg.secondaryValueType = KKLaneValueTypeFloat;
  cfg.secondarySeedValues = @[ @100.0, @100.0 ];
  // Destination the constants step drags Position to (off-centre from the
  // seeded centre, normalized 0..1).
  cfg.primaryTargetValues = @[ @0.7, @0.35 ];
  // A different spot for the keypose-edit drag so the handle visibly moves.
  cfg.keyposeTargetValues = @[ @0.3, @0.62 ];
  // Mini-viewer guide: four corner positions so the clip visibly moves around
  // the frame across the filmstrip / onion-skin frames.
  cfg.miniViewerSeedValues =
      @[ @[ @0.3, @0.3 ], @[ @0.7, @0.3 ], @[ @0.7, @0.7 ], @[ @0.3, @0.7 ] ];
  cfg.viewerScreenRect = ^NSRect {
    return MagicMoveSharedOSCGuideBridge().estimatedViewerScreenRect;
  };
  cfg.oscGuideBridge = ^KKOSCGuideBridge * {
    return MagicMoveSharedOSCGuideBridge();
  };
  // The pill step disables Scale (not Position), so the keypose mini-viewer
  // (which shows only the featured Position lane) stays populated for the later
  // steps.
  cfg.oscDisableLabel = @"Scale";
  // The OSC-shape strategy: how a viewer drag maps to the 2D Position value and
  // back (pure math; the shared guide owns the copy). Position is a point, so
  // values box as NSValue.
  __weak KKTimelineLanesView *weakLanes = self.basicLanesView;
  __weak typeof(self) weakSelf = self;
  cfg.oscGuideStrategy = ^KKOSCGuideStrategy * {
    KKOSCGuideStrategy *s = [[KKOSCGuideStrategy alloc] init];
    s.currentValue = ^id {
      return [NSValue valueWithPoint:MagicMoveGuideCurrentPosition(weakLanes)];
    };
    s.setLiveValue = ^(id v) {
      NSPoint p = [v pointValue];
      MagicMoveSetGuidePosition(p.x, p.y); // viewer handle tracks the drag
    };
    s.valueForScreenPoint = ^id(NSPoint pt) {
      double x = 0.5, y = 0.5;
      MagicMoveGuidePositionForScreenPoint(pt, &x, &y);
      return [NSValue valueWithPoint:NSMakePoint(x, y)];
    };
    s.applyValue = ^(id v) {
      NSPoint p = [v pointValue];
      MagicMoveSetGuidePosition(p.x, p.y);
      KKTimelineLanesView *lanes = weakLanes;
      KKTimeline *tl = MagicMoveGuidePositionTimeline(p.x, p.y);
      [lanes applyTimeline:tl];
      __strong typeof(weakSelf) strong = weakSelf;
      if (strong.onTimelineMutated)
        strong.onTimelineMutated(tl);
    };
    s.valueOnTarget = ^BOOL(id v) {
      return MagicMovePositionNearTarget([v pointValue]);
    };
    s.snapValue = ^id(id v) {
      NSPoint p = [v pointValue];
      if (MagicMovePositionNearTarget(p)) {
        CGPoint t = MagicMoveGuideTargetObjectPosition();
        return [NSValue valueWithPoint:NSMakePoint(t.x, t.y)];
      }
      return v;
    };
    s.requireTargetHit = YES;
    return s;
  };
  return cfg;
}

- (void)restartShapingGuide {
  KKTimingGuideConfig *cfg = [self _timingGuideConfig];
  // Keep ALL on-screen controls visible (oscKeepLabels nil): the double-click
  // curve step needs the Position path visible, and the scale step needs the
  // Scale box - so don't hide anything for this run.
  [self
      runCustomAdvancedGuideWithSeed:^KKTimeline * {
        return MagicMoveShapingSeed();
      }
      buildSteps:^NSArray<KKJoyrideStep *> *(KKJoyrideController *guide,
                                             KKJoyrideLanesBinder *binder) {
        return MagicMoveShapingGuideSteps(guide, binder, cfg);
      }
      oscKeepLabels:nil];
}
@end

/// Plain-text coordinate-space description for the AI agent's value-resolution
/// pass - the only context that LLM call sees alongside the user's prompt. Just
/// lanes and their numeric ranges; no timing words.
static NSString *_MagicMoveAILaneSchemaText(void) {
  NSMutableString *s = [NSMutableString string];
  [s appendString:@"Lane labels and coordinate spaces:\n\n"];
  [s appendString:
          @"- \"Position\": two numeric components [x, y].\n"
          @"    Normalised clip space, 0..1, where 0.5 = centre of the frame.\n"
          @"    x: 0 = left edge, 1 = right edge.\n"
          @"    y: 0 = bottom, 1 = top (Y points UP).\n"
          @"    Off-frame values (< 0 or > 1) are allowed, so the clip can "
          @"start or end fully outside the frame.\n"
          @"    Default value: [0.5, 0.5] (centred).\n"
          @"\n"
          @"- \"Scale\": two numeric components [x, y], whole percentages of "
          @"the clip's own size.\n"
          @"    100 = original size. Floored at 0, no upper limit. Never "
          @"negative (use Rotation to flip).\n"
          @"    Default value: [100, 100].\n"
          @"\n"
          @"- \"Rotation\": three numeric components [x, y, z], in DEGREES.\n"
          @"    z = the in-plane spin (clockwise positive) - this is the usual "
          @"rotation. x and y tilt the clip in 3D.\n"
          @"    Values accumulate past 360 (720 = two full turns).\n"
          @"    Default value: [0, 0, 0].\n"
          @"\n"
          @"- \"Opacity\": one numeric component, whole percentage 0..100.\n"
          @"    100 = fully opaque, 0 = invisible.\n"
          @"    Default value: 100.\n"
          @"\n"
          @"- \"Anchor\": two numeric components [x, y] - the pivot that "
          @"Rotation and Scale swing around.\n"
          @"    Same normalised space as Position relative to the clip: "
          @"[0.5, 0.5] = clip centre, [0, 0] = bottom-left corner, "
          @"[1, 1] = top-right corner.\n"
          @"    Default value: [0.5, 0.5] (centre). Only change it when the "
          @"user wants rotation/scale to pivot off-centre.\n"];
  return s;
}

@implementation MagicMovePlugin (CustomUI)

- (BOOL)usesMotionBlur {
  return YES;
}

- (KKClipWrappingMode)clipWrappingMode {
  return KKClipWrappingModeCompound;
}

+ (NSArray<KKLane *> *)availableLanes {
  KKLane *position = [KKLane laneWithLabel:@"Position"];
  position.valueType = KKLaneValueTypeGeneric;
  // Position is allowed off-canvas, so no min/max - empty = unconstrained.
  position.componentMin = @[];
  position.componentMax = @[];
  position.componentUnits = @[ @"px", @"px" ];
  position.componentLabels = @[ @"X", @"Y" ];
  // 2D spatial path: keyposes can be smooth (curved). Lights the per-keypose
  // corner/smooth toggle in the value popover and curves the motion path.
  position.spatialCurvable = YES;
  [position insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.5, @0.5 ]]];

  KKLane *rotation = [KKLane laneWithLabel:@"Rotation"];
  rotation.valueType = KKLaneValueTypeAngle;
  // Knobs cover one revolution visually but model values accumulate past
  // 360° (FCP behaviour - 2 full turns = 720°). Empty min/max = unconstrained.
  rotation.componentMin = @[];
  rotation.componentMax = @[];
  rotation.componentUnits = @[ @"°", @"°", @"°" ];
  rotation.componentLabels = @[ @"X", @"Y", @"Z" ];
  // Standard 3D-axis tint convention (Motion / Blender / Maya): X=red,
  // Y=green, Z=blue. Slightly desaturated so they don't shout against the
  // inspector background.
  rotation.componentLabelColors = @[
    [NSColor colorWithSRGBRed:0.95 green:0.35 blue:0.35 alpha:1.0],
    [NSColor colorWithSRGBRed:0.40 green:0.85 blue:0.45 alpha:1.0],
    [NSColor colorWithSRGBRed:0.40 green:0.60 blue:0.95 alpha:1.0],
  ];
  [rotation insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                            values:@[ @0.0, @0.0, @0.0 ]]];

  KKLane *scale = [KKLane laneWithLabel:@"Scale"];
  scale.valueType = KKLaneValueTypeFloat;
  // Percentage of the clip's own size; 100 = identity. Floor at 0 (no flip),
  // no upper cap (empty max = unconstrained), same as Position's open fields.
  scale.componentMin = @[ @0.0, @0.0 ];
  scale.componentMax = @[];
  scale.componentUnits = @[ @"%", @"%" ];
  scale.componentLabels = @[ @"X", @"Y" ];
  scale.integerValued = YES; // whole percentages only

  // Aspect lock: link glyph in the value popover, on by default (most apps
  // constrain proportions out of the box). Preserves the current X:Y ratio.
  scale.aspectLinkable = YES;
  scale.aspectLinked = YES;
  [scale insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                         values:@[ @100.0, @100.0 ]]];

  KKLane *opacity = [KKLane laneWithLabel:@"Opacity"];
  opacity.valueType = KKLaneValueTypeFloat;
  // Percentage like FCP's opacity control; 100 = fully opaque. Hard 0-100
  // bounds (unlike Scale's open top) - there's no meaningful overshoot.
  opacity.componentMin = @[ @0.0 ];
  opacity.componentMax = @[ @100.0 ];
  opacity.componentUnits = @[ @"%" ];
  opacity.integerValued = YES; // whole percentages only
  [opacity insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @100.0 ]]];

  KKLane *anchor = [KKLane laneWithLabel:@"Anchor"];
  anchor.valueType = KKLaneValueTypeGeneric;
  // The pivot rotation and scale swing around, in the same normalized object
  // space as Position (0.5,0.5 = clip center). No min/max - the anchor can sit
  // off the clip just like Position can go off-canvas.
  anchor.componentMin = @[];
  anchor.componentMax = @[];
  anchor.componentUnits = @[ @"px", @"px" ];
  anchor.componentLabels = @[ @"X", @"Y" ];
  [anchor insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.5, @0.5 ]]];

  return @[ position, scale, rotation, opacity, anchor ];
}

+ (NSArray<NSArray<NSString *> *> *)oscCompounds {
  return @[
    @[ @"Position" ],
    @[ @"Path" ],
    @[ @"Scale" ],
    @[ @"Rotation", @"Rotation.X", @"Rotation.Y", @"Rotation.Z" ],
    @[ @"Anchor" ],
  ];
}

+ (NSArray<NSString *> *)oscElementKeys {
  NSMutableArray<NSString *> *flat = [NSMutableArray array];
  for (NSArray<NSString *> *c in [self oscCompounds])
    [flat addObjectsFromArray:c];
  return flat;
}

- (void)applyOSCElementsFromUIState:(NSDictionary *)uiState {
  [self kkApplyOSCVisibilityFromState:uiState
                          elementKeys:[MagicMovePlugin oscElementKeys]
                             renderer:self.miniViewerRenderer];
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID != kParamInspectorUI) {
    typedef NSView *(*ViewIMP)(id, SEL, UInt32);
    ViewIMP imp = (ViewIMP)[KKPlugin instanceMethodForSelector:_cmd];
    return imp(self, _cmd, parameterID);
  }

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];

  KKInspectorPersistedState *st =
      [self kkReadInspectorPersistedStateWithGetAPI:getAPI
                                     uiStateParamID:kParamUIState];
  BOOL loopEnabled = st.loopEnabled;
  NSInteger activeTab = st.activeTab;
  BOOL oscMasterVisible = st.oscMasterVisible;
  KKMiniViewerRenderMode renderMode = (KKMiniViewerRenderMode)st.renderMode;
  BOOL motionBlurEnabled = st.motionBlurEnabled;
  double motionBlurShutterAngle = st.motionBlurShutterAngle;
  NSInteger motionBlurSamples = st.motionBlurSamples;
  NSInteger motionBlurMode = st.motionBlurMode;
  NSDictionary *uiState = st.uiState;
  KKTimeline *timeline = [self timelineStampedWithClipDuration:st.timeline];

  // Cold-boot seed for the OSC. Without this the first drawOSC tick after FCP
  // relaunch reads nil → handle snaps to (0.5, 0.5) regardless of saved state.
  KKSetProcessTimelineSnapshot(timeline);
  // Per-instance OSC visibility lives in KKPluginInstanceState (the OSC reads
  // it via the shared kKKParamInstanceID UUID, NOT a process singleton, so two
  // instances on one clip stay independent). Ensure mints the UUID here, inside
  // the action scope where the setting API resolves.
  KKPluginInstanceState *instState =
      KKInstanceStateEnsureForAPI(self.apiManager);
  instState.oscMasterVisible = oscMasterVisible;

  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  double seedFrameDurSec = 0.0;
  double seedClipDurSec = 0.0;
  if (timingAPI) {
    CMTime frameDur = kCMTimeZero, clipDur = kCMTimeZero;
    [timingAPI frameDuration:&frameDur];
    [timingAPI durationTimeForEffect:&clipDur];
    seedFrameDurSec = CMTimeGetSeconds(frameDur);
    seedClipDurSec = CMTimeGetSeconds(clipDur);
    if (seedFrameDurSec > 0)
      KKSetProcessFrameDurationSeconds(seedFrameDurSec);
  }

  [actionAPI endAction:self];

  NSArray<KKLane *> *available = [MagicMovePlugin availableLanes];
  KKTimelineInspectorView *view =
      [[MagicMoveInspectorView alloc] initWithAPIManager:self.apiManager
                                             loopEnabled:loopEnabled
                                               activeTab:activeTab
                                          availableLanes:available
                                                timeline:timeline];

  if (!self.miniViewerRenderer) {
    self.miniViewerRenderer = [[MagicMoveMiniViewerRenderer alloc] init];
  }
  self.miniViewerRenderer.timeline = timeline;
  self.miniViewerRenderer.handlesHidden = !oscMasterVisible;
  [self applyOSCElementsFromUIState:uiState];
  // Wire the master tick + per-element pills + mini-viewer opt-click in one
  // call (shared glue in KKPlugin (OSCVisibility)).
  [self kkWireOSCVisibilityForView:view
                          renderer:self.miniViewerRenderer
                         compounds:[MagicMovePlugin oscCompounds]
                           paramID:kParamUIState];
  view.miniViewerDelegate = self.miniViewerRenderer;

  // Force OSCs visible while a guide runs (so its mini-viewer + viewer handles
  // are usable), then restore the user's OSC setting on guide end.
  [self kkInstallGuideOSCForcingOnHost:[(MagicMoveInspectorView *)
                                               view timingGuideHost]
                                  view:view
                           elementKeys:[KKPlugin
                                           kkOSCElementKeysForCompounds:
                                               [MagicMovePlugin oscCompounds]]
                          nudgeParamID:kParamRenderNudge];
  // Per-instance rendezvous paths (keyed by the instance UUID minted above) so
  // two stacked MagicMove clips read/write distinct /tmp files instead of the
  // top clip flickering the one below it.
  NSString *instUUID = KKInstanceUUIDForAPI(self.apiManager);
  view.miniViewerDescriptorPath =
      MagicMoveMiniViewerDescriptorPathForUUID(instUUID);
  view.miniViewerRequestPath = MagicMoveMiniViewerRequestPathForUUID(instUUID);
  if (seedClipDurSec > 0)
    [view setClipDurationSeconds:seedClipDurSec];
  if (seedFrameDurSec > 0)
    [view setFrameDurationSeconds:seedFrameDurSec];
  [view setMotionBlurEnabled:motionBlurEnabled];
  [view setMotionBlurShutterAngle:motionBlurShutterAngle
                          samples:motionBlurSamples];
  [view setMotionBlurMode:(KKMotionBlurMode)motionBlurMode];
  [view setRenderMode:renderMode];
  [view setOSCVisible:oscMasterVisible];

  [self kkWireStandardInspectorCallbacksForView:view
                                 uiStateParamID:kParamUIState
                             renderNudgeParamID:kParamRenderNudge
                                  dragUndoLabel:@"Adjust Magic Move"
                             detachedWindowSize:CGSizeMake(720.0, 460.0)];
  // Mini-viewer motion-path edits (anchor / handle drag) persist the whole
  // blob through the same writer as inspector timeline mutations.
  self.miniViewerRenderer.onTimelinePersist = view.onTimelineMutated;

  // Rotate-with-motion: per-interval toggle on the Position lane's gap
  // popovers (curve + hold-modulation, Advanced + Basic). Persisted under
  // the interval's userProperties dict. Disabled (and ignored) when the
  // gap has no actual motion - linear curves with no modulation produce no
  // tangent to rotate along.
  view.gapPopoverExtraRows = ^NSArray<NSView *> *(
      KKGapPopoverPhase phase, NSString *laneLabel, KKInterval *rep,
      KKGapIntervalReader read, KKGapIntervalMutator mutate) {
    if (![laneLabel isEqualToString:@"Position"])
      return @[];
    KKCheckboxRowView *row = [[KKCheckboxRowView alloc]
        initWithTitle:MMLoc(@"Rotate with motion",
                            @"Gap popover toggle: align rotation to the "
                            @"position-curve tangent during this gap.")
        tooltip:nil
        binding:^BOOL {
          KKInterval *live = read();
          return [live userBoolForKey:@"rotateWithMotion" default:NO];
        }
        disabledBinding:^BOOL {
          // Rotate-with-motion only needs the position to MOVE - the lean is
          // driven by acceleration, so a modulated gap's wobble drives it just
          // as well as a path tangent. Disable only when the gap is genuinely
          // static:
          // - Hold-modulation gaps wobble only if they actually have
          // modulation;
          //   a plain static hold does not move, so disable that.
          // - Transition gaps move unless they holdsFlat (Basic per-property
          //   phase-off) with no modulation to wobble them.
          KKInterval *live = read();
          BOOL hasModulation = (live.modulation != KKIntervalModulationNone);
          if (phase == KKGapPopoverPhaseHoldModulation)
            return !hasModulation;
          return live.holdsFlat && !hasModulation;
        }
        onToggle:^(BOOL isOn) {
          mutate(^(KKInterval *iv) {
            [iv setUserBool:isOn forKey:@"rotateWithMotion"];
          });
        }];
    return @[ row ];
  };

  self.inspectorView = view;
  if (!self.playheadPoller) {
    self.playheadPoller =
        [[KKPlayheadPoller alloc] initWithAPIManager:self.apiManager
                                        actionTarget:self
                                         renderCache:self.renderCache];
  }
  [self.playheadPoller setInspectorView:view];
  // The render tick may have already established timing before the
  // inspector view existed (poller was nil then, so ensureRunning was a
  // no-op nil-send). Kick it now so the scrubber appears without needing
  // the user to scrub.
  if (self.renderCache.effectDurSec > 0.0)
    [self.playheadPoller ensureRunning];
  return view;
}

- (NSArray<KKHelpGuide *> *)helpGuides {
  // The Introduction + Advanced Timing entries (copy, gating, completion
  // wiring) are identical across plugins, so the kit builds them. MagicMove
  // only supplies the canvas-reference gate (set once the user hovers the
  // viewer; the watch-back step needs it for the viewer cutout) and the live
  // inspector.
  __weak typeof(self) weak = self;
  KKTimelineInspectorView * (^ivProvider)(void) = ^KKTimelineInspectorView * {
    __strong typeof(weak) strong = weak;
    return strong.inspectorView;
  };
  BOOL (^enabled)(void) = ^BOOL {
    return MagicMoveSharedOSCGuideBridge().hasCanvasReference;
  };
  NSMutableArray<KKHelpGuide *> *guides = [[KKTimingGuide
      standardHelpGuidesForInspectorProvider:ivProvider
                             enabledProvider:enabled] mutableCopy];

  // MagicMove-only "Shaping a Move" walkthrough (curve a Position keypose +
  // scale a Scale keypose in the mini viewer). Appended after the shared four.
  __block __weak KKHelpGuide *weakShaping = nil;
  KKHelpGuide *shaping = [KKHelpGuide
      guideWithTitle:MMLoc(@"Shaping a Move",
                           @"Help guide title: Magic Move shaping walkthrough.")
            subtitle:MMLoc(@"Curve the path and scale a keypose",
                           @"Help guide subtitle: Shaping a Move.")
             onStart:^{
               KKTimelineInspectorView *iv = ivProvider();
               if (![iv isKindOfClass:[MagicMoveInspectorView class]])
                 return;
               KKHelpGuide *live = weakShaping;
               iv.onGuideCompleted = ^{
                 [live markCompleted];
               };
               [(MagicMoveInspectorView *)iv restartShapingGuide];
             }];
  weakShaping = shaping;
  shaping.identifier = @"magicmove.shaping";
  shaping.enabledProvider = enabled;
  shaping.disabledSubtitle = MMLoc(
      @"Guides are disabled. Click the effect's header on a clip to select it "
      @"(it highlights yellow), then move your mouse over the viewer to enable "
      @"them.",
      @"Help guide disabled subtitle (no OSC canvas reference yet).");
  [guides addObject:shaping];
  return guides;
}

- (NSNotificationName)helpGuideRefreshNotificationName {
  // The OSC bridge posts this ~1/s while the OSC draws, so the help window
  // re-evaluates the enabled gate once the user hovers the viewer and the
  // canvas reference is established.
  return MagicMoveSharedOSCGuideBridge().guidePositionNotificationName;
}

- (nullable NSString *)helpHeaderTitle {
  return MMLoc(@"Magic Move", @"Help section title (plugin name).");
}

- (nullable NSImage *)helpHeaderIcon {
  return [NSImage imageWithSystemSymbolName:@"circle.dotted.and.circle"
                   accessibilityDescription:nil];
}

- (NSArray<KKHelpSection *> *)helpSections {
  // Quick reference: a short overview + parameter list (single-sourced from
  // magicmove.md, the same doc the AI reads), then an on-screen-control
  // shortcuts table. The per-property deep docs (position/scale/anchor.md)
  // stay AI-only.
  KKHelpSection *overview = [self
      helpSectionFromKnowledgeTopic:@"magicmove"
                              title:MMLoc(@"Magic Move",
                                          @"Help section title (plugin name).")
                             symbol:@"circle.dotted.and.circle"
                          localizer:^NSString *(NSString *tip) {
                            return MMLoc(tip, @"Magic Move help tip (from "
                                              @"AIKnowledge markdown).");
                          }];

  NSMutableArray<KKHelpShortcut *> *rows = [@[
    [KKHelpShortcut
        shortcutWithKeysMarkup:MMLoc(@"<kbd>⇧</kbd> + drag a Position handle",
                                     @"Shortcut keys.")
                    descMarkup:MMLoc(@"Lock the move to the X or Y axis",
                                     @"Help shortcut.")],
    [KKHelpShortcut
        shortcutWithKeysMarkup:MMLoc(@"<kbd>⌘</kbd> + drag", @"Shortcut keys.")
                    descMarkup:MMLoc(@"Snap to the centre, edges, thirds, or "
                                     @"another keypose",
                                     @"Help shortcut.")],
    [KKHelpShortcut
        shortcutWithKeysMarkup:MMLoc(@"Double-click a path anchor",
                                     @"Shortcut keys.")
                    descMarkup:MMLoc(@"Toggle a smooth curve or a sharp corner",
                                     @"Help shortcut.")],
    [KKHelpShortcut
        shortcutWithKeysMarkup:MMLoc(@"<kbd>⇧</kbd> + drag a path handle",
                                     @"Shortcut keys.")
                    descMarkup:MMLoc(@"Break the curve handle's symmetry",
                                     @"Help shortcut.")],
    [KKHelpShortcut
        shortcutWithKeysMarkup:MMLoc(@"<kbd>⇧</kbd> + drag a Scale handle",
                                     @"Shortcut keys.")
                    descMarkup:MMLoc(@"Break the aspect lock for that drag",
                                     @"Help shortcut.")],
    [KKHelpShortcut
        shortcutWithKeysMarkup:MMLoc(@"<kbd>⌘</kbd> + drag a Scale handle",
                                     @"Shortcut keys.")
                    descMarkup:MMLoc(@"Fine adjustment", @"Help shortcut.")],
  ] mutableCopy];
  [rows addObjectsFromArray:[KKPlugin sharedOnScreenControlShortcuts]];

  KKHelpSection *shortcuts =
      [KKHelpSection sectionWithTitle:MMLoc(@"On-screen control shortcuts",
                                            @"Help section title.")
                            tipMarkup:nil
                            shortcuts:rows];
  shortcuts.icon = [NSImage imageWithSystemSymbolName:@"hand.point.up.left"
                             accessibilityDescription:nil];

  return @[ overview, shortcuts ];
}

- (nullable NSView *)aiAccessoryView {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // Shared timeline docs now live in the kit framework bundle (so the kit
    // help window can render the same source); register them from there.
    [KKAIKnowledge registerSharedTimelineDocsWithBundle:
                       [NSBundle bundleForClass:[KKOnScreenControl class]]];
    [KKAIKnowledge
        registerBundleDocsWithName:@"Magic Move"
                            bundle:[NSBundle
                                       bundleForClass:[MagicMovePlugin class]]
                      subdirectory:@"AIKnowledge"];
    // Shared on-screen-control docs live in the kit framework (flattened to its
    // Resources root). Magic Move uses the rotation gizmo + the visibility
    // system, so expose just those two topics.
    [KKAIKnowledge
        registerBundleDocsWithName:@"On-Screen Controls"
                            bundle:[NSBundle
                                       bundleForClass:[KKOnScreenControl class]]
                      subdirectory:nil
                      onlyTopicIDs:@[ @"visibility", @"rotation" ]];
  });

  NSString *productContext = MMLoc(
      @"Magic Move, a Final Cut Pro plugin that animates a clip's position, "
      @"scale, rotation, and opacity around an adjustable anchor point, using "
      @"the shared Keyframeless timeline system (Basic and Advanced timing, "
      @"easing, motion blur). Always refer to yourself as Magic Move. Detailed "
      @"feature information is in the reference docs below.",
      @"AI assistant product context for Magic Move plugin.");

  NSArray<NSArray<NSString *> *> *examples = @[
    @[
      MMLoc(@"Slide in from the left",
            @"AI example chip: slide in from the left."),
      MMLoc(@"Animate the clip sliding in from off the left edge to the "
            @"centre over the first second.",
            @"AI example value: slide in from the left.")
    ],
    @[
      MMLoc(@"Spin once", @"AI example chip: spin once."),
      MMLoc(@"Spin the clip one full turn over the whole duration.",
            @"AI example value: spin once.")
    ],
    @[
      MMLoc(@"Pop in with a bounce", @"AI example chip: pop in with a bounce."),
      MMLoc(@"Scale the clip from 0% up to 100% with a bounce at the start.",
            @"AI example value: pop in with a bounce.")
    ],
    @[
      MMLoc(@"What does the anchor point do?",
            @"AI example chip: anchor point question."),
      MMLoc(@"What does the anchor point do?",
            @"AI example value: anchor point question.")
    ],
  ];

  NSString *placeholder = MMLoc(@"Ask a question or describe an animation…",
                                @"AI prompt field placeholder for Magic Move.");

  __weak typeof(self) weakSelf = self;
  return [KKAIBannerHost
      makePluginButtonWithProductContext:productContext
                            examplePairs:examples
                             placeholder:placeholder
                                   onRun:^(NSString *prompt) {
                                     __strong typeof(weakSelf) strong =
                                         weakSelf;
                                     if (!strong)
                                       return;
                                     [strong _runAIPrompt:prompt
                                           productContext:productContext];
                                   }];
}

- (void)_runAIPrompt:(NSString *)prompt
      productContext:(NSString *)productContext {
  [KKAIDraft setRouting:YES];
  [KKAIDraft setError:nil];

  id<FxCustomParameterActionAPI_v4> readAct =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!readAct) {
    [KKAIDraft setRouting:NO];
    [KKAIDraft setError:@"Couldn't open the FCP action scope."];
    return;
  }
  [readAct startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSString *currentJSON =
      KKTimelineAICurrentJSON(getAPI, [MagicMovePlugin availableLanes]);
  NSString *uiJson = KKReadCustomParamString(getAPI, kParamUIState);
  NSDictionary *uiState =
      (uiJson.length
           ? [NSJSONSerialization
                 JSONObjectWithData:[uiJson
                                        dataUsingEncoding:NSUTF8StringEncoding]
                            options:0
                              error:nil]
           : nil)
          ?: @{};
  NSInteger activeTab = [uiState[@"activeTab"] integerValue];
  NSString *currentMode = (activeTab == 1) ? @"Advanced" : @"Basic";
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  CMTime clipDur = kCMTimeZero;
  if (timingAPI)
    [timingAPI durationTimeForEffect:&clipDur];
  double clipDurSec = CMTimeGetSeconds(clipDur);
  if (clipDurSec <= 0 || isnan(clipDurSec))
    clipDurSec = 5.0;
  [readAct endAction:self];

  NSString *schema = _MagicMoveAILaneSchemaText();

  __weak typeof(self) weakSelf = self;
  [KKAIPluginAgent
             runWithPrompt:prompt
            productContext:productContext
            laneSchemaText:schema
       currentTimelineJSON:currentJSON
       clipDurationSeconds:clipDurSec
      currentInspectorMode:currentMode
                completion:^(KKAIPluginResult *result, NSError *err) {
                  dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) strong = weakSelf;
                    if (!strong)
                      return;
                    [KKAIDraft setRouting:NO];
                    if (err) {
                      KKLogError(@"AI[err] %@", err.localizedDescription);
                      [KKAIDraft setError:err.localizedDescription];
                      return;
                    }
                    if (!result) {
                      KKLogError(@"AI[err] empty result");
                      [KKAIDraft setError:@"Empty AI response."];
                      return;
                    }
                    if (result.kind == KKAIPluginResultKindAnswer) {
                      [KKAIDraft setAnswer:result.answer];
                      return;
                    }
                    // The merge also snaps final keyposes to the last
                    // renderable frame (FCP's last frame is one frame before
                    // the clip end, so a keypose at 1.0 is never reached) -
                    // clipDur from the prompt, frameDur from the process cache.
                    NSString *merged = KKTimelineAIMergeMutationJSON(
                        currentJSON, result.mutationJSON, clipDurSec,
                        KKProcessFrameDurationSeconds());
                    if (!merged) {
                      KKLogError(@"AI[err] merge returned nil");
                      [KKAIDraft
                          setError:
                              @"AI returned an invalid timeline mutation."];
                      return;
                    }
                    id<FxCustomParameterActionAPI_v4> writeAct =
                        [strong.apiManager
                            apiForProtocol:@protocol(
                                               FxCustomParameterActionAPI_v4)];
                    if (!writeAct) {
                      [KKAIDraft
                          setError:@"Couldn't open the FCP action scope to "
                                   @"apply the mutation."];
                      return;
                    }
                    [writeAct startAction:strong];
                    id<FxParameterSettingAPI_v5> setAPI = [strong.apiManager
                        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
                    KKWriteCustomParamString(setAPI, merged,
                                             kKKParamTimelineData);
                    // If the result isn't Basic-representable, force the
                    // inspector to Advanced so the user sees the real structure
                    // instead of the compatibility banner. The merge snaps the
                    // final keypose to outEndFrac, so pass that same end here.
                    KKTimeline *resultTimeline =
                        [KKTimeline timelineFromJSON:merged];
                    double mergeFrameDur = KKProcessFrameDurationSeconds();
                    double aiEndFrac =
                        (clipDurSec > 0.0 && mergeFrameDur > 0.0 &&
                         mergeFrameDur < clipDurSec)
                            ? (clipDurSec - mergeFrameDur) / clipDurSec
                            : 1.0;
                    if (resultTimeline && !KKTimelineIsBasicCompatible(
                                              resultTimeline, aiEndFrac)) {
                      [strong patchUIStateKey:@"activeTab"
                                        value:@(1)
                                      paramID:kParamUIState];
                    }
                    [writeAct endAction:strong];
                    [KKAIDraft setAnswer:nil];
                    [KKAIDraft clearPrompt];
                    // Light the green "done" sparkle so a fire-and-look-away
                    // run still has a confirmation waiting on return. Cleared
                    // when the user next opens the popover or types.
                    [KKAIDraft setCompleted:YES];
                  });
                }];
}

@end
