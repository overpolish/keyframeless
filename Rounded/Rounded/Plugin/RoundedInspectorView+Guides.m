/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "RoundedInspectorView+Guides.h"
#import "RoundedInspectorView_Private.h"
#import "RoundedLocalized.h"
#import <KeyframelessKit/KKHostInfo.h>
#import <KeyframelessKit/KKJoyrideDragStep.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKMiniCanvasGuideScroll.h>
#import <KeyframelessKit/KKMiniCanvasView.h>
#import <KeyframelessKit/KKOSCGuideBridge.h>
#import <KeyframelessKit/KKOSCGuideStrategy.h>
#import <KeyframelessKit/KKTimelineAdvancedView.h>
#import <KeyframelessKit/KKTimelineBasicView.h>
#import <KeyframelessKit/KKTimelineInspectorView+Guide.h>
#import <KeyframelessKit/KKTimelineLanesView+Guide.h>
#import <KeyframelessKit/KKTimelineLanesView.h>

static NSString *const kRoundedIntroSeenKey = @"RoundedIntroSeen";

// Snap tolerance (radius units) that counts as "hit" for the OSC guide target.
static const double kOSCGuideTargetSnap = 4.0;

// Radius the constants guide's final slider step asks the user to reach, and
// how close (radius units) counts as "there".
static const double kConstantsGuideTargetRadius = 80.0;
// Release tolerance for the slider step - forgiving enough to "land near 80"
// by hand (no mid-drag magnetism), then it snaps exactly onto 80.
static const double kConstantsGuideSliderSnap = 4.0;
// The mini-canvas (miniOSC) drag step targets a *different* radius than the
// slider step, with the same generous snap as the in-viewer OSC guide.
static const double kConstantsGuideS2Radius = 40.0;
// Magnetic-snap radius (screen points) around the amber target for the
// mini-canvas drag step - gentle so it doesn't grab from far away.
static const CGFloat kConstantsGuideSnapPx = 9.0;
// Gentle mid-drag magnet (radius units) so the slider knob sticks onto the
// target as it approaches - same feel as the miniOSC, but not grabby.
static const double kConstantsGuideSliderMagnet = 2.0;
// Crop drag step: drag the top-left handle (index 0 in KKCropPt order) to a
// centred 60% box. Target [w,h,x,y]; snap reuses kConstantsGuideSnapPx.
static const NSInteger kConstantsGuideCropHandleIdx = 0;
static NSArray<NSNumber *> *KKConstantsGuideCropTarget(void) {
  return @[ @0.6, @0.6, @0.0, @0.0 ];
}
// Final step: type this value (px) into the Crop X field; on match it
// auto-commits and the guide ends. Crop component index 2 = X.
static const NSInteger kConstantsGuideCropXComponent = 2;
static const double kConstantsGuideCropXTarget = 100.0;

@implementation RoundedInspectorView (Guides)

// One host serves all guides - they're mutually exclusive and share the same
// timeline accessor/applier + completion-callback wiring. Lazy so it picks up
// `self.basicLanesView` after the superclass finishes setting it up.
- (KKJoyrideGuideHost *)_guideHost {
  if (_guideHost)
    return _guideHost;
  _guideHost =
      [[KKJoyrideGuideHost alloc] initWithHostView:self
                                         lanesView:self.basicLanesView];
  __weak typeof(self) weak = self;
  _guideHost.currentTimelineProvider = ^KKTimeline * {
    __strong typeof(weak) s = weak;
    return s.basicLanesView.currentTimeline;
  };
  _guideHost.timelineApplier = ^(KKTimeline *tl) {
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    [s.basicLanesView applyTimeline:tl];
    if (s.onTimelineMutated)
      s.onTimelineMutated(tl);
  };
  _guideHost.onGuideCompleted = ^{
    __strong typeof(weak) s = weak;
    if (s.onGuideCompleted)
      s.onGuideCompleted();
  };
  return _guideHost;
}

- (void)_maybeAutostartIntroGuide {
  __weak typeof(self) weak = self;
  [[self _guideHost] autostartOnceWithSeenKey:kRoundedIntroSeenKey
      precondition:^BOOL {
        __strong typeof(weak) s = weak;
        return s && !s.isDetachedCopy &&
               s.basicLanesView.currentTimeline.lanes.count == 0;
      }
      start:^{
        __strong typeof(weak) s = weak;
        [s _startIntroGuide];
      }];
}

// The 3 inspector intro steps. Trigger plumbing (advance/dismiss/close-on-
// advance + passthrough-window lifecycle + payload capture) is delegated to
// `binder`; this method only builds the steps and binds them. Same steps drive
// the standalone intro guide and the combined walkthrough (different binders,
// different guides). displayTotal > 0 overrides the "of N" counter (used by
// the combined guide so numbering stays continuous across the inspector→OSC
// handoff).
- (NSArray<KKJoyrideStep *> *)_introStepsForGuide:(KKJoyrideController *)guide
                                     displayTotal:(NSInteger)displayTotal
                                           binder:
                                               (KKJoyrideLanesBinder *)binder {
  __weak KKTimelineLanesView *weakBasic = self.basicLanesView;
  __weak KKJoyrideLanesBinder *weakBinder = binder;

  KKJoyrideStep *s1 = [KKJoyrideStep
      stepWithMessage:RLoc(@"Tap <symbol plus.circle.fill color=accent /> to "
                           @"add an animated property",
                           @"Intro guide: add an animatable property.")
           targetView:^NSView * {
             __strong KKTimelineLanesView *b = weakBasic;
             return b.footerView;
           }];

  KKJoyrideStep *s2 = [KKJoyrideStep
      stepWithMessage:RLoc(@"Tap <accent>Radius</accent> to animate it",
                           @"Intro guide: tap Radius to make it animatable.")
           targetView:^NSView * {
             __strong KKJoyrideLanesBinder *b = weakBinder;
             return b.latestManagePopoverRow;
           }];

  KKJoyrideStep *s3 = [KKJoyrideStep
      stepWithMessage:RLoc(@"Drag the timeline to animate this property",
                           @"Intro guide: scrub the timeline to animate.")
           targetView:^NSView * {
             __strong KKJoyrideLanesBinder *b = weakBinder;
             return b.latestOptedInLaneRow;
           }];
  s3.showsNext = YES;

  if (displayTotal > 0)
    for (KKJoyrideStep *s in @[ s1, s2, s3 ])
      s.displayTotalSteps = displayTotal;

  [binder bindStep:s1
           atIndex:0
         advanceOn:[KKJoyrideTrigger managePopoverWillOpen]
         dismissOn:nil];
  [binder bindStep:s2
           atIndex:1
         advanceOn:[KKJoyrideTrigger laneOptedIn:nil]
         dismissOn:[KKJoyrideTrigger managePopoverClosed]];
  // Defer-close the manage popover after the lane is added (matches the
  // pre-binder pattern: sync close would cascade into applyTimeline: from the
  // toggle call stack and crash on the manage view).
  [binder setCloseOnAdvance:KKJoyrideCloseOnAdvanceManagePopover forStep:s2];

  return @[ s1, s2, s3 ];
}

// Autostart path: no seed (so the lanes the user creates during the guide
// persist after it ends - the host won't save+restore). The intro-seen flag
// is set in extraOnComplete regardless of skip vs complete, matching the
// pre-host behaviour.
- (void)_startIntroGuide {
  KKJoyrideGuideHost *host = [self _guideHost];
  host.forwardsGestures = NO;
  __weak typeof(self) weak = self;
  [host runWithSeed:nil
      buildSteps:^NSArray<KKJoyrideStep *> *(KKJoyrideController *guide,
                                             KKJoyrideLanesBinder *binder) {
        __strong typeof(weak) s = weak;
        return s ? [s _introStepsForGuide:guide displayTotal:0 binder:binder]
                 : @[];
      }
      extraOnComplete:^{
        [NSUserDefaults.standardUserDefaults setBool:YES
                                              forKey:kRoundedIntroSeenKey];
        [NSUserDefaults.standardUserDefaults synchronize];
      }];
}

// Manual restart: clears the intro-seen pref and seeds an empty timeline
// (the host saves the user's previous timeline and restores it on
// complete/skip).
- (void)restartIntroGuide {
  [NSUserDefaults.standardUserDefaults removeObjectForKey:kRoundedIntroSeenKey];
  [NSUserDefaults.standardUserDefaults synchronize];
  KKJoyrideGuideHost *host = [self _guideHost];
  host.forwardsGestures = NO;
  __weak typeof(self) weak = self;
  [host
      runWithSeed:^KKTimeline * {
        return [KKTimeline timeline];
      }
      buildSteps:^NSArray<KKJoyrideStep *> *(KKJoyrideController *guide,
                                             KKJoyrideLanesBinder *binder) {
        __strong typeof(weak) s = weak;
        return s ? [s _introStepsForGuide:guide displayTotal:0 binder:binder]
                 : @[];
      }
      extraOnComplete:^{
        [NSUserDefaults.standardUserDefaults setBool:YES
                                              forKey:kRoundedIntroSeenKey];
        [NSUserDefaults.standardUserDefaults synchronize];
      }];
}

