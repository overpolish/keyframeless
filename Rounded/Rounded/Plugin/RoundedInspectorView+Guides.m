/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "RoundedInspectorView+Guides.h"
#import "RoundedInspectorView_Private.h"
#import <KeyframelessKit/KKHostInfo.h>
#import <KeyframelessKit/KKJoyrideDragStep.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKMiniCanvasGuideScroll.h>
#import <KeyframelessKit/KKMiniCanvasView.h>
#import <KeyframelessKit/KKOSCGuideBridge.h>
#import <KeyframelessKit/KKOSCGuideStrategy.h>
#import <KeyframelessKit/KKTimelineLanesView.h>

static NSString *const kRoundedIntroSeenKey = @"RoundedIntroSeen";

// Snap tolerance (radius units) that counts as "hit" for the OSC guide target.
static const double kOSCGuideTargetSnap = 4.0;

// Radius the constants guide's final slider step asks the user to reach, and
// how close (radius units) counts as "there".
static const double kConstantsGuideTargetRadius = 80.0;
// Release tolerance for the slider step — forgiving enough to "land near 80"
// by hand (no mid-drag magnetism), then it snaps exactly onto 80.
static const double kConstantsGuideSliderSnap = 4.0;
// The mini-canvas (miniOSC) drag step targets a *different* radius than the
// slider step, with the same generous snap as the in-viewer OSC guide.
static const double kConstantsGuideS2Radius = 40.0;
// Magnetic-snap radius (screen points) around the amber target for the
// mini-canvas drag step — gentle so it doesn't grab from far away.
static const CGFloat kConstantsGuideSnapPx = 9.0;
// Gentle mid-drag magnet (radius units) so the slider knob sticks onto the
// target as it approaches — same feel as the miniOSC, but not grabby.
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

// Fits the viewer to the window via System Events AppleScript — host-aware:
// FCP is "Window > Go To > Viewer" then "View > Zoom to Fit"; Motion is
// "View > Zoom Level > Fit in Window". Runs synchronously — call from a
// background queue or dispatch_async.
static void RoundedTriggerHostZoomToFit(void) {
  BOOL fcp = [KKHostInfo isRunningInFinalCut];
  NSString *src = fcp ? @"tell application \"System Events\"\n"
                         "  tell process \"Final Cut Pro\"\n"
                         "    tell menu bar 1\n"
                         "      tell menu bar item \"Window\"\n"
                         "        tell menu \"Window\"\n"
                         "          tell menu item \"Go To\"\n"
                         "            tell menu \"Go To\"\n"
                         "              click menu item \"Viewer\"\n"
                         "            end tell\n"
                         "          end tell\n"
                         "        end tell\n"
                         "      end tell\n"
                         "    end tell\n"
                         "    delay 0.1\n"
                         "    tell menu bar 1\n"
                         "      tell menu bar item \"View\"\n"
                         "        tell menu \"View\"\n"
                         "          click menu item \"Zoom to Fit\"\n"
                         "        end tell\n"
                         "      end tell\n"
                         "    end tell\n"
                         "  end tell\n"
                         "end tell"
                      : @"tell application \"System Events\"\n"
                         "  tell process \"Motion\"\n"
                         "    tell menu bar 1\n"
                         "      tell menu bar item \"View\"\n"
                         "        tell menu \"View\"\n"
                         "          tell menu item \"Zoom Level\"\n"
                         "            tell menu \"Zoom Level\"\n"
                         "              click menu item \"Fit in Window\"\n"
                         "            end tell\n"
                         "          end tell\n"
                         "        end tell\n"
                         "      end tell\n"
                         "    end tell\n"
                         "  end tell\n"
                         "end tell";
  NSAppleScript *script = [[NSAppleScript alloc] initWithSource:src];
  NSDictionary *err = nil;
  [script executeAndReturnError:&err];
  if (err)
    KKLogWarn(@"[OSCGuide] zoom-to-fit AppleScript error (%@): %@",
              fcp ? @"FCP" : @"Motion", err);
  [script release];
}

@implementation RoundedInspectorView (Guides)

- (void)_maybeAutostartIntroGuide {
  if (self.isDetachedCopy)
    return;
  if (!self.window)
    return;
  if (self.basicLanesView.currentTimeline.lanes.count > 0)
    return;
  if ([NSUserDefaults.standardUserDefaults boolForKey:kRoundedIntroSeenKey])
    return;
  __weak typeof(self) weak = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong typeof(self) strong = weak;
    if (!strong || !strong.window)
      return;
    if (strong.basicLanesView.currentTimeline.lanes.count > 0)
      return;
    if ([NSUserDefaults.standardUserDefaults boolForKey:kRoundedIntroSeenKey])
      return;
    [strong _startIntroGuide];
  });
}

// The 3 inspector intro steps, wired to advance `guide` off the basic view's
// popover/lane callbacks. No guide start, no timeline save/restore — the
// caller owns lifetime so these steps can be the head of either the standalone
// intro guide or the combined walkthrough. displayTotal > 0 overrides the step
// counter's "of N" (used by the combined guide so numbering stays continuous
// across the inspector→OSC handoff).
- (NSArray<KKJoyrideStep *> *)_introStepsForGuide:(KKJoyrideController *)guide
                                     displayTotal:(NSInteger)displayTotal {
  __block NSView *step2Row = nil;
  __block NSView *step3Row = nil;
  __weak KKTimelineLanesView *weakBasic = self.basicLanesView;
  __weak KKJoyrideController *weakGuide = guide;

  KKJoyrideStep *s1 = [KKJoyrideStep
      stepWithMessage:@"Tap <symbol plus.circle.fill color=accent /> to add "
                      @"an animated property"
           targetView:^NSView * {
             __strong KKTimelineLanesView *b = weakBasic;
             return b.footerView;
           }];

  KKJoyrideStep *s2 = [KKJoyrideStep
      stepWithMessage:@"Tap <accent>Radius</accent> to animate it"
           targetView:^NSView * {
             return step2Row;
           }];

  KKJoyrideStep *s3 = [KKJoyrideStep
      stepWithMessage:@"Drag the timeline to animate this property"
           targetView:^NSView * {
             return step3Row;
           }];
  s3.showsNext = YES;

  if (displayTotal > 0)
    for (KKJoyrideStep *s in @[ s1, s2, s3 ])
      s.displayTotalSteps = displayTotal;

  self.basicLanesView.onManagePopoverWillOpen = ^(NSView *row) {
    step2Row = row;
    __strong KKJoyrideController *g = weakGuide;
    g.additionalPassthroughWindow = row.window;
    [g advance];
  };
  self.basicLanesView.onManagePopoverClosed = ^{
    __strong KKJoyrideController *g = weakGuide;
    g.additionalPassthroughWindow = nil;
    if (g.isActive && g.currentStepIndex == 1)
      [g dismiss];
  };
  self.basicLanesView.onLaneOptedIn = ^(NSString *label) {
    __strong KKTimelineLanesView *basic = weakBasic;
    __strong KKJoyrideController *g = weakGuide;
    step3Row = [basic laneRowViewForLabel:label];
    [g advance];
    // Defer close so the popover-close notification fires after the toggle
    // call stack unwinds — closing synchronously cascades into applyTimeline:
    // and crashes via use-after-free on the manage view.
    dispatch_async(dispatch_get_main_queue(), ^{
      [basic closeManagePopover];
    });
  };

  return @[ s1, s2, s3 ];
}