// The point-OSC value mapping for the generic KKJoyrideOSCSegment: how a
// screen drag becomes a radius and back. This is the only OSC-shape-specific
// code the inspector still owns - a different OSC supplies its own strategy.
- (KKOSCGuideStrategy *)_pointOSCStrategy {
  __weak typeof(self) weak = self;
  __weak KKTimelineLanesView *weakBasic = self.basicLanesView;
  KKOSCGuideStrategy *s = [[KKOSCGuideStrategy alloc] init];
  s.captureAnchorAtScreen = ^(NSPoint pt) {
    RoundedOSCCaptureGuideAnchorAtScreen(pt);
  };
  s.currentValue = ^double {
    __strong typeof(weak) strong = weak;
    return strong ? [strong _guideCurrentRadius] : 20.0;
  };
  s.setLiveValue = ^(double v) {
    RoundedSetGuideRadius(v); // OSC handle tracks (blob unreadable in drawOSC)
  };
  s.valueForScreenPoint = ^double(NSPoint pt) {
    // Map the cursor to the radius that puts the OSC handle under it - the
    // OSC's own geometry, so the drag tracks the mouse 1:1 like a native drag.
    return RoundedGuideRadiusForScreenPoint(pt);
  };
  s.applyValue = ^(double v) {
    __strong typeof(weak) strong = weak;
    __strong KKTimelineLanesView *b = weakBasic;
    if (!strong || !b)
      return;
    RoundedSetGuideRadius(v);
    KKTimeline *tl = [strong _guideTimelineWithRadius:v];
    [b applyTimeline:tl];
    if (strong.onTimelineMutated)
      strong.onTimelineMutated(tl);
  };
  s.targetValue = kOSCGuideTargetRadius;
  s.snapTolerance = kOSCGuideTargetSnap;
  s.requireTargetHit = self.oscGuideRequireTargetHit;
  s.clickMessage = RLoc(
      @"Click the <accent>circle</accent> in the viewer to control the radius",
      @"OSC guide: click message for the radius circle.");
  s.dragMessage =
      RLoc(@"Drag toward the <warn>glowing target</warn>",
           @"Drag message shown for OSC and crop-corner guide steps.");
  s.selectedMessage = RLoc(
      @"The OSC is available whenever <accent>Rounded</accent> is selected",
      @"OSC guide: shown when the clip is selected.");
  // Point at THIS effect's FCP header (plugin-instance-scoped so multiple
  // effects each resolve their own); nil → floating tip.
  s.finalStepTargetRect = ^NSRect {
    __strong typeof(weak) strong = weak;
    NSRect (^p)(void) = strong.effectHeaderRectProvider;
    return p ? p() : NSZeroRect;
  };
  return s;
}

// The 2 OSC steps, now built by the generic segment from the point-OSC
// strategy + the shared bridge. displayBase/displayTotal offset the visible
// counter so it continues from the inspector portion; firstStepOnEnter runs
// the inspector→OSC crossover warm-up in the combined walkthrough.
- (NSArray<KKJoyrideStep *> *)_oscStepsForGuide:(KKJoyrideController *)guide
                                    displayBase:(NSInteger)displayBase
                                   displayTotal:(NSInteger)displayTotal
                               firstStepOnEnter:
                                   (nullable void (^)(void))firstStepOnEnter {
  KKJoyrideOSCSegment *segment =
      [[KKJoyrideOSCSegment alloc] initWithBridge:RoundedSharedOSCGuideBridge()
                                         strategy:[self _pointOSCStrategy]];
  [self _teardownOSCSegment];
  _oscSegment = segment; // MRR: own it until the guide's onComplete
  return [segment stepsForGuide:guide
                    displayBase:displayBase
                   displayTotal:displayTotal
               firstStepOnEnter:firstStepOnEnter];
}

- (void)_teardownOSCSegment {
  [_oscSegment teardown];
  _oscSegment = nil;
}

// Builds the guide's single-lane Radius timeline at the given value. The OSC
// reads radius from this blob (via parameterChanged → instance state), so
// writing it is the only channel that moves the on-screen control - the
// in-viewer OSC never receives events through the overlay and its API is nil
// outside FCP callbacks.
- (KKTimeline *)_guideTimelineWithRadius:(double)radius {
  KKTimeline *tl = [KKTimeline timeline];
  KKLane *radiusLane = [KKLane laneWithLabel:@"Radius"];
  // enabled == animatable (dropdown-only); the guide just sets a value.
  radiusLane.enabled = NO;
  radiusLane.valueType = KKLaneValueTypeFloat;
  radiusLane.componentMin = @[ @0.0 ];
  radiusLane.componentMax = @[ @100.0 ];
  KKKeyPose *kp = [KKKeyPose keyposeAtTime:0.0 values:@[ @(radius) ]];
  radiusLane.keyposes = @[ kp ];
  tl.lanes = @[ radiusLane ];
  return tl;
}

// Constants-guide seed: Radius + Crop both as constants so the popover shows
// the radius slider AND the crop box/handles + Crop W/H/X/Y fields (the new
// crop-drag and type-a-value steps need them). Mirrors the plugin's Crop
// lane template bounds. Kept separate from `_guideTimelineWithRadius:` so the
// OSC guide (which wants Radius only) is unaffected.
- (KKTimeline *)_constantsGuideSeedTimeline {
  KKTimeline *tl = [self _guideTimelineWithRadius:20.0];
  NSMutableArray<KKLane *> *lanes = [tl.lanes mutableCopy];
  KKLane *crop = [KKLane laneWithLabel:@"Crop"];
  crop.enabled = NO; // constant (not animatable)
  crop.valueType = KKLaneValueTypeCrop;
  crop.componentMin = @[ @0.0, @0.0, @-0.5, @-0.5 ];
  crop.componentMax = @[ @1.0, @1.0, @0.5, @0.5 ];
  crop.keyposes = @[ [KKKeyPose keyposeAtTime:0.0
                                       values:@[ @1.0, @1.0, @0.0, @0.0 ]] ];
  [lanes addObject:crop];
  tl.lanes = lanes;
  return tl;
}

- (double)_guideCurrentRadius {
  for (KKLane *lane in self.basicLanesView.currentTimeline.lanes) {
    if ([lane.label isEqualToString:@"Radius"] && lane.keyposes.count > 0) {
      KKKeyPose *kp = lane.keyposes.firstObject;
      if (kp.values.count > 0)
        return [kp.values.firstObject doubleValue];
    }
  }
  return 20.0;
}

- (BOOL)oscGuideActive {
  return _oscGuideActive;
}

- (void)restartOSCGuide {
  // Step 1: spotlight on the handle, no target yet. The press bumps to OSC
  // step 2 (in spotlightMouseDown) which reveals the target - the handle
  // already follows sGuideRadius at any step > 0.
  RoundedSetOSCGuideStep(1);
  // The OSC handle reads sGuideRadius during the guide; reset it so a new
  // guide starts at the default and doesn't remember the last drag.
  RoundedSetGuideRadius(20.0);

  KKJoyrideGuideHost *host = [self _guideHost];
  host.forwardsGestures = NO;
  _oscGuideActive = YES;

  // The host runs the zoom-to-fit + settle warm-up, then starts these steps.
  __weak typeof(self) weak = self;
  [host runOSCGuideWithSeed:[self _guideTimelineWithRadius:20.0]
      buildSteps:^NSArray<KKJoyrideStep *> *(KKJoyrideController *guide,
                                             KKJoyrideLanesBinder *binder) {
        __strong typeof(weak) s = weak;
        return s ? [s _oscStepsForGuide:guide
                            displayBase:0
                           displayTotal:3
                       firstStepOnEnter:nil]
                 : @[];
      }
      extraOnComplete:^{
        __strong typeof(self) s = weak;
        if (!s)
          return;
        RoundedSetOSCGuideStep(0);
        [s _teardownOSCSegment];
        s->_oscGuideActive = NO;
      }];
}

// Crossover into the OSC portion: the user finished the inspector portion and
// the first OSC step just became active. Zoom-to-fit already ran up front (in
// restartFullWalkthroughGuide) so FCP's focus steal happened before the
// overlay existed - here we only do the focus-free work: enable the OSC guide
// visuals and seed a clean Radius-only timeline (the drag math needs one
// Radius lane). That param write retriggers drawOSC at the already-fitted
// geometry, and the position observer's refreshSpotlight reveals the cutout.
- (void)_enterFullWalkthroughOSCPortion {
  RoundedSetOSCGuideStep(1);
  RoundedSetGuideRadius(20.0);
  KKTimeline *clean = [self _guideTimelineWithRadius:20.0];
  [self.basicLanesView applyTimeline:clean];
  if (self.onTimelineMutated)
    self.onTimelineMutated(clean);
}