- (void)_startIntroGuide {
  [_introGuide dismiss];

  __weak typeof(self) weak = self;
  __weak KKTimelineLanesView *weakBasic = self.basicLanesView;
  KKJoyrideController *guide =
      [[KKJoyrideController alloc] initWithHostView:self];
  __weak KKJoyrideController *weakGuide = guide;
  NSArray<KKJoyrideStep *> *steps = [self _introStepsForGuide:guide
                                                 displayTotal:0];

  [guide startWithSteps:steps
             onComplete:^{
               __strong typeof(self) strong = weak;
               __strong KKTimelineLanesView *basic = weakBasic;
               if (!strong)
                 return;
               // Reached the final step (index 2 of [s1,s2,s3]) = completed.
               __strong KKJoyrideController *cg = weakGuide;
               if (cg && cg.currentStepIndex >= 2 && strong.onGuideCompleted)
                 strong.onGuideCompleted();
               [NSUserDefaults.standardUserDefaults
                   setBool:YES
                    forKey:kRoundedIntroSeenKey];
               [NSUserDefaults.standardUserDefaults synchronize];
               basic.onManagePopoverWillOpen = nil;
               basic.onManagePopoverClosed = nil;
               basic.onLaneOptedIn = nil;
               strong->_introGuide = nil;
               // MRR: transfer ownership of the retained _savedIntroTimeline
               // to the dispatch_async block (which retains it on copy).
               KKTimeline *saved = strong->_savedIntroTimeline;
               strong->_savedIntroTimeline = nil;
               if (saved) {
                 dispatch_async(dispatch_get_main_queue(), ^{
                   __strong typeof(self) s2 = weak;
                   __strong KKTimelineLanesView *b2 = weakBasic;
                   if (b2) {
                     [b2 applyTimeline:saved];
                     if (s2 && s2.onTimelineMutated)
                       s2.onTimelineMutated(saved);
                   }
                 });
                 [saved release]; // block retained it; release our ownership
               }
             }];
  _introGuide = guide;
}

- (void)restartIntroGuide {
  [NSUserDefaults.standardUserDefaults removeObjectForKey:kRoundedIntroSeenKey];
  [NSUserDefaults.standardUserDefaults synchronize];
  [_savedIntroTimeline release];
  _savedIntroTimeline = [self.basicLanesView.currentTimeline retain];
  KKTimeline *empty = [KKTimeline timeline];
  [self.basicLanesView applyTimeline:empty];
  if (self.onTimelineMutated)
    self.onTimelineMutated(empty);
  [self _startIntroGuide];
}

// The point-OSC value mapping for the generic KKJoyrideOSCSegment: how a
// screen drag becomes a radius and back. This is the only OSC-shape-specific
// code the inspector still owns — a different OSC supplies its own strategy.
- (KKOSCGuideStrategy *)_pointOSCStrategy {
  __weak typeof(self) weak = self;
  __weak KKTimelineLanesView *weakBasic = self.basicLanesView;
  KKOSCGuideStrategy *s = [[[KKOSCGuideStrategy alloc] init] autorelease];
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
    // Map the cursor to the radius that puts the OSC handle under it — the
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
  s.clickMessage = @"Click the <accent>circle</accent> in the viewer to "
                   @"control the radius";
  s.dragMessage = @"Drag toward the <warn>glowing target</warn>";
  s.selectedMessage =
      @"The OSC is available whenever <accent>Rounded</accent> is selected";
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
  [_oscSegment release];
  _oscSegment = nil;
}

- (void)_startOSCGuide {
  [_oscGuide dismiss];

  __weak typeof(self) weak = self;
  __weak KKTimelineLanesView *weakBasic = self.basicLanesView;
  KKJoyrideController *guide =
      [[KKJoyrideController alloc] initWithHostView:self];
  __weak KKJoyrideController *weakGuide = guide;
  NSArray<KKJoyrideStep *> *steps = [self _oscStepsForGuide:guide
                                                displayBase:0
                                               displayTotal:3
                                           firstStepOnEnter:nil];

  [guide startWithSteps:steps
             onComplete:^{
               __strong typeof(self) strong = weak;

               // Reached the final step (index 1 of [s1,s3]) = completed.
               __strong KKJoyrideController *cg = weakGuide;
               if (cg && cg.currentStepIndex >= 1 && strong.onGuideCompleted)
                 strong.onGuideCompleted();

               RoundedSetOSCGuideStep(0);
               [strong _teardownOSCSegment];

               KKJoyrideController *toRelease =
                   strong ? strong->_oscGuide : nil;
               if (strong)
                 strong->_oscGuide = nil;
               if (toRelease) {
                 dispatch_async(dispatch_get_main_queue(), ^{
                   [toRelease release];
                 });
               }

               KKTimeline *saved = strong ? strong->_savedOSCTimeline : nil;
               if (strong)
                 strong->_savedOSCTimeline = nil;
               if (saved) {
                 dispatch_async(dispatch_get_main_queue(), ^{
                   __strong typeof(self) s2 = weak;
                   __strong KKTimelineLanesView *b2 = weakBasic;
                   if (b2) {
                     [b2 applyTimeline:saved];
                     if (s2 && s2.onTimelineMutated)
                       s2.onTimelineMutated(saved);
                   }
                 });
                 [saved release]; // block retained it; release our ownership
               }
             }];

  _oscGuide = guide;
}

// Builds the guide's single-lane Radius timeline at the given value. The OSC
// reads radius from this blob (via parameterChanged → instance state), so
// writing it is the only channel that moves the on-screen control — the
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
  return _oscGuide.isActive;
}