- (void)_teardownConstantsScrollMonitors {
  [_constantsScrollFwd teardown];
  _constantsScrollFwd = nil;
}

// Scroll/pinch routing during the guide now lives in the reusable
// KKMiniCanvasGuideScroll (any plugin's mini-canvas guide gets it). It
// forwards to the canvas only while the constants guide is active and the
// pointer is over the canvas. (Magnify monitors are the real pinch carrier -
// see [[project_joyride_xpc_popover_gestures]].)
- (void)_installConstantsScrollMonitorsForCanvas:(KKMiniCanvasView *)canvas {
  [self _teardownConstantsScrollMonitors];
  __weak typeof(self) weak = self;
  _constantsScrollFwd =
      [[KKMiniCanvasGuideScroll alloc] initWithCanvas:canvas
                                           activeWhen:^BOOL {
                                             __strong typeof(self) s = weak;
                                             return s && s->_guideHost.isActive;
                                           }];
  [_constantsScrollFwd install];
}

// The 5 constants steps, all inspector-side (no viewer OSC / focus steal):
// open the Constants popover, drag the mini-canvas radius handle (the
// "miniOSC"), zoom/pan the preview, double-click to reset it, then drag the
// slider to 80. The popover/canvas hooks added to KKTimelineLanesView drive
// the advances; nothing here is Rounded-shape-specific except the "Radius"
// label and the target value.
- (NSArray<KKJoyrideStep *> *)
    _constantsStepsForGuide:(KKJoyrideController *)guide
                     binder:(KKJoyrideLanesBinder *)binder {
  __weak typeof(self) weak = self;
  __weak KKJoyrideController *weakGuide = guide;
  __weak KKJoyrideLanesBinder *weakBinder = binder;
  // Step indices in one place (order is fixed) so gates don't churn when the
  // sequence changes. ixLast drives "final step → dismiss vs advance".
  const NSInteger ixConstants = 0, ixRadius = 1, ixCrop = 2, ixZoom = 3,
                  ixReset = 4, ixSlider = 5, ixTypeX = 6, ixLast = 6;

  KKJoyrideStep *s1 = [KKJoyrideStep
      stepWithMessage:RLoc(@"Tap <accent>Constants</accent> to edit values "
                           @"that don't change over time",
                           @"Constants guide: open the Constants editor.")
           targetView:^NSView * {
             __strong typeof(self) s = weak;
             return s ? s.constantsButton : nil;
           }];

  // The two mini-canvas drags (radius dot, crop corner) and the slider are
  // the same OSC-Basics capture-drag pattern, built from KKJoyrideDragStep:
  // it owns the press latch, target reveal, message swap, magnetic snap and
  // advance/dismiss gate; here we only supply the control-specific blocks.
  // Both mini-canvas drags share the renderer's generic screen-point handle
  // path (the crop one is routed to the crop editor's corner).
  NSRect (^s2Target)(void) = ^NSRect {
    __strong KKMiniCanvasView *c = weakBinder.latestMiniCanvas;
    return c ? [c pointHandleScreenRectForValue:kConstantsGuideS2Radius]
             : NSZeroRect;
  };
  KKJoyrideStep *s2 = [KKJoyrideDragStep stepForGuide:guide
      atIndex:ixRadius
      isLast:(ixRadius == ixLast)
      clickMessage:
          RLoc(@"Click the <accent>dot</accent> to set the corner radius",
               @"Constants guide: click message for the radius dot.")
      dragMessage:
          RLoc(@"Drag toward the <warn>glowing target</warn>",
               @"Drag message shown for OSC and crop-corner guide steps.")
      circular:YES
      spotRect:^NSRect {
        __strong KKMiniCanvasView *c = weakBinder.latestMiniCanvas;
        return c ? [c pointHandleScreenRect] : NSZeroRect;
      }
      targetRect:s2Target
      begin:^(NSPoint p) {
        [weakBinder.latestMiniCanvas beginPointHandleDragAtScreenPoint:p];
      }
      dragTo:^(NSPoint p) {
        [weakBinder.latestMiniCanvas
            dragPointHandleToScreenPoint:KKJoyrideSnapToTarget(
                                             p, s2Target(),
                                             kConstantsGuideSnapPx)];
      }
      end:^{
        [weakBinder.latestMiniCanvas endPointHandleDrag];
      }
      hitOnRelease:^BOOL(NSPoint p) {
        NSRect t = s2Target();
        double dpx =
            NSIsEmptyRect(t) ? 1e9 : hypot(p.x - NSMidX(t), p.y - NSMidY(t));
        // By value OR screen proximity (covers a stale last-tick value).
        NSArray<NSNumber *> *latest =
            [weakBinder latestStaticValueForLabel:@"Radius"];
        double r = latest.count ? latest.firstObject.doubleValue : -1.0;
        return fabs(r - kConstantsGuideS2Radius) <= kOSCGuideTargetSnap ||
               dpx <= kConstantsGuideSnapPx;
      }];

  NSRect (^cropTarget)(void) = ^NSRect {
    __strong KKMiniCanvasView *c = weakBinder.latestMiniCanvas;
    return c ? [c cropHandleScreenRectAtIndex:kConstantsGuideCropHandleIdx
                                forCropValues:KKConstantsGuideCropTarget()]
             : NSZeroRect;
  };
  KKJoyrideStep *sCrop = [KKJoyrideDragStep stepForGuide:guide
      atIndex:ixCrop
      isLast:(ixCrop == ixLast)
      clickMessage:RLoc(@"Click the <accent>top-left</accent> crop corner",
                        @"Constants guide: click message for the crop corner.")
      dragMessage:RLoc(
                      @"Drag the corner toward the <warn>glowing target</warn>",
                      @"Constants guide: drag message for the crop corner.")
      circular:YES
      spotRect:^NSRect {
        __strong KKMiniCanvasView *c = weakBinder.latestMiniCanvas;
        return c ? [c cropHandleScreenRectAtIndex:kConstantsGuideCropHandleIdx]
                 : NSZeroRect;
      }
      targetRect:cropTarget
      begin:^(NSPoint p) {
        [weakBinder.latestMiniCanvas beginPointHandleDragAtScreenPoint:p];
      }
      dragTo:^(NSPoint p) {
        [weakBinder.latestMiniCanvas
            dragPointHandleToScreenPoint:KKJoyrideSnapToTarget(
                                             p, cropTarget(),
                                             kConstantsGuideSnapPx)];
      }
      end:^{
        [weakBinder.latestMiniCanvas endPointHandleDrag];
      }
      hitOnRelease:^BOOL(NSPoint p) {
        NSRect t = cropTarget();
        double dpx =
            NSIsEmptyRect(t) ? 1e9 : hypot(p.x - NSMidX(t), p.y - NSMidY(t));
        return dpx <= kConstantsGuideSnapPx;
      }];

  KKJoyrideStep *s3 = [KKJoyrideStep
      stepWithMessage:RLoc(
                          @"Scroll to <accent>zoom</accent>, two-finger drag "
                          @"to <accent>pan</accent> the preview",
                          @"Constants guide: zoom/pan the mini-canvas preview.")
           targetView:^NSView * {
             return weakBinder.latestMiniCanvas;
           }];
  s3.spotlightMagnifyEvent = ^(NSEvent *e) {
    [weakBinder.latestMiniCanvas applyMagnifyEvent:e];
  };

  KKJoyrideStep *s4 = [KKJoyrideStep
      stepWithMessage:
          RLoc(@"<accent>Double-click</accent> the preview to reset the view",
               @"Constants guide: reset the mini-canvas zoom/pan.")
           targetView:^NSView * {
             return weakBinder.latestMiniCanvas;
           }];

  // The slider has a modal tracking loop, so (unlike pan/scroll) its drag
  // can't be forwarded - capture it and drive the constant through the
  // popover's coalesced channel. Same KKJoyrideDragStep factory, slider
  // variant: target shown immediately (no press-gated reveal, dragMessage
  // nil) and not circular. The map uses the slider's own screen geometry so
  // the amber target sits on the real track; the gentle magnet lives in
  // valueForX, with an exact snap-onto-80 on release.
  double (^valueForX)(CGFloat) = ^double(CGFloat x) {
    __strong typeof(self) s = weak;
    if (!s)
      return 0.0;
    double v = [s.basicLanesView guideConstantSliderValueForScreenX:x
                                                           forLabel:@"Radius"];
    if (fabs(v - kConstantsGuideTargetRadius) <= kConstantsGuideSliderMagnet)
      v = kConstantsGuideTargetRadius;
    return v;
  };
  __block double s5Last = -1.0;
  KKJoyrideStep *s5 = [KKJoyrideDragStep stepForGuide:guide
      atIndex:ixSlider
      isLast:(ixSlider == ixLast)
      clickMessage:RLoc(@"Drag the slider to the <warn>target</warn> (80)",
                        @"Constants guide: drag a slider to a target value.")
      dragMessage:nil
      circular:NO
      spotRect:^NSRect {
        // Spotlight the knob at its current value - the actual grab point -
        // not the whole track/row. The cutout is drawn as a capsule anchored
        // at the spot's CENTRE (radius = its short dimension), so a wide
        // control collapses to a circle at the track midpoint and the thumb
        // (sitting off-centre at the value) falls outside it. Tracking the
        // knob keeps the cutout on the thumb wherever it is - same as the
        // keypose-diamond step, whose spot already is the thing you grab.
        __strong typeof(self) s = weak;
        return s ? [s.basicLanesView
                       guideConstantSliderKnobScreenRectForLabel:@"Radius"]
                 : NSZeroRect;
      }
      targetRect:^NSRect {
        __strong typeof(self) s = weak;
        if (!s)
          return NSZeroRect;
        NSRect tr = [s.basicLanesView
            guideConstantSliderTrackScreenRectForLabel:@"Radius"];
        if (NSIsEmptyRect(tr))
          return NSZeroRect;
        CGFloat x = [s.basicLanesView
            guideConstantSliderScreenXForValue:kConstantsGuideTargetRadius
                                      forLabel:@"Radius"];
        CGFloat r = 7.0;
        return NSMakeRect(x - r, NSMidY(tr) - r, 2 * r, 2 * r);
      }
      begin:^(NSPoint p) {
        __strong typeof(self) s = weak;
        s5Last = valueForX(p.x);
        [s.basicLanesView beginGuideConstantDrag];
        [s.basicLanesView applyGuideConstantValues:@[ @(s5Last) ]
                                          forLabel:@"Radius"];
      }
      dragTo:^(NSPoint p) {
        __strong typeof(self) s = weak;
        s5Last = valueForX(p.x);
        [s.basicLanesView applyGuideConstantValues:@[ @(s5Last) ]
                                          forLabel:@"Radius"];
      }
      end:^{
        __strong typeof(self) s = weak;
        if (fabs(s5Last - kConstantsGuideTargetRadius) <=
            kConstantsGuideSliderSnap)
          [s.basicLanesView
              applyGuideConstantValues:@[ @(kConstantsGuideTargetRadius) ]
                              forLabel:@"Radius"];
        [s.basicLanesView endGuideConstantDrag];
      }
      hitOnRelease:^BOOL(NSPoint p) {
        return fabs(s5Last - kConstantsGuideTargetRadius) <=
               kConstantsGuideSliderSnap;
      }];

  // Final step: click into the Crop X field and type the target value. No
  // capture - a normal forwarded click focuses the field, the user types,
  // and the live-keystroke handler (set in willOpen) auto-commits + ends
  // the guide when the value matches.
  KKJoyrideStep *sX = [KKJoyrideStep
      stepWithMessage:
          RLoc(@"Click the <accent>X</accent> field and type <warn>100</warn>",
               @"Constants guide: type a value into the X field.")
           targetView:nil];
  sX.targetScreenRect = ^NSRect {
    __strong typeof(self) s = weak;
    return s ? [s.basicLanesView
                   guideConstantFieldScreenRectForLabel:@"Crop"
                                              component:
                                                  kConstantsGuideCropXComponent]
             : NSZeroRect;
  };

  // Advance/dismiss plumbing: declarative via the binder. The drag steps
  // (s2/sCrop/s5) self-advance through KKJoyrideDragStep's hitOnRelease; the
  // staticValueDragEnded:@"Radius" trigger on s2 is a belt-and-braces fallback
  // matching the pre-binder behaviour.
  [binder bindStep:s1
           atIndex:ixConstants
         advanceOn:[KKJoyrideTrigger staticValuesPopoverWillOpen]
         dismissOn:nil];
  [binder bindStep:s2
           atIndex:ixRadius
         advanceOn:[KKJoyrideTrigger staticValueDragEndedForLabel:@"Radius"]
         dismissOn:nil];
  [binder bindStep:s3
           atIndex:ixZoom
         advanceOn:[KKJoyrideTrigger miniCanvasViewTransformChanged]
         dismissOn:nil];
  [binder bindStep:s4
           atIndex:ixReset
         advanceOn:[KKJoyrideTrigger miniCanvasViewReset]
         dismissOn:nil];
  // Every step dismisses if the static-values popover closes mid-tour. Apply
  // to ALL steps that need the popover open (s1's dismiss is a no-op because
  // s1 advances on willOpen anyway, but binding it on s2..sX is what matters).
  for (NSInteger i = ixRadius; i <= ixTypeX; i++) {
    NSArray<KKJoyrideStep *> *steps = @[ s2, sCrop, s3, s4, s5, sX ];
    NSInteger which = i - ixRadius;
    if (which >= (NSInteger)steps.count)
      break;
    if (i == ixRadius || i == ixZoom || i == ixReset)
      continue; // these already have a binding above; rebind dismiss separately
    [binder bindStep:steps[which]
             atIndex:i
           advanceOn:nil
           dismissOn:[KKJoyrideTrigger staticValuesPopoverClosed]];
  }

  // Plugin-side work that needs the popover content/canvas live: install the
  // scroll forwarder + the Crop-X field handler. Routed via the binder's
  // relay so callback ownership stays with the binder.
  binder.staticValuesPopoverDidOpen = ^(NSView *content, KKMiniCanvasView *cv) {
    __strong typeof(self) s = weak;
    if (!s)
      return;
    if (cv)
      [s _installConstantsScrollMonitorsForCanvas:cv];
    [s.basicLanesView
        setGuideConstantFieldEditHandlerForLabel:@"Crop"
                                         handler:^(NSInteger comp,
                                                   double disp) {
                                           __strong KKJoyrideController *gg =
                                               weakGuide;
                                           __strong typeof(self) hs = weak;
                                           if (!gg || !hs || !gg.isActive ||
                                               gg.currentStepIndex != ixTypeX)
                                             return;
                                           if (comp !=
                                               kConstantsGuideCropXComponent)
                                             return;
                                           if (fabs(
                                                   disp -
                                                   kConstantsGuideCropXTarget) <
                                               0.5) {
                                             [hs.basicLanesView
                                                 commitGuideConstantFieldForLabel:
                                                     @"Crop"
                                                                        component:
                                                                            kConstantsGuideCropXComponent];
                                             [gg dismiss]; // final → completed
                                           }
                                         }];
  };

  return @[ s1, s2, sCrop, s3, s4, s5, sX ];
}

- (void)restartConstantsGuide {
  KKJoyrideGuideHost *host = [self _guideHost];
  // Let the panel receive pinch so s3 can forward it to the mini-canvas;
  // clicks still pass via the global-monitor synthesize path.
  host.forwardsGestures = YES;
  // Single-frame preview while teaching the constant handles; restore the
  // user's filmstrip/onion choice on completion (plain setter, no persistence).
  KKMiniCanvasRenderMode priorRenderMode = self.basicLanesView.renderMode;
  self.basicLanesView.renderMode = KKMiniCanvasRenderModeOff;
  __weak typeof(self) weak = self;
  [host
      runWithSeed:^KKTimeline * {
        // Teach on a known state: Radius + Crop both constant so the popover
        // shows the radius slider + handle AND the crop box/handles + X field.
        __strong typeof(weak) s = weak;
        return s ? [s _constantsGuideSeedTimeline] : nil;
      }
      buildSteps:^NSArray<KKJoyrideStep *> *(KKJoyrideController *guide,
                                             KKJoyrideLanesBinder *binder) {
        __strong typeof(weak) s = weak;
        return s ? [s _constantsStepsForGuide:guide binder:binder] : @[];
      }
      extraOnComplete:^{
        __strong typeof(weak) s = weak;
        [s _teardownConstantsScrollMonitors];
        s.basicLanesView.renderMode = priorRenderMode;
      }];
}