- (void)restartOSCGuide {
  // Step 1: spotlight on the handle, no target yet. The press bumps to OSC
  // step 2 (in spotlightMouseDown) which reveals the target — the handle
  // already follows sGuideRadius at any step > 0.
  RoundedSetOSCGuideStep(1);
  // The OSC handle reads sGuideRadius during the guide; reset it so a new
  // guide starts at the default and doesn't remember the last drag.
  RoundedSetGuideRadius(20.0);

  [_savedOSCTimeline release];
  _savedOSCTimeline = [self.basicLanesView.currentTimeline retain];

  KKTimeline *clean = [self _guideTimelineWithRadius:20.0];

  [self.basicLanesView applyTimeline:clean];
  if (self.onTimelineMutated)
    self.onTimelineMutated(clean);

  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    RoundedTriggerHostZoomToFit();
    // The AppleScript zoom-to-fit is async; FCP needs time to actually
    // resize the viewer. drawOSC already gets fresh canvas corners, but the
    // viewer-screen rect doesn't refresh until FCP re-renders/re-processes
    // post-resize. Wait for the resize to settle, then force a param write
    // (same clean timeline) so parameterChanged → re-render → drawOSC runs
    // at the FINAL geometry before the guide reads the spotlight position.
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          __strong typeof(self) s = weakSelf;
          if (!s)
            return;
          KKTimeline *settle = [s _guideTimelineWithRadius:20.0];
          [s.basicLanesView applyTimeline:settle];
          if (s.onTimelineMutated)
            s.onTimelineMutated(settle);
          dispatch_after(
              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
              dispatch_get_main_queue(), ^{
                __strong typeof(self) s2 = weakSelf;
                if (s2)
                  [s2 _startOSCGuide];
              });
        });
  });
}

// Crossover into the OSC portion: the user finished the inspector portion and
// the first OSC step just became active. Zoom-to-fit already ran up front (in
// restartFullWalkthroughGuide) so FCP's focus steal happened before the
// overlay existed — here we only do the focus-free work: enable the OSC guide
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

// Concrete example of one guide that crosses inspector → OSC: a single
// controller running the 3 inspector intro steps followed by the 2 OSC steps.
// The same KKJoyrideController drives both — inspector steps target NSViews,
// OSC steps target screen rects + capture the gesture; the only seam is the
// first OSC step's onEnter, which switches the viewer into OSC-guide mode.
// The focus-stealing zoom-to-fit already ran up front in
// restartFullWalkthroughGuide (before the overlay existed), so the crossover
// is now a quiet param write that doesn't pull FCP in front of the overlay.
- (void)_startFullWalkthroughGuide {
  [_fullGuide dismiss];

  __weak typeof(self) weak = self;
  __weak KKTimelineLanesView *weakBasic = self.basicLanesView;
  KKJoyrideController *guide =
      [[KKJoyrideController alloc] initWithHostView:self];
  __weak KKJoyrideController *weakGuide = guide;

  NSArray<KKJoyrideStep *> *introSteps = [self _introStepsForGuide:guide
                                                      displayTotal:6];

  void (^warmUp)(void) = ^{
    __strong typeof(self) strong = weak;
    if (!strong)
      return;
    // Inspector portion done — record it seen, then enter the OSC portion
    // (quiet param write; zoom-to-fit already ran up front).
    [NSUserDefaults.standardUserDefaults setBool:YES
                                          forKey:kRoundedIntroSeenKey];
    [NSUserDefaults.standardUserDefaults synchronize];
    [strong _enterFullWalkthroughOSCPortion];
  };
  NSArray<KKJoyrideStep *> *oscSteps = [self _oscStepsForGuide:guide
                                                   displayBase:3
                                                  displayTotal:6
                                              firstStepOnEnter:warmUp];

  NSMutableArray<KKJoyrideStep *> *steps = [introSteps mutableCopy];
  [steps addObjectsFromArray:oscSteps];
  NSInteger finalIdx = (NSInteger)steps.count - 1;

  [guide startWithSteps:steps
             onComplete:^{
               __strong typeof(self) strong = weak;
               __strong KKTimelineLanesView *basic = weakBasic;

               // Reached the final OSC step = fully completed.
               __strong KKJoyrideController *cg = weakGuide;
               if (cg && cg.currentStepIndex >= finalIdx &&
                   strong.onGuideCompleted)
                 strong.onGuideCompleted();

               RoundedSetOSCGuideStep(0);
               [strong _teardownOSCSegment];
               if (basic) {
                 basic.onManagePopoverWillOpen = nil;
                 basic.onManagePopoverClosed = nil;
                 basic.onLaneOptedIn = nil;
               }

               KKJoyrideController *toRelease =
                   strong ? strong->_fullGuide : nil;
               if (strong)
                 strong->_fullGuide = nil;
               if (toRelease) {
                 dispatch_async(dispatch_get_main_queue(), ^{
                   [toRelease release];
                 });
               }

               KKTimeline *saved = strong ? strong->_savedFullTimeline : nil;
               if (strong)
                 strong->_savedFullTimeline = nil;
               if (saved) {
                 dispatch_async(dispatch_get_main_queue(), ^{
                   __strong typeof(self) s2 = weak;
                   __strong KKTimelineLanesView *b2 = weakBasic;
                   if (b2) {
                     [b2 applyTimeline:saved];
                     if (s2 && s2.onTimelineMutated)
                       s2.onTimelineMutated(saved);
                   }
                 });
                 [saved release]; // block retained it; release our ownership
               }
             }];
  _fullGuide = guide;
}

- (void)_teardownConstantsScrollMonitors {
  [_constantsScrollFwd teardown];
  [_constantsScrollFwd release];
  _constantsScrollFwd = nil;
}

// Scroll/pinch routing during the guide now lives in the reusable
// KKMiniCanvasGuideScroll (any plugin's mini-canvas guide gets it). It
// forwards to the canvas only while the constants guide is active and the
// pointer is over the canvas. (Magnify monitors are the real pinch carrier —
// see [[project_joyride_xpc_popover_gestures]].)
- (void)_installConstantsScrollMonitorsForCanvas:(KKMiniCanvasView *)canvas {
  [self _teardownConstantsScrollMonitors];
  __weak typeof(self) weak = self;
  _constantsScrollFwd = [[KKMiniCanvasGuideScroll alloc]
      initWithCanvas:canvas
          activeWhen:^BOOL {
            __strong typeof(self) s = weak;
            return s && s->_constantsGuide.isActive;
          }];
  [_constantsScrollFwd install];
}