// Chunk-1 Basic Timing guide: open the "+" footer popover, add Crop and
// Radius, then toggle the In transition on. All advances come from existing
// KKTimelineLanesView callbacks (onManagePopoverWillOpen / onLaneOptedIn)
// plus the new KKTimelineBasicView onPhaseToggled hook; cutouts use the
// new screen-rect helpers in the +Guide categories.
- (NSArray<KKJoyrideStep *> *)
    _basicTimingStepsForGuide:(KKJoyrideController *)guide
                       binder:(KKJoyrideLanesBinder *)binder {
  __weak typeof(self) weak = self;
  __weak KKTimelineLanesView *weakBasic = self.basicLanesView;
  __weak KKTimelineBasicView *weakGraph = self.basicLanesView.basicGraph;
  __weak KKJoyrideController *weakGuide = guide;
  __weak KKJoyrideLanesBinder *weakBinder = binder;

  const NSInteger ixIntro = 0, ixPlay = 1, ixAdd = 2, ixAddCrop = 3,
                  ixAddRadius = 4, ixPhasesIntro = 5, ixToggleIn = 6,
                  ixGraphNotice = 7, ixDiamondClick = 8, ixMiniViewer = 9,
                  ixCropRadius = 10, ixGapClick = 11, ixSpringPick = 12,
                  ixDragDiamond = 13, ixWatchBack = 14, ixDone = 15;
  (void)ixIntro;
  (void)ixPhasesIntro;
  (void)ixGraphNotice;
  (void)ixMiniViewer;
  (void)ixDone;

  // Step 15: auto-pause this long after the user starts playback before
  // advancing - long enough to see a beat of the animation, short enough
  // that the demo doesn't feel like it's stalled.
  const double kWatchBackSeconds = 1.0;

  // Step 14: drag the In-end diamond to t=0.8s. Snap window in seconds -
  // both for the gentle in-drag magnet and the final release tolerance.
  const double kDragTargetSeconds = 0.8;
  const double kDragSnapSeconds = 0.05;
  const CGFloat kDragSnapPx = 14.0;

  // KKIntervalCurveElastic == 4 (Linear=0, EaseIn=1, EaseOut=2, EaseInOut=3,
  // Elastic=4, Bounce=5) - what we present to users as the "Spring" curve.
  const NSInteger kSpringCurveType = 4;

  // Diamond 2 (hold-start) - chronologically the second visible keypose
  // once the In transition is on (the diamonds the user just saw appear).
  const NSInteger kDiamondTarget = 2;
  __block BOOL cropChanged = NO, radiusChanged = NO;

  KKJoyrideStep *s1 = [KKJoyrideStep
      stepWithMessage:
          RLoc(@"Here is where you edit the <accent>timing</accent> of things",
               @"Basic timing guide: intro to the timing editor.")
           targetView:^NSView * {
             __strong KKTimelineBasicView *g = weakGraph;
             __strong KKTimelineLanesView *b = weakBasic;
             return g ?: (NSView *)b;
           }];
  s1.showsNext = YES;

  // Step 2: click to play, then click again to pause - advances on the
  // pause edge. Useful demo when the spacebar shortcut isn't working.
  KKJoyrideStep *sPlay = [KKJoyrideStep
      stepWithMessage:RLoc(
                          @"Click <symbol play.fill color=accent /> to play, "
                          @"then again to <accent>pause</accent> - handy when "
                          @"<warn>spacebar</warn> isn't working",
                          @"Basic timing guide: play/pause from the inspector.")
           targetView:nil];
  sPlay.targetScreenRect = ^NSRect {
    __strong typeof(self) s = weak;
    return s ? [s guidePlayButtonScreenRect] : NSZeroRect;
  };

  KKJoyrideStep *s2 = [KKJoyrideStep
      stepWithMessage:
          RLoc(@"Tap <symbol plus.circle.fill color=accent /> to add "
               @"<accent>Crop</accent> and <accent>Radius</accent> for "
               @"animation",
               @"Basic timing guide: add Crop and Radius for animation.")
           targetView:^NSView * {
             __strong KKTimelineLanesView *b = weakBasic;
             return b.footerView;
           }];

  KKJoyrideStep *s3 = [KKJoyrideStep
      stepWithMessage:RLoc(@"Tap <accent>Crop</accent>",
                           @"Basic timing guide: tap the Crop property.")
           targetView:nil];
  s3.targetScreenRect = ^NSRect {
    __strong KKTimelineLanesView *b = weakBasic;
    return b ? [b guideManagePopoverItemScreenRectForLabel:@"Crop"]
             : NSZeroRect;
  };

  KKJoyrideStep *s4 = [KKJoyrideStep
      stepWithMessage:RLoc(@"Tap <accent>Radius</accent>",
                           @"Basic timing guide: tap the Radius property.")
           targetView:nil];
  s4.targetScreenRect = ^NSRect {
    __strong KKTimelineLanesView *b = weakBasic;
    return b ? [b guideManagePopoverItemScreenRectForLabel:@"Radius"]
             : NSZeroRect;
  };

  KKJoyrideStep *s5 = [KKJoyrideStep
      stepWithMessage:
          RLoc(@"Basic timing has three phases: <accent>In</accent>, "
               @"<accent>Hold</accent>, and <accent>Out</accent>",
               @"Basic timing guide: explains the three phases.")
           targetView:^NSView * {
             __strong KKTimelineBasicView *g = weakGraph;
             return g;
           }];
  s5.showsNext = YES;

  KKJoyrideStep *s6 = [KKJoyrideStep
      stepWithMessage:RLoc(@"Turn on the <accent>In</accent> transition",
                           @"Basic timing guide: enable the In transition.")
           targetView:nil];
  s6.targetScreenRect = ^NSRect {
    __strong KKTimelineBasicView *g = weakGraph;
    return g ? [g guidePhaseToggleScreenRectForPhase:0] : NSZeroRect;
  };

  KKJoyrideStep *sGraph = [KKJoyrideStep
      stepWithMessage:
          RLoc(@"Notice the <accent>graph</accent> has updated to show the "
               @"general movement",
               @"Basic timing guide: the easing graph reflects the transition.")
           targetView:^NSView * {
             __strong KKTimelineBasicView *g = weakGraph;
             return g;
           }];
  sGraph.showsNext = YES;

  KKJoyrideStep *sDiamond = [KKJoyrideStep
      stepWithMessage:RLoc(@"Click one of the <accent>diamonds</accent> to "
                           @"edit values at that point in time",
                           @"Basic timing guide: edit a keypose diamond.")
           targetView:nil];
  sDiamond.targetScreenRect = ^NSRect {
    __strong KKTimelineBasicView *g = weakGraph;
    return g ? [g guideDiamondScreenRectForIndex:kDiamondTarget] : NSZeroRect;
  };

  KKJoyrideStep *sMini = [KKJoyrideStep
      stepWithMessage:RLoc(@"This <accent>mini viewer</accent> shows the clip "
                           @"at this point in time - no need to scrub around",
                           @"Advanced timing guide: the keypose mini viewer.")
           targetView:^NSView * {
             return weakBinder.latestMiniCanvas;
           }];
  sMini.showsNext = YES;

  // Drag the radius dot OR a crop corner inside the boundary popover -
  // same canvas API the constants guide uses for radius/crop drags, so the
  // popover's onDragBegin/onHandleValue/onDragEnd fire in a clean pair (no
  // leaked action scopes). Advances once both Crop AND Radius have been
  // changed (tracked via onStaticValueChanged below).
  KKJoyrideStep *sEdit = [KKJoyrideStep
      stepWithMessage:
          RLoc(@"Drag the <accent>dot</accent> for Radius or a "
               @"<accent>corner</accent> for Crop",
               @"Basic timing guide: edit values in the mini viewer.")
           targetView:nil];
  sEdit.spotlightCircular = NO;
  sEdit.spotlightPassThrough = YES;
  sEdit.targetScreenRect = ^NSRect {
    __strong NSView *content = weakBinder.latestStaticValuesPopoverContent;
    NSWindow *w = content.window;
    if (!content || !w)
      return NSZeroRect;
    return [w convertRectToScreen:[content convertRect:content.bounds
                                                toView:nil]];
  };
  sEdit.spotlightMouseDown = ^(NSPoint p) {
    [weakBinder.latestMiniCanvas beginPointHandleDragAtScreenPoint:p];
  };
  sEdit.spotlightMouseDragged = ^(NSPoint p) {
    [weakBinder.latestMiniCanvas dragPointHandleToScreenPoint:p];
  };
  sEdit.spotlightMouseUp = ^(NSPoint p) {
    [weakBinder.latestMiniCanvas endPointHandleDrag];
  };
  sEdit.onEnter = ^{
    cropChanged = NO;
    radiusChanged = NO;
  };

  KKJoyrideStep *sGap = [KKJoyrideStep
      stepWithMessage:
          RLoc(
              @"Click the <accent>gap</accent> between keyposes to edit timing",
              @"Advanced timing guide: click a gap segment.")
           targetView:nil];
  sGap.targetScreenRect = ^NSRect {
    __strong KKTimelineBasicView *g = weakGraph;
    return g ? [g guideGapScreenRectForSection:1 /* KKBasicSectionIn */]
             : NSZeroRect;
  };

  // No spotlightPassThrough - that sends the click to FCP. We want it
  // forwarded to the XPC popover so the pill receives it (same path as the
  // Crop/Radius row click in the animated-dropdown popover).
  // Step 14: drag diamond 2 (Hold-start / In-end) toward 0.8s on the
  // timeline. Same KKJoyrideDragStep snap pattern the constants slider uses.
  NSRect (^dragSpotRect)(void) = ^NSRect {
    __strong KKTimelineBasicView *g = weakGraph;
    return g ? [g guideDiamondScreenRectForIndex:2] : NSZeroRect;
  };
  NSRect (^dragTargetRect)(void) = ^NSRect {
    __strong KKTimelineBasicView *g = weakGraph;
    return g ? [g guideDiamondScreenRectAtTimeSeconds:kDragTargetSeconds
                                           forDiamond:2]
             : NSZeroRect;
  };
  KKJoyrideStep *sDrag = [KKJoyrideDragStep stepForGuide:guide
      atIndex:ixDragDiamond
      isLast:NO
      clickMessage:
          RLoc(@"Drag the <accent>diamond</accent> toward the <warn>glowing "
               @"target</warn> (0.8s)",
               @"Basic timing guide: drag a keypose diamond to a target time.")
      dragMessage:nil
      circular:YES
      spotRect:dragSpotRect
      targetRect:dragTargetRect
      begin:^(NSPoint p) {
        [weakGraph guideBeginDragDiamondAtIndex:2 atScreenPoint:p];
      }
      dragTo:^(NSPoint p) {
        // Magnetic snap onto target during the drag (same feel as the
        // constants mini-canvas snap).
        NSPoint snapped =
            KKJoyrideSnapToTarget(p, dragTargetRect(), kDragSnapPx);
        [weakGraph guideDragDiamondToScreenPoint:snapped];
      }
      end:^{
        [weakGraph guideEndDiamondDrag];
      }
      hitOnRelease:^BOOL(NSPoint p) {
        double now = [weakGraph guideCurrentDiamondTimeSecondsForIndex:2];
        if (isnan(now))
          return NO;
        return fabs(now - kDragTargetSeconds) <= kDragSnapSeconds;
      }];

  KKJoyrideStep *sWatchBack = [KKJoyrideStep
      stepWithMessage:RLoc(@"Let's <accent>watch it back</accent> - click play",
                           @"Basic timing guide: play back the animation.")
           targetView:nil];
  // Cutout encompasses both the play button AND the FCP viewer (when the OSC
  // is alive - the shared bridge gives us the viewer image rect). Non-
  // circular so the wide bounding box renders sensibly.
  sWatchBack.spotlightCircular = NO;
  sWatchBack.targetScreenRect = ^NSRect {
    __strong typeof(self) s = weak;
    NSRect play = s ? [s guidePlayButtonScreenRect] : NSZeroRect;
    NSRect viewer = RoundedSharedOSCGuideBridge().estimatedViewerScreenRect;
    if (NSIsEmptyRect(viewer))
      return play;
    if (NSIsEmptyRect(play))
      return viewer;
    return NSUnionRect(play, viewer);
  };
  // Reset playhead to clip start before the user hits play, so they always
  // watch from the beginning. onScrub is wired to the host's
  // movePlayheadToTime: (FxCommandAPI), same as restartBasicTimingGuide.
  __block BOOL watchBackScheduled = NO;
  sWatchBack.onEnter = ^{
    __strong typeof(self) s = weak;
    watchBackScheduled = NO;
    if (s && s.onScrub)
      s.onScrub(0.0);
    // Wake up the OSC so the bridge gets a draw tick → its
    // estimatedViewerScreenRect populates and the cutout can union the
    // viewer with the play button. Same nudge the boundary popover uses
    // to force a render when the playhead is static.
    if (s && s.onBoundaryPreviewNeedsRender)
      s.onBoundaryPreviewNeedsRender();
  };

  KKJoyrideStep *sDone = [KKJoyrideStep
      stepWithMessage:RLoc(@"That's all you need to know to get going!",
                           @"Basic timing guide: closing step.")
           targetView:^NSView * {
             __strong KKTimelineBasicView *g = weakGraph;
             return g;
           }];

  KKJoyrideStep *sSpring = [KKJoyrideStep
      stepWithMessage:
          RLoc(@"Pick the <accent>Spring</accent> curve",
               @"Basic timing guide: choose the Spring easing curve.")
           targetView:nil];
  sSpring.targetScreenRect = ^NSRect {
    __strong KKSegmentEditView *e = weakBinder.latestGapSegmentEditor;
    return e ? [e guideCurvePillScreenRectForCurve:kSpringCurveType]
             : NSZeroRect;
  };

  // Declarative advance/dismiss via the binder. The "armed" diamond/gap →
  // popover-open patterns are now `thenWaitFor:`; the sPlay play→pause edge is
  // the binder's `playToggleEdge` - driven by deterministic play-button taps
  // (not the poll-inferred play state, which flickers under FCP's bursty
  // currentTime mid-guide and would auto-advance the step). sWatchBack's timed
  // auto-advance and sEdit's multi-signal AND stay plugin-side.
  [binder bindStep:sPlay
           atIndex:ixPlay
         advanceOn:[KKJoyrideTrigger playToggleEdge]
         dismissOn:nil];
  [binder bindStep:s2
           atIndex:ixAdd
         advanceOn:[KKJoyrideTrigger managePopoverWillOpen]
         dismissOn:nil];
  [binder bindStep:s3
           atIndex:ixAddCrop
         advanceOn:[KKJoyrideTrigger laneOptedIn:@"Crop"]
         dismissOn:[KKJoyrideTrigger managePopoverClosed]];
  [binder bindStep:s4
           atIndex:ixAddRadius
         advanceOn:[KKJoyrideTrigger laneOptedIn:@"Radius"]
         dismissOn:[KKJoyrideTrigger managePopoverClosed]];
  [binder setCloseOnAdvance:KKJoyrideCloseOnAdvanceManagePopover forStep:s4];
  [binder bindStep:s6
           atIndex:ixToggleIn
         advanceOn:[KKJoyrideTrigger phaseToggled:0 on:YES]
         dismissOn:nil];
  // Diamond / gap tap → wait for the corresponding popover to actually open
  // (the next step's target rect isn't live until then).
  [binder
       bindStep:sDiamond
        atIndex:ixDiamondClick
      advanceOn:[[KKJoyrideTrigger diamondTapped:kDiamondTarget]
                    thenWaitFor:[KKJoyrideTrigger staticValuesPopoverWillOpen]]
      dismissOn:nil];
  [binder bindStep:sGap
           atIndex:ixGapClick
         advanceOn:[[KKJoyrideTrigger gapTapped:1 /* KKBasicSectionIn */]
                       thenWaitFor:[KKJoyrideTrigger gapPopoverWillOpen]]
         dismissOn:nil];
  // sMini / sEdit dismiss if the boundary popover closes mid-tour.
  [binder bindStep:sMini
           atIndex:ixMiniViewer
         advanceOn:nil
         dismissOn:[KKJoyrideTrigger staticValuesPopoverClosed]];
  [binder bindStep:sEdit
           atIndex:ixCropRadius
         advanceOn:nil
         dismissOn:[KKJoyrideTrigger staticValuesPopoverClosed]];
  [binder bindStep:sSpring
           atIndex:ixSpringPick
         advanceOn:[KKJoyrideTrigger gapPopoverCurveChanged:kSpringCurveType]
         dismissOn:nil];
  [binder setCloseOnAdvance:KKJoyrideCloseOnAdvanceContentPopover
                    forStep:sSpring];

  // sEdit's "advance ONLY after BOTH Crop AND Radius dragged" doesn't fit a
  // single trigger - keep it as a plugin-side AND via the binder's relay.
  binder.staticValueDragDidEnd =
      ^(NSString *label, NSArray<NSNumber *> *values) {
        __strong KKJoyrideController *g = weakGuide;
        __strong KKTimelineLanesView *basic = weakBasic;
        if (!g || g.currentStepIndex != ixCropRadius)
          return;
        if ([label isEqualToString:@"Crop"])
          cropChanged = YES;
        else if ([label isEqualToString:@"Radius"])
          radiusChanged = YES;
        if (cropChanged && radiusChanged) {
          [g advance];
          dispatch_async(dispatch_get_main_queue(), ^{
            [basic guideCloseContentPopover];
          });
        }
      };
  // sEdit.onEnter already resets cropChanged/radiusChanged above.

  // Both play steps are driven by deterministic play-button taps, not the
  // poll-inferred play state (which flickers under FCP's bursty currentTime
  // mid-guide - that flicker used to flash the accent and auto-advance the
  // step). Each tap is one unambiguous toggle:
  //   - sPlay advances on `playToggleEdge` (1st tap plays, 2nd pauses), via
  //     the binder below.
  //   - sWatchBack starts playback on the 1st tap, then auto-pauses + advances
  //     after kWatchBackSeconds (no manual pause - the guide handles it).
  // `guideOwnsPlayState` (set in restartBasicTimingGuide) makes each tap drive
  // the accent directly, so it tracks the clicks instead of the poll.
  self.onPlaybackToggleTapped = ^{
    __strong typeof(self) strong = weak;
    __strong KKJoyrideLanesBinder *b = weakBinder;
    __strong KKJoyrideController *g = weakGuide;
    [b notifyPlaybackToggleTapped];
    if (!strong || !g || g.currentStepIndex != ixWatchBack)
      return;
    // First tap = the user started playback. Schedule the auto-pause +
    // advance once; ignore further taps within this step.
    if (watchBackScheduled)
      return;
    watchBackScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kWatchBackSeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     __strong typeof(weak) s2 = weak;
                     __strong KKJoyrideController *g2 = weakGuide;
                     if (!s2 || !g2 || g2.currentStepIndex != ixWatchBack)
                       return;
                     // The auto-pause isn't a user tap, so flip the accent
                     // off ourselves to match the host stopping.
                     if (s2.onTogglePlayback)
                       s2.onTogglePlayback();
                     [s2 guideSetPlayingAccent:NO];
                     [g2 advance];
                   });
  };

  return @[
    s1, sPlay, s2, s3, s4, s5, s6, sGraph, sDiamond, sMini, sEdit, sGap,
    sSpring, sDrag, sWatchBack, sDone
  ];
}

- (void)restartBasicTimingGuide {
  // Force Basic tab - the guide assumes Basic-mode UI (boundary pills,
  // In/Hold/Out projection). If the user last left the inspector on
  // Advanced the guide steps would target controls that aren't visible.
  // Snapshot so we can restore on completion.
  NSInteger priorTab = self.activeTab;
  [self setActiveTab:KKTimelineTabBasic];
  // Filmstrip/onion would clutter the mini-viewer steps - force a single-frame
  // preview for the guide and restore the user's choice on completion. Plain
  // setter (not _renderModeDidChange:) so persisted UI state is untouched.
  KKMiniCanvasRenderMode priorRenderMode = self.basicLanesView.renderMode;
  self.basicLanesView.renderMode = KKMiniCanvasRenderModeOff;
  KKJoyrideGuideHost *host = [self _guideHost];
  // forwardsGestures: panel intercepts clicks instead of ignoresMouseEvents
  // letting them through. Without this, a click inside the spotlight reaches
  // the popover natively (canvas's own mouseDown → onHandleDragBegin) AND
  // fires the spotlight block (beginPointHandleDragAtScreenPoint: → ALSO
  // onHandleDragBegin) - two "Adjust Radius" undo groups race for the same
  // channel and FCP abort()s. Constants guide uses the same flag.
  host.forwardsGestures = YES;

  // The guide owns the play accent for its duration: taps drive it
  // deterministically and the poll-inferred setPlaying: is ignored, so it
  // can't flicker the button (or fire spurious edges) under FCP's bursty
  // currentTime. Restored on completion below.
  self.guideOwnsPlayState = YES;

  // Prereq: park the host playhead at clip start so every step (and the
  // boundary mini-viewer) renders from a predictable position. onScrub is
  // host-aware (FxCommandAPI movePlayheadToTime:); the plugin wires it.
  if (self.onScrub)
    self.onScrub(0.0);

  __weak typeof(self) weak = self;
  [host
      runWithSeed:^KKTimeline * {
        return [KKTimeline timeline];
      }
      buildSteps:^NSArray<KKJoyrideStep *> *(KKJoyrideController *guide,
                                             KKJoyrideLanesBinder *binder) {
        __strong typeof(weak) s = weak;
        return s ? [s _basicTimingStepsForGuide:guide binder:binder] : @[];
      }
      extraOnComplete:^{
        __strong typeof(weak) s = weak;
        if (!s)
          return;
        s.onPlaybackToggleTapped = nil;
        s.guideOwnsPlayState = NO;
        s.basicLanesView.renderMode = priorRenderMode;
        if (priorTab != KKTimelineTabBasic)
          [s setActiveTab:priorTab];
      }];
}