// The 5 constants steps, all inspector-side (no viewer OSC / focus steal):
// open the Constants popover, drag the mini-canvas radius handle (the
// "miniOSC"), zoom/pan the preview, double-click to reset it, then drag the
// slider to 80. The popover/canvas hooks added to KKTimelineLanesView drive
// the advances; nothing here is Rounded-shape-specific except the "Radius"
// label and the target value.
- (NSArray<KKJoyrideStep *> *)_constantsStepsForGuide:
    (KKJoyrideController *)guide {
  __weak typeof(self) weak = self;
  __weak KKJoyrideController *weakGuide = guide;
  __block __weak KKMiniCanvasView *weakCanvas = nil;
  __block __weak NSView *weakRadiusRow = nil;
  // Latest Radius the popover reported (mini-canvas handle or slider) — the
  // require-target-hit gate reads it at release, like the OSC guide.
  __block double lastRadius = -1.0;
  // Step indices in one place (order is fixed) so gates don't churn when the
  // sequence changes. ixLast drives "final step → dismiss vs advance".
  const NSInteger ixConstants = 0, ixRadius = 1, ixCrop = 2, ixZoom = 3,
                  ixReset = 4, ixSlider = 5, ixTypeX = 6, ixLast = 6;

  KKJoyrideStep *s1 = [KKJoyrideStep
      stepWithMessage:@"Tap <accent>Constants</accent> to edit values that "
                      @"don't change over time"
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
    __strong KKMiniCanvasView *c = weakCanvas;
    return c ? [c pointHandleScreenRectForValue:kConstantsGuideS2Radius]
             : NSZeroRect;
  };
  KKJoyrideStep *s2 = [KKJoyrideDragStep stepForGuide:guide
      atIndex:ixRadius
      isLast:(ixRadius == ixLast)
      clickMessage:@"Click the <accent>dot</accent> to set the corner radius"
      dragMessage:@"Drag toward the <warn>glowing target</warn>"
      circular:YES
      spotRect:^NSRect {
        __strong KKMiniCanvasView *c = weakCanvas;
        return c ? [c pointHandleScreenRect] : NSZeroRect;
      }
      targetRect:s2Target
      begin:^(NSPoint p) {
        [weakCanvas beginPointHandleDragAtScreenPoint:p];
      }
      dragTo:^(NSPoint p) {
        [weakCanvas dragPointHandleToScreenPoint:KKJoyrideSnapToTarget(
                                                     p, s2Target(),
                                                     kConstantsGuideSnapPx)];
      }
      end:^{
        [weakCanvas endPointHandleDrag];
      }
      hitOnRelease:^BOOL(NSPoint p) {
        NSRect t = s2Target();
        double dpx =
            NSIsEmptyRect(t) ? 1e9 : hypot(p.x - NSMidX(t), p.y - NSMidY(t));
        // By value OR screen proximity (covers a stale last-tick value).
        return fabs(lastRadius - kConstantsGuideS2Radius) <=
                   kOSCGuideTargetSnap ||
               dpx <= kConstantsGuideSnapPx;
      }];

  NSRect (^cropTarget)(void) = ^NSRect {
    __strong KKMiniCanvasView *c = weakCanvas;
    return c ? [c cropHandleScreenRectAtIndex:kConstantsGuideCropHandleIdx
                                forCropValues:KKConstantsGuideCropTarget()]
             : NSZeroRect;
  };
  KKJoyrideStep *sCrop = [KKJoyrideDragStep stepForGuide:guide
      atIndex:ixCrop
      isLast:(ixCrop == ixLast)
      clickMessage:@"Click the <accent>top-left</accent> crop corner"
      dragMessage:@"Drag the corner toward the <warn>glowing target</warn>"
      circular:YES
      spotRect:^NSRect {
        __strong KKMiniCanvasView *c = weakCanvas;
        return c ? [c cropHandleScreenRectAtIndex:kConstantsGuideCropHandleIdx]
                 : NSZeroRect;
      }
      targetRect:cropTarget
      begin:^(NSPoint p) {
        [weakCanvas beginPointHandleDragAtScreenPoint:p];
      }
      dragTo:^(NSPoint p) {
        [weakCanvas dragPointHandleToScreenPoint:KKJoyrideSnapToTarget(
                                                     p, cropTarget(),
                                                     kConstantsGuideSnapPx)];
      }
      end:^{
        [weakCanvas endPointHandleDrag];
      }
      hitOnRelease:^BOOL(NSPoint p) {
        NSRect t = cropTarget();
        double dpx =
            NSIsEmptyRect(t) ? 1e9 : hypot(p.x - NSMidX(t), p.y - NSMidY(t));
        return dpx <= kConstantsGuideSnapPx;
      }];

  KKJoyrideStep *s3 = [KKJoyrideStep
      stepWithMessage:@"Scroll to <accent>zoom</accent>, two-finger drag to "
                      @"<accent>pan</accent> the preview"
           targetView:^NSView * {
             return weakCanvas;
           }];
  s3.spotlightMagnifyEvent = ^(NSEvent *e) {
    [weakCanvas applyMagnifyEvent:e];
  };

  KKJoyrideStep *s4 = [KKJoyrideStep
      stepWithMessage:@"<accent>Double-click</accent> the preview to reset "
                      @"the view"
           targetView:^NSView * {
             return weakCanvas;
           }];

  // The slider has a modal tracking loop, so (unlike pan/scroll) its drag
  // can't be forwarded — capture it and drive the constant through the
  // popover's coalesced channel. Same KKJoyrideDragStep factory, slider
  // variant: target shown immediately (no press-gated reveal, dragMessage
  // nil) and not circular. The map uses the slider's own screen geometry so
  // the amber target sits on the real track; the gentle magnet lives in
  // valueForX, with an exact snap-onto-80 on release.
  double (^valueForX)(CGFloat) = ^double(CGFloat x) {
    __strong typeof(self) s = weak;
    if (!s)
      return lastRadius;
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
      clickMessage:@"Drag the slider to the <warn>target</warn> (80)"
      dragMessage:nil
      circular:NO
      spotRect:^NSRect {
        __strong NSView *r = weakRadiusRow;
        NSWindow *w = r.window;
        if (!r || !w)
          return NSZeroRect;
        return [w convertRectToScreen:[r convertRect:r.bounds toView:nil]];
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
  // capture — a normal forwarded click focuses the field, the user types,
  // and the live-keystroke handler (set in willOpen) auto-commits + ends
  // the guide when the value matches.
  KKJoyrideStep *sX = [KKJoyrideStep
      stepWithMessage:@"Click the <accent>X</accent> field and type "
                      @"<warn>100</warn>"
           targetView:nil];
  sX.targetScreenRect = ^NSRect {
    __strong typeof(self) s = weak;
    return s ? [s.basicLanesView
                   guideConstantFieldScreenRectForLabel:@"Crop"
                                              component:
                                                  kConstantsGuideCropXComponent]
             : NSZeroRect;
  };

  self.basicLanesView.onStaticValuesPopoverWillOpen = ^(NSView *content,
                                                        KKMiniCanvasView *cv) {
    __strong KKJoyrideController *g = weakGuide;
    __strong typeof(self) s = weak;
    weakCanvas = cv;
    if (s)
      weakRadiusRow = [s.basicLanesView staticValueRowViewForLabel:@"Radius"];
    if (!g)
      return;
    g.additionalPassthroughWindow = content.window;
    if (cv) {
      cv.onViewTransformChanged = ^{
        __strong KKJoyrideController *gg = weakGuide;
        if (gg && gg.isActive && gg.currentStepIndex == ixZoom)
          [gg advance];
      };
      cv.onViewReset = ^{
        __strong KKJoyrideController *gg = weakGuide;
        if (gg && gg.isActive && gg.currentStepIndex == ixReset)
          [gg advance];
      };
      if (s)
        [s _installConstantsScrollMonitorsForCanvas:cv];
    }
    // Final step: auto-commit + end when the user types the target into
    // the Crop X field.
    if (s)
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
                                               [gg dismiss]; // final →
                                                             // completed
                                             }
                                           }];
    if (g.isActive && g.currentStepIndex == ixConstants)
      [g advance];
  };
  self.basicLanesView.onStaticValuesPopoverClosed = ^{
    __strong KKJoyrideController *g = weakGuide;
    if (!g)
      return;
    g.additionalPassthroughWindow = nil;
    // Popover dismissed before the tour finished — end it (onComplete
    // restores the saved timeline).
    if (g.isActive)
      [g dismiss];
  };
  self.basicLanesView.onStaticValueDragEnded =
      ^(NSString *label, NSArray<NSNumber *> *values) {
        __strong KKJoyrideController *g = weakGuide;
        if (g && g.isActive && g.currentStepIndex == ixRadius &&
            [label isEqualToString:@"Radius"])
          [g advance];
      };
  // Just track the latest Radius (mini-canvas handle or slider). The
  // require-target-hit gates fire on release in s2/s5, not per tick.
  self.basicLanesView.onStaticValueChanged =
      ^(NSString *label, NSArray<NSNumber *> *values) {
        if ([label isEqualToString:@"Radius"] && values.count > 0)
          lastRadius = values.firstObject.doubleValue;
      };

  return @[ s1, s2, sCrop, s3, s4, s5, sX ];
}

- (void)_startConstantsGuide {
  [_constantsGuide dismiss];

  __weak typeof(self) weak = self;
  __weak KKTimelineLanesView *weakBasic = self.basicLanesView;
  KKJoyrideController *guide =
      [[KKJoyrideController alloc] initWithHostView:self];
  // Let the panel receive pinch so s3 can forward it to the mini-canvas;
  // clicks still pass via the global-monitor synthesize path.
  guide.forwardsGestures = YES;
  __weak KKJoyrideController *weakGuide = guide;
  NSArray<KKJoyrideStep *> *steps = [self _constantsStepsForGuide:guide];
  NSInteger finalIdx = (NSInteger)steps.count - 1;

  [guide startWithSteps:steps
             onComplete:^{
               __strong typeof(self) strong = weak;
               __strong KKTimelineLanesView *basic = weakBasic;

               __strong KKJoyrideController *cg = weakGuide;
               if (cg && cg.currentStepIndex >= finalIdx &&
                   strong.onGuideCompleted)
                 strong.onGuideCompleted();

               [strong _teardownConstantsScrollMonitors];

               if (basic) {
                 basic.onStaticValuesPopoverWillOpen = nil;
                 basic.onStaticValuesPopoverClosed = nil;
                 basic.onStaticValueChanged = nil;
                 basic.onStaticValueDragEnded = nil;
                 [basic setGuideConstantFieldEditHandlerForLabel:@"Crop"
                                                         handler:nil];
               }

               KKJoyrideController *toRelease =
                   strong ? strong->_constantsGuide : nil;
               if (strong)
                 strong->_constantsGuide = nil;
               if (toRelease) {
                 dispatch_async(dispatch_get_main_queue(), ^{
                   [toRelease release];
                 });
               }

               KKTimeline *saved =
                   strong ? strong->_savedConstantsTimeline : nil;
               if (strong)
                 strong->_savedConstantsTimeline = nil;
               if (saved) {
                 dispatch_async(dispatch_get_main_queue(), ^{
                   __strong typeof(self) s2 = weak;
                   __strong KKTimelineLanesView *b2 = weakBasic;
                   if (b2) {
                     [b2 applyTimeline:saved];
                     if (s2 && s2.onTimelineMutated)
                       s2.onTimelineMutated(saved);
                   }
                 });
                 [saved release]; // block retained it; release our ownership
               }
             }];
  _constantsGuide = guide;
}

- (void)restartConstantsGuide {
  [_savedConstantsTimeline release];
  _savedConstantsTimeline = [self.basicLanesView.currentTimeline retain];

  // Teach on a known state: Radius + Crop both constant so the popover shows
  // the radius slider + handle AND the crop box/handles + X field.
  KKTimeline *seed = [self _constantsGuideSeedTimeline];
  [self.basicLanesView applyTimeline:seed];
  if (self.onTimelineMutated)
    self.onTimelineMutated(seed);

  [self _startConstantsGuide];
}