// Seed for the Advanced guide: both Crop and Radius animatable, each with
// two keyposes (t=0 and t=1) so the user lands on a populated sequencer.
// Crop uses its template's `[1,1,0,0]` default for both endpoints; Radius
// uses `20` (same as the OSC guide seed).
- (KKTimeline *)_advancedGuideSeedTimeline {
  KKTimeline *tl = [KKTimeline timeline];

  KKLane *radius = [KKLane laneWithLabel:@"Radius"];
  radius.enabled = YES; // animatable
  radius.valueType = KKLaneValueTypeFloat;
  radius.componentMin = @[ @0.0 ];
  radius.componentMax = @[ @100.0 ];
  radius.keyposes = @[
    [KKKeyPose keyposeAtTime:0.0 values:@[ @20.0 ]],
    [KKKeyPose keyposeAtTime:1.0 values:@[ @20.0 ]],
  ];

  KKLane *crop = [KKLane laneWithLabel:@"Crop"];
  crop.enabled = YES;
  crop.valueType = KKLaneValueTypeCrop;
  crop.componentMin = @[ @0.0, @0.0, @-0.5, @-0.5 ];
  crop.componentMax = @[ @1.0, @1.0, @0.5, @0.5 ];
  crop.keyposes = @[
    [KKKeyPose keyposeAtTime:0.0 values:@[ @1.0, @1.0, @0.0, @0.0 ]],
    [KKKeyPose keyposeAtTime:1.0 values:@[ @1.0, @1.0, @0.0, @0.0 ]],
  ];

  // KKTimelineLanesView sorts lanes alphabetically by label for display
  // (and only seeds *missing* lanes at the end), so order this seed to
  // match - otherwise the guide's lane-row lookups land on the wrong row.
  tl.lanes = @[ crop, radius ];
  return tl;
}