// Chunk-1 Basic Timing guide: open the "+" footer popover, add Crop and
// Radius, then toggle the In transition on. All advances come from existing
// KKTimelineLanesView callbacks (onManagePopoverWillOpen / onLaneOptedIn)
// plus the new KKTimelineBasicView onPhaseToggled hook; cutouts use the
// new screen-rect helpers in the +Guide categories.
- (NSArray<KKJoyrideStep *> *)_basicTimingStepsForGuide:
    (KKJoyrideController *)guide {
  __weak typeof(self) weak = self;
  __weak KKTimelineLanesView *weakBasic = self.basicLanesView;
  __weak KKTimelineBasicView *weakGraph = self.basicLanesView.basicGraph;
  __weak KKJoyrideController *weakGuide = guide;

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
  // advancing — long enough to see a beat of the animation, short enough
  // that the demo doesn't feel like it's stalled.
  const double kWatchBackSeconds = 1.0;

  // Step 14: drag the In-end diamond to t=0.8s. Snap window in seconds —
  // both for the gentle in-drag magnet and the final release tolerance.
  const double kDragTargetSeconds = 0.8;
  const double kDragSnapSeconds = 0.05;
  const CGFloat kDragSnapPx = 14.0;

  // KKIntervalCurveElastic == 4 (Linear=0, EaseIn=1, EaseOut=2, EaseInOut=3,
  // Elastic=4, Bounce=5) — what we present to users as the "Spring" curve.
  const NSInteger kSpringCurveType = 4;
  __block __weak KKSegmentEditView *weakGapEditor = nil;

  // Diamond 2 (hold-start) — chronologically the second visible keypose
  // once the In transition is on (the diamonds the user just saw appear).
  const NSInteger kDiamondTarget = 2;
  __block __weak KKMiniCanvasView *weakBoundaryMini = nil;
  __block __weak NSView *weakBoundaryPopoverContent = nil;
  __block BOOL cropChanged = NO, radiusChanged = NO;

  KKJoyrideStep *s1 = [KKJoyrideStep
      stepWithMessage:@"Here is where you edit the <accent>timing</accent> "
                      @"of things"
           targetView:^NSView * {
             __strong KKTimelineBasicView *g = weakGraph;
             __strong KKTimelineLanesView *b = weakBasic;
             return g ?: (NSView *)b;
           }];
  s1.showsNext = YES;

  // Step 2: click to play, then click again to pause — advances on the
  // pause edge. Useful demo when the spacebar shortcut isn't working.
  KKJoyrideStep *sPlay = [KKJoyrideStep
      stepWithMessage:@"Click <symbol play.fill color=accent /> to play, then "
                      @"again to <accent>pause</accent> — handy when "
                      @"<warn>spacebar</warn> isn't working"
           targetView:nil];
  sPlay.targetScreenRect = ^NSRect {
    __strong typeof(self) s = weak;
    return s ? [s guidePlayButtonScreenRect] : NSZeroRect;
  };

  KKJoyrideStep *s2 = [KKJoyrideStep
      stepWithMessage:@"Tap <symbol plus.circle.fill color=accent /> to add "
                      @"<accent>Crop</accent> and <accent>Radius</accent> "
                      @"for animation"
           targetView:^NSView * {
             __strong KKTimelineLanesView *b = weakBasic;
             return b.footerView;
           }];

  KKJoyrideStep *s3 =
      [KKJoyrideStep stepWithMessage:@"Tap <accent>Crop</accent>"
                          targetView:nil];
  s3.targetScreenRect = ^NSRect {
    __strong KKTimelineLanesView *b = weakBasic;
    return b ? [b guideManagePopoverItemScreenRectForLabel:@"Crop"]
             : NSZeroRect;
  };

  KKJoyrideStep *s4 =
      [KKJoyrideStep stepWithMessage:@"Tap <accent>Radius</accent>"
                          targetView:nil];
  s4.targetScreenRect = ^NSRect {
    __strong KKTimelineLanesView *b = weakBasic;
    return b ? [b guideManagePopoverItemScreenRectForLabel:@"Radius"]
             : NSZeroRect;
  };

  KKJoyrideStep *s5 = [KKJoyrideStep
      stepWithMessage:@"Basic timing has three phases: <accent>In</accent>, "
                      @"<accent>Hold</accent>, and <accent>Out</accent>"
           targetView:^NSView * {
             __strong KKTimelineBasicView *g = weakGraph;
             return g;
           }];
  s5.showsNext = YES;

  KKJoyrideStep *s6 = [KKJoyrideStep
      stepWithMessage:@"Turn on the <accent>In</accent> transition"
           targetView:nil];
  s6.targetScreenRect = ^NSRect {
    __strong KKTimelineBasicView *g = weakGraph;
    return g ? [g guidePhaseToggleScreenRectForPhase:0] : NSZeroRect;
  };

  KKJoyrideStep *sGraph = [KKJoyrideStep
      stepWithMessage:@"Notice the <accent>graph</accent> has updated to "
                      @"show the general movement"
           targetView:^NSView * {
             __strong KKTimelineBasicView *g = weakGraph;
             return g;
           }];
  sGraph.showsNext = YES;

  KKJoyrideStep *sDiamond = [KKJoyrideStep
      stepWithMessage:@"Click one of the <accent>diamonds</accent> to edit "
                      @"values at that point in time"
           targetView:nil];
  sDiamond.targetScreenRect = ^NSRect {
    __strong KKTimelineBasicView *g = weakGraph;
    return g ? [g guideDiamondScreenRectForIndex:kDiamondTarget] : NSZeroRect;
  };

  KKJoyrideStep *sMini = [KKJoyrideStep
      stepWithMessage:@"This <accent>mini viewer</accent> shows the clip at "
                      @"this point in time — no need to scrub around"
           targetView:^NSView * {
             return weakBoundaryMini;
           }];
  sMini.showsNext = YES;

  // Drag the radius dot OR a crop corner inside the boundary popover —
  // same canvas API the constants guide uses for radius/crop drags, so the
  // popover's onDragBegin/onHandleValue/onDragEnd fire in a clean pair (no
  // leaked action scopes). Advances once both Crop AND Radius have been
  // changed (tracked via onStaticValueChanged below).
  KKJoyrideStep *sEdit = [KKJoyrideStep
      stepWithMessage:@"Drag the <accent>dot</accent> for Radius or a "
                      @"<accent>corner</accent> for Crop"
           targetView:nil];
  sEdit.spotlightCircular = NO;
  sEdit.spotlightPassThrough = YES;
  sEdit.targetScreenRect = ^NSRect {
    __strong NSView *content = weakBoundaryPopoverContent;
    NSWindow *w = content.window;
    if (!content || !w)
      return NSZeroRect;
    return [w convertRectToScreen:[content convertRect:content.bounds
                                                toView:nil]];
  };
  sEdit.spotlightMouseDown = ^(NSPoint p) {
    [weakBoundaryMini beginPointHandleDragAtScreenPoint:p];
  };
  sEdit.spotlightMouseDragged = ^(NSPoint p) {
    [weakBoundaryMini dragPointHandleToScreenPoint:p];
  };
  sEdit.spotlightMouseUp = ^(NSPoint p) {
    [weakBoundaryMini endPointHandleDrag];
  };
  sEdit.onEnter = ^{
    cropChanged = NO;
    radiusChanged = NO;
  };

  KKJoyrideStep *sGap = [KKJoyrideStep
      stepWithMessage:@"Click the <accent>gap</accent> between keyposes to "
                      @"edit timing"
           targetView:nil];
  sGap.targetScreenRect = ^NSRect {
    __strong KKTimelineBasicView *g = weakGraph;
    return g ? [g guideGapScreenRectForSection:1 /* KKBasicSectionIn */]
             : NSZeroRect;
  };

  // No spotlightPassThrough — that sends the click to FCP. We want it
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
      clickMessage:@"Drag the <accent>diamond</accent> toward the "
                   @"<warn>glowing target</warn> (0.8s)"
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
      stepWithMessage:@"Let's <accent>watch it back</accent> — click play"
           targetView:nil];
  // Cutout encompasses both the play button AND the FCP viewer (when the OSC
  // is alive — the shared bridge gives us the viewer image rect). Non-
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
  __block CFAbsoluteTime watchBackEnteredAt = 0;
  sWatchBack.onEnter = ^{
    __strong typeof(self) s = weak;
    watchBackEnteredAt = CFAbsoluteTimeGetCurrent();
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
      stepWithMessage:@"That's all you need to know to get going!"
           targetView:^NSView * {
             __strong KKTimelineBasicView *g = weakGraph;
             return g;
           }];

  KKJoyrideStep *sSpring =
      [KKJoyrideStep stepWithMessage:@"Pick the <accent>Spring</accent> curve"
                          targetView:nil];
  sSpring.targetScreenRect = ^NSRect {
    __strong KKSegmentEditView *e = weakGapEditor;
    return e ? [e guideCurvePillScreenRectForCurve:kSpringCurveType]
             : NSZeroRect;
  };

  self.basicLanesView.onManagePopoverWillOpen = ^(NSView *row) {
    __strong KKJoyrideController *g = weakGuide;
    g.additionalPassthroughWindow = row.window;
    if (g.isActive && g.currentStepIndex == ixAdd)
      [g advance];
  };
  self.basicLanesView.onManagePopoverClosed = ^{
    __strong KKJoyrideController *g = weakGuide;
    g.additionalPassthroughWindow = nil;
    // If the user dismisses the popover before adding both lanes, end the
    // guide (the saved timeline is restored in onComplete).
    if (g.isActive &&
        (g.currentStepIndex == ixAddCrop || g.currentStepIndex == ixAddRadius))
      [g dismiss];
  };
  self.basicLanesView.onLaneOptedIn = ^(NSString *label) {
    __strong KKJoyrideController *g = weakGuide;
    __strong KKTimelineLanesView *basic = weakBasic;
    if (!g)
      return;
    if (g.currentStepIndex == ixAddCrop && [label isEqualToString:@"Crop"]) {
      [g advance];
    } else if (g.currentStepIndex == ixAddRadius &&
               [label isEqualToString:@"Radius"]) {
      [g advance];
      // Both lanes added — close the popover so the basic graph is in view
      // for the next steps. Defer per the intro-guide pattern; closing in
      // the toggle's call stack cascades through applyTimeline:.
      dispatch_async(dispatch_get_main_queue(), ^{
        [basic closeManagePopover];
      });
    }
  };
  self.basicLanesView.basicGraph.onPhaseToggled = ^(NSInteger phase, BOOL on) {
    __strong KKJoyrideController *g = weakGuide;
    if (g && g.currentStepIndex == ixToggleIn && phase == 0 && on)
      [g advance];
  };
  // Track which diamond the user tapped so the popover-open handler can
  // distinguish "advanced from the diamond step" from "popover opened for
  // some other reason." Doesn't advance directly — the canvas isn't found
  // until willOpen fires (after the popover entrance-animation settle), so
  // advancing here would leave sMini's targetView nil for ~0.25s and the
  // cutout would draw in the wrong place.
  __block BOOL armedForDiamondAdvance = NO;
  self.basicLanesView.basicGraph.onDiamondTapped = ^(NSInteger idx) {
    __strong KKJoyrideController *g = weakGuide;
    if (g && g.currentStepIndex == ixDiamondClick && idx == kDiamondTarget)
      armedForDiamondAdvance = YES;
  };
  // Boundary popover (re-uses the constants popover machinery + callbacks).
  // willOpen gives us the mini canvas for sMini's cutout; closed dismisses
  // the guide if the user closes the popover while we still need it.
  self.basicLanesView.onStaticValuesPopoverWillOpen =
      ^(NSView *content, KKMiniCanvasView *cv) {
        __strong KKJoyrideController *g = weakGuide;
        weakBoundaryMini = cv;
        weakBoundaryPopoverContent = content;
        g.additionalPassthroughWindow = content.window;
        // Now that the canvas reference is live, advance from the diamond
        // step (if we're still on it and the user tapped the right one).
        if (g.isActive && g.currentStepIndex == ixDiamondClick &&
            armedForDiamondAdvance) {
          armedForDiamondAdvance = NO;
          [g advance];
        }
      };
  self.basicLanesView.onStaticValuesPopoverClosed = ^{
    __strong KKJoyrideController *g = weakGuide;
    g.additionalPassthroughWindow = nil;
    weakBoundaryMini = nil;
    weakBoundaryPopoverContent = nil;
    // If the user dismisses the popover before finishing the in-popover
    // steps, end the guide (saved timeline restored in onComplete).
    if (g.isActive && (g.currentStepIndex == ixMiniViewer ||
                       g.currentStepIndex == ixCropRadius))
      [g dismiss];
  };
  // Gap tap: arm an advance flag, but DON'T advance yet — the segment
  // editor isn't reachable until onGapPopoverWillOpen fires after the
  // popover's settle delay. Advancing here would land sSpring with a nil
  // editor (targetScreenRect returns NSZeroRect → cutout in the wrong
  // place). Same pattern as diamond → mini-viewer.
  __block BOOL armedForGapAdvance = NO;
  self.basicLanesView.basicGraph.onGapTapped = ^(NSInteger section) {
    __strong KKJoyrideController *g = weakGuide;
    if (g && g.currentStepIndex == ixGapClick &&
        section == 1 /* KKBasicSectionIn */)
      armedForGapAdvance = YES;
  };
  self.basicLanesView.onGapPopoverWillOpen = ^(NSView *content,
                                               KKSegmentEditView *editor) {
    __strong KKJoyrideController *g = weakGuide;
    weakGapEditor = editor;
    g.additionalPassthroughWindow = content.window;
    if (g.isActive && g.currentStepIndex == ixGapClick && armedForGapAdvance) {
      armedForGapAdvance = NO;
      [g advance];
    }
  };
  // Curve pick in the gap popover → advance from sSpring + close popover.
  self.basicLanesView.onGapPopoverCurveChanged = ^(NSInteger curveType) {
    __strong KKJoyrideController *g = weakGuide;
    __strong KKTimelineLanesView *basic = weakBasic;
    if (!g || g.currentStepIndex != ixSpringPick)
      return;
    if (curveType != kSpringCurveType)
      return;
    [g advance];
    dispatch_async(dispatch_get_main_queue(), ^{
      [basic guideCloseContentPopover];
    });
  };

  // Advance ONLY after a drag completes — not on per-tick value changes.
  // Advancing mid-drag tears down the spotlight monitors, so the synthesized
  // mouseUp never fires, endPointHandleDrag never runs, onDragEnd never
  // closes the "Adjust Radius" undo group — the next FCP action collides
  // and abort()s. onStaticValueDragEnded fires AFTER the wrapper has
  // committed the value AND called the host onDragEnd (which closes the
  // group), so it's safe to advance from here.
  self.basicLanesView.onStaticValueDragEnded =
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
          // Defer close per the manage-popover pattern — closing inside the
          // value-change call stack cascades through applyTimeline:.
          dispatch_async(dispatch_get_main_queue(), ^{
            [basic guideCloseContentPopover];
          });
        }
      };
  // Step 2 (sPlay): track play→pause edge. Only count the pause AFTER the
  // user has played in this step (so entering already-playing doesn't fast-
  // forward, and a stray off-on-off during another step is ignored).
  // Step 15 (sWatchBack): user clicks play → wait kWatchBackSeconds → auto-
  // pause and advance. Don't await a manual pause — the guide handles it.
  __block BOOL playStartedInPlayStep = NO;
  self.onPlayingChanged = ^(BOOL playing) {
    __strong typeof(self) strong = weak;
    __strong KKJoyrideController *g = weakGuide;
    if (!g)
      return;
    if (g.currentStepIndex == ixPlay) {
      if (playing) {
        playStartedInPlayStep = YES;
      } else if (playStartedInPlayStep) {
        playStartedInPlayStep = NO;
        [g advance];
      }
      return;
    }
    if (g.currentStepIndex == ixWatchBack && playing) {
      // Ignore the spurious play=1 FCP pushes right after onScrub(0.0)
      // (movePlayheadToTime: produces a play/stop blip within ~150ms). If
      // we don't, we'd schedule auto-pause too early and the 1s toggle
      // would end up STARTING playback instead of stopping it.
      if (CFAbsoluteTimeGetCurrent() - watchBackEnteredAt < 0.3)
        return;
      dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                   (int64_t)(kWatchBackSeconds * NSEC_PER_SEC)),
                     dispatch_get_main_queue(), ^{
                       __strong typeof(weak) s2 = weak;
                       __strong KKJoyrideController *g2 = weakGuide;
                       if (!s2 || !g2 || g2.currentStepIndex != ixWatchBack)
                         return;
                       if (s2.onTogglePlayback)
                         s2.onTogglePlayback();
                       [g2 advance];
                     });
      (void)strong;
    }
  };

  return @[
    s1, sPlay, s2, s3, s4, s5, s6, sGraph, sDiamond, sMini, sEdit, sGap,
    sSpring, sDrag, sWatchBack, sDone
  ];
}

- (void)_startBasicTimingGuide {
  [_basicTimingGuide dismiss];

  __weak typeof(self) weak = self;
  __weak KKTimelineLanesView *weakBasic = self.basicLanesView;
  KKJoyrideController *guide =
      [[KKJoyrideController alloc] initWithHostView:self];
  // forwardsGestures: panel intercepts clicks instead of ignoresMouseEvents
  // letting them through. Without this, a click inside the spotlight reaches
  // the popover natively (canvas's own mouseDown → onHandleDragBegin) AND
  // fires the spotlight block (beginPointHandleDragAtScreenPoint: → ALSO
  // onHandleDragBegin) — two "Adjust Radius" undo groups race for the same
  // channel and FCP abort()s. Constants guide uses the same flag.
  guide.forwardsGestures = YES;
  __weak KKJoyrideController *weakGuide = guide;
  NSArray<KKJoyrideStep *> *steps = [self _basicTimingStepsForGuide:guide];
  NSInteger finalIdx = (NSInteger)steps.count - 1;

  [guide startWithSteps:steps
             onComplete:^{
               __strong typeof(self) strong = weak;
               __strong KKTimelineLanesView *basic = weakBasic;

               __strong KKJoyrideController *cg = weakGuide;
               if (cg && cg.currentStepIndex >= finalIdx &&
                   strong.onGuideCompleted)
                 strong.onGuideCompleted();

               if (basic) {
                 basic.onManagePopoverWillOpen = nil;
                 basic.onManagePopoverClosed = nil;
                 basic.onLaneOptedIn = nil;
                 basic.onStaticValuesPopoverWillOpen = nil;
                 basic.onStaticValuesPopoverClosed = nil;
                 basic.onStaticValueChanged = nil;
                 basic.basicGraph.onPhaseToggled = nil;
                 basic.basicGraph.onDiamondTapped = nil;
                 basic.basicGraph.onGapTapped = nil;
                 basic.onGapPopoverWillOpen = nil;
                 basic.onGapPopoverCurveChanged = nil;
               }
               if (strong)
                 strong.onPlayingChanged = nil;

               KKJoyrideController *toRelease =
                   strong ? strong->_basicTimingGuide : nil;
               if (strong)
                 strong->_basicTimingGuide = nil;
               if (toRelease) {
                 dispatch_async(dispatch_get_main_queue(), ^{
                   [toRelease release];
                 });
               }

               KKTimeline *saved =
                   strong ? strong->_savedBasicTimingTimeline : nil;
               if (strong)
                 strong->_savedBasicTimingTimeline = nil;
               if (saved) {
                 dispatch_async(dispatch_get_main_queue(), ^{
                   __strong typeof(self) s2 = weak;
                   __strong KKTimelineLanesView *b2 = weakBasic;
                   if (b2) {
                     [b2 applyTimeline:saved];
                     if (s2 && s2.onTimelineMutated)
                       s2.onTimelineMutated(saved);
                   }
                 });
                 [saved release];
               }
             }];
  _basicTimingGuide = guide;
}