// Advanced guide steps (POC): tab-switch → orientation → cmd-click adds a
// Crop keypose → popover intro → final "drag a pill" + done.
// Step plumbing is intentionally light - most steps use `showsNext` and the
// one auto-advance (cmd-click → popover) reuses the existing
// `staticValuesPopoverWillOpen` trigger (Advanced's value popover goes
// through the same `_presentBoundaryValuePopover…` path as Basic).
- (NSArray<KKJoyrideStep *> *)
    _advancedTimingStepsForGuide:(KKJoyrideController *)guide
                          binder:(KKJoyrideLanesBinder *)binder {
  __weak typeof(self) weak = self;
  __weak KKTimelineAdvancedView *weakAdv = self.basicLanesView.advancedGraph;

  const NSInteger ixSwitch = 0, ixIntro = 1, ixCmdClick = 2, ixPopover = 3,
                  ixDrag = 4;

  // Step 1 - Tap the Advanced tab segment. forwardsGestures=YES routes the
  // synthesized click to the underlying pill; the inspector's
  // `onGuideTabChanged` (set in `restartAdvancedTimingGuide`) advances the
  // guide once the tab actually flips to Advanced.
  KKJoyrideStep *sSwitch = [KKJoyrideStep
      stepWithMessage:RLoc(@"Tap <accent>Advanced</accent> for the "
                           @"per-property timeline editor",
                           @"Advanced timing guide: open the Advanced editor.")
           targetView:nil];
  sSwitch.targetScreenRect = ^NSRect {
    __strong typeof(self) s = weak;
    return s ? [s guideTabSegmentScreenRectForTab:1 /* Advanced */]
             : NSZeroRect;
  };

  // Step 2 - Orientation. Cutout the Advanced view itself.
  KKJoyrideStep *sIntro = [KKJoyrideStep
      stepWithMessage:
          RLoc(@"Each row is a property - drop keyposes anywhere on the "
               @"timeline and shape transitions independently",
               @"Advanced timing guide: explains the per-property lanes.")
           targetView:^NSView * {
             __strong KKTimelineAdvancedView *a = weakAdv;
             return a;
           }];
  sIntro.showsNext = YES;

  // Step 3 - Cmd-click on the Crop lane. Cutout the whole row; glowing
  // target shows where to drop the new keypose (~50% time). The user
  // performs the cmd-click natively (forwardsGestures = YES). Advance fires
  // when Advanced opens the value popover.
  const double kCropAddFrac = 0.5;
sCmdClick: {
  KKJoyrideStep *sCmdClick = [KKJoyrideStep
      stepWithMessage:
          RLoc(@"<accent>Cmd-click</accent> the Crop lane at the <warn>glowing "
               @"target</warn> to add a keypose",
               @"Advanced timing guide: add a keypose to the Crop lane.")
           targetView:nil];
  sCmdClick.spotlightCircular = NO;
  sCmdClick.targetScreenRect = ^NSRect {
    __strong KKTimelineAdvancedView *a = weakAdv;
    return a ? [a guideLaneRowScreenRectForLabel:@"Crop"] : NSZeroRect;
  };
  sCmdClick.pillToScreenRect = ^NSRect {
    __strong KKTimelineAdvancedView *a = weakAdv;
    return a ? [a guideKeyposeScreenRectForLabel:@"Crop"
                                      atFraction:kCropAddFrac]
             : NSZeroRect;
  };

  // Step 4 - Popover intro. Cutout the popover content; Next closes it.
  KKJoyrideStep *sPopover = [KKJoyrideStep
      stepWithMessage:
          RLoc(@"Edit values at this point in time. Next closes the popover.",
               @"Advanced timing guide: edit values in the keypose popover.")
           targetView:nil];
  sPopover.targetScreenRect = ^NSRect {
    __strong NSView *content = binder.latestStaticValuesPopoverContent;
    NSWindow *w = content.window;
    if (!content || !w)
      return NSZeroRect;
    return [w convertRectToScreen:[content convertRect:content.bounds
                                                toView:nil]];
  };
  sPopover.showsNext = YES;

  // Step 5 - Drag the Radius KP at t=1 toward an earlier time. Same
  // KKJoyrideDragStep pattern Basic uses for the diamond drag, so the
  // joyride panel captures the press and feeds it through
  // guideBegin/Drag/EndPillDrag.
  const NSInteger kRadiusKPIdx = 1;    // the end keypose (t=1)
  const double kDragTargetFrac = 0.55; // glow target time
  const double kDragSnapFrac = 0.06;   // release tolerance
  const CGFloat kDragSnapPx = 14.0;    // mid-drag magnet (screen px)
  NSRect (^sDragSpot)(void) = ^NSRect {
    __strong KKTimelineAdvancedView *a = weakAdv;
    return a ? [a guideKeyposeScreenRectForLabel:@"Radius" atIndex:kRadiusKPIdx]
             : NSZeroRect;
  };
  NSRect (^sDragTarget)(void) = ^NSRect {
    __strong KKTimelineAdvancedView *a = weakAdv;
    return a ? [a guideKeyposeScreenRectForLabel:@"Radius"
                                      atFraction:kDragTargetFrac]
             : NSZeroRect;
  };
  KKJoyrideStep *sDrag = [KKJoyrideDragStep stepForGuide:guide
      atIndex:ixDrag
      isLast:YES
      clickMessage:
          RLoc(@"Drag a Radius keypose toward the <warn>glowing target</warn>",
               @"Advanced timing guide: drag a Radius keypose.")
      dragMessage:nil
      circular:YES
      spotRect:sDragSpot
      targetRect:sDragTarget
      begin:^(NSPoint p) {
        __strong KKTimelineAdvancedView *a = weakAdv;
        [a guideBeginPillDragForLabel:@"Radius"
                              atIndex:kRadiusKPIdx
                        atScreenPoint:p];
      }
      dragTo:^(NSPoint p) {
        __strong KKTimelineAdvancedView *a = weakAdv;
        NSPoint snapped = KKJoyrideSnapToTarget(p, sDragTarget(), kDragSnapPx);
        [a guideDragPillToScreenPoint:snapped];
      }
      end:^{
        __strong KKTimelineAdvancedView *a = weakAdv;
        [a guideEndPillDrag];
      }
      hitOnRelease:^BOOL(NSPoint p) {
        __strong KKTimelineAdvancedView *a = weakAdv;
        double now = [a guideKeyposeFractionForLabel:@"Radius"
                                             atIndex:kRadiusKPIdx];
        if (isnan(now))
          return NO;
        return fabs(now - kDragTargetFrac) <= kDragSnapFrac;
      }];
  // Closing the boundary value popover is the seam between popover-intro
  // and drag - the showsNext path on sPopover skips the binder's
  // closeOnAdvance, so we close it inline as the drag step opens.
  __weak KKTimelineLanesView *weakBasic = self.basicLanesView;
  sDrag.onEnter = ^{
    [weakBasic guideCloseContentPopover];
  };

  // Bindings.
  [binder bindStep:sCmdClick
           atIndex:ixCmdClick
         advanceOn:[KKJoyrideTrigger staticValuesPopoverWillOpen]
         dismissOn:nil];
  [binder bindStep:sPopover atIndex:ixPopover advanceOn:nil dismissOn:nil];
  (void)ixSwitch;
  (void)ixIntro;

  return @[ sSwitch, sIntro, sCmdClick, sPopover, sDrag ];
}
}

- (void)restartAdvancedTimingGuide {
  NSInteger priorTab = self.activeTab;
  // Single-frame mini-viewer during the guide; restore the user's
  // filmstrip/onion choice on completion (plain setter, no persistence).
  KKMiniCanvasRenderMode priorRenderMode = self.basicLanesView.renderMode;
  self.basicLanesView.renderMode = KKMiniCanvasRenderModeOff;
  KKJoyrideGuideHost *host = [self _guideHost];
  host.forwardsGestures = YES; // cmd-click + drag must reach the lane view

  // Start the guide visually on Basic so the user sees the tab switch in
  // step 1. The host's saved-timeline restore handles undo on completion.
  [self setActiveTab:0 /* Basic */];

  if (self.onScrub)
    self.onScrub(0.0);

  __weak typeof(self) weak = self;
  // Step 1 advances when the user actually flips the tab to Advanced.
  // `onGuideTabChanged` sits next to (not on top of) the host's
  // `onTabChanged`, so blob persistence is untouched.
  self.onGuideTabChanged = ^(NSInteger tab) {
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    KKJoyrideGuideHost *h = [s _guideHost];
    if (!h.isActive || tab != 1)
      return;
    KKJoyrideController *gc = h.currentGuide;
    if (gc.currentStepIndex != 0)
      return;
    [gc advance];
  };

  [host
      runWithSeed:^KKTimeline * {
        __strong typeof(weak) s = weak;
        return s ? [s _advancedGuideSeedTimeline] : nil;
      }
      buildSteps:^NSArray<KKJoyrideStep *> *(KKJoyrideController *guide,
                                             KKJoyrideLanesBinder *binder) {
        __strong typeof(weak) s = weak;
        return s ? [s _advancedTimingStepsForGuide:guide binder:binder] : @[];
      }
      extraOnComplete:^{
        __strong typeof(weak) s = weak;
        if (!s)
          return;
        s.onGuideTabChanged = nil;
        s.basicLanesView.renderMode = priorRenderMode;
        if (priorTab != s.activeTab)
          [s setActiveTab:priorTab];
      }];
}

- (void)restartFullWalkthroughGuide {
  // OSC setup runs UP FRONT (inside the host warm-up): the zoom-to-fit
  // AppleScript steals FCP focus, so it must fire before the overlay exists.
  RoundedSetOSCGuideStep(0);
  RoundedSetGuideRadius(20.0);

  KKJoyrideGuideHost *host = [self _guideHost];
  host.forwardsGestures = NO;

  __weak typeof(self) weak = self;
  [host runOSCGuideWithSeed:[KKTimeline timeline]
      buildSteps:^NSArray<KKJoyrideStep *> *(KKJoyrideController *guide,
                                             KKJoyrideLanesBinder *binder) {
        __strong typeof(weak) s = weak;
        if (!s)
          return @[];
        NSArray<KKJoyrideStep *> *introSteps = [s _introStepsForGuide:guide
                                                         displayTotal:6
                                                               binder:binder];
        void (^warmUp)(void) = ^{
          __strong typeof(weak) sw = weak;
          if (!sw)
            return;
          // Inspector portion done: record it seen, then enter the OSC portion
          // (quiet param write; zoom-to-fit already ran up front).
          [NSUserDefaults.standardUserDefaults setBool:YES
                                                forKey:kRoundedIntroSeenKey];
          [NSUserDefaults.standardUserDefaults synchronize];
          [sw _enterFullWalkthroughOSCPortion];
        };
        NSArray<KKJoyrideStep *> *oscSteps = [s _oscStepsForGuide:guide
                                                      displayBase:3
                                                     displayTotal:6
                                                 firstStepOnEnter:warmUp];
        NSMutableArray<KKJoyrideStep *> *all = [introSteps mutableCopy];
        [all addObjectsFromArray:oscSteps];
        return all;
      }
      extraOnComplete:^{
        __strong typeof(weak) s = weak;
        RoundedSetOSCGuideStep(0);
        [s _teardownOSCSegment];
      }];
}

@end