- (void)restartBasicTimingGuide {
  [_savedBasicTimingTimeline release];
  _savedBasicTimingTimeline = [self.basicLanesView.currentTimeline retain];

  KKTimeline *empty = [KKTimeline timeline];
  [self.basicLanesView applyTimeline:empty];
  if (self.onTimelineMutated)
    self.onTimelineMutated(empty);

  // Prereq: park the host playhead at clip start so every step (and the
  // boundary mini-viewer) renders from a predictable position. onScrub is
  // host-aware (FxCommandAPI movePlayheadToTime:); the plugin wires it.
  if (self.onScrub)
    self.onScrub(0.0);

  [self _startBasicTimingGuide];
}

- (void)restartFullWalkthroughGuide {
  // One controller: inspector intro steps, then OSC steps. Because some steps
  // need the OSC, do the OSC setup UP FRONT — the zoom-to-fit AppleScript
  // steals FCP focus, so it must fire before the overlay exists (exactly like
  // restartOSCGuide). Running it mid-guide pulled FCP in front and dropped the
  // overlay behind. Save the pre-guide timeline once; the intro portion starts
  // from a clean slate, restored on complete/skip.
  RoundedSetOSCGuideStep(0);
  RoundedSetGuideRadius(20.0);

  [_savedFullTimeline release];
  _savedFullTimeline = [self.basicLanesView.currentTimeline retain];

  KKTimeline *empty = [KKTimeline timeline];
  [self.basicLanesView applyTimeline:empty];
  if (self.onTimelineMutated)
    self.onTimelineMutated(empty);

  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    RoundedTriggerHostZoomToFit();
    // Async zoom-to-fit; wait for FCP to resize the viewer, then force a
    // param write so parameterChanged → re-render → drawOSC runs at the FINAL
    // geometry. Then start the guide — the focus steal is already done and
    // the overlay comes up on top and stays there through both portions.
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.6 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          __strong typeof(self) s = weakSelf;
          if (!s)
            return;
          KKTimeline *settle = [KKTimeline timeline];
          [s.basicLanesView applyTimeline:settle];
          if (s.onTimelineMutated)
            s.onTimelineMutated(settle);
          dispatch_after(
              dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.2 * NSEC_PER_SEC)),
              dispatch_get_main_queue(), ^{
                __strong typeof(self) s2 = weakSelf;
                if (s2)
                  [s2 _startFullWalkthroughGuide];
              });
        });
  });
}

@end
