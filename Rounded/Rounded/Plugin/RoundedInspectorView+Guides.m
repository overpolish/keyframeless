/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "RoundedInspectorView+Guides.h"
#import "RoundedInspectorView_Private.h"
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKOSCGuideBridge.h>
#import <KeyframelessKit/KKOSCGuideStrategy.h>

static NSString *const kRoundedIntroSeenKey = @"RoundedIntroSeen";

// Snap tolerance (radius units) that counts as "hit" for the OSC guide target.
static const double kOSCGuideTargetSnap = 4.0;

// Triggers FCP's "Zoom to Fit" (View menu) via System Events AppleScript.
// Runs synchronously — call from a background queue or dispatch_async.
static void RoundedTriggerFCPZoomToFit(void) {
  NSString *src = @"tell application \"System Events\"\n"
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
                   "end tell";
  NSAppleScript *script = [[NSAppleScript alloc] initWithSource:src];
  NSDictionary *err = nil;
  [script executeAndReturnError:&err];
  if (err)
    KKLogWarn(@"[OSCGuide] zoom-to-fit AppleScript error: %@", err);
  else
    KKLogInfo(@"[OSCGuide] zoom-to-fit triggered via AppleScript");
  [script release];
}

@implementation RoundedInspectorView (Guides)

- (void)_maybeAutostartIntroGuide {
  if (_isDetachedCopy)
    return;
  if (!self.window)
    return;
  if (_basicView.currentTimeline.lanes.count > 0)
    return;
  if ([NSUserDefaults.standardUserDefaults boolForKey:kRoundedIntroSeenKey])
    return;
  __weak typeof(self) weak = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong typeof(self) strong = weak;
    if (!strong || !strong.window)
      return;
    if (strong->_basicView.currentTimeline.lanes.count > 0)
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
  __weak KKTimelineLanesView *weakBasic = _basicView;
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

  _basicView.onManagePopoverWillOpen = ^(NSView *row) {
    step2Row = row;
    __strong KKJoyrideController *g = weakGuide;
    g.additionalPassthroughWindow = row.window;
    [g advance];
  };
  _basicView.onManagePopoverClosed = ^{
    __strong KKJoyrideController *g = weakGuide;
    g.additionalPassthroughWindow = nil;
    if (g.isActive && g.currentStepIndex == 1)
      [g dismiss];
  };
  _basicView.onLaneOptedIn = ^(NSString *label) {
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
  __weak KKTimelineLanesView *weakBasic = _basicView;
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
  _savedIntroTimeline = [_basicView.currentTimeline retain];
  KKTimeline *empty = [KKTimeline timeline];
  [_basicView applyTimeline:empty];
  if (self.onTimelineMutated)
    self.onTimelineMutated(empty);
  [self _startIntroGuide];
}

// The point-OSC value mapping for the generic KKJoyrideOSCSegment: how a
// screen drag becomes a radius and back. This is the only OSC-shape-specific
// code the inspector still owns — a different OSC supplies its own strategy.
- (KKOSCGuideStrategy *)_pointOSCStrategy {
  __weak typeof(self) weak = self;
  __weak KKTimelineLanesView *weakBasic = _basicView;
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
  KKLogInfo(@"[OSCGuide] _startOSCGuide called, window=%@", self.window);
  [_oscGuide dismiss];

  __weak typeof(self) weak = self;
  __weak KKTimelineLanesView *weakBasic = _basicView;
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
  KKLogInfo(@"[OSCGuide] guide started, isActive=%d", (int)guide.isActive);
}

// Builds the guide's single-lane Radius timeline at the given value. The OSC
// reads radius from this blob (via parameterChanged → instance state), so
// writing it is the only channel that moves the on-screen control — the
// in-viewer OSC never receives events through the overlay and its API is nil
// outside FCP callbacks.
- (KKTimeline *)_guideTimelineWithRadius:(double)radius {
  KKTimeline *tl = [KKTimeline timeline];
  KKLane *radiusLane = [KKLane laneWithLabel:@"Radius"];
  radiusLane.enabled = YES;
  radiusLane.valueType = KKLaneValueTypeFloat;
  radiusLane.componentMin = @[ @0.0 ];
  radiusLane.componentMax = @[ @100.0 ];
  KKKeyPose *kp = [KKKeyPose keyposeAtTime:0.0 values:@[ @(radius) ]];
  radiusLane.keyposes = @[ kp ];
  tl.lanes = @[ radiusLane ];
  return tl;
}

- (double)_guideCurrentRadius {
  for (KKLane *lane in _basicView.currentTimeline.lanes) {
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
  _savedOSCTimeline = [_basicView.currentTimeline retain];

  KKTimeline *clean = [self _guideTimelineWithRadius:20.0];

  [_basicView applyTimeline:clean];
  if (self.onTimelineMutated)
    self.onTimelineMutated(clean);

  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    RoundedTriggerFCPZoomToFit();
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
          KKLogInfo(@"[OSCGuide] post-resize forced param write to "
                    @"retrigger drawOSC at final geometry");
          KKTimeline *settle = [s _guideTimelineWithRadius:20.0];
          [s->_basicView applyTimeline:settle];
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
  [_basicView applyTimeline:clean];
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
  __weak KKTimelineLanesView *weakBasic = _basicView;
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
  _savedFullTimeline = [_basicView.currentTimeline retain];

  KKTimeline *empty = [KKTimeline timeline];
  [_basicView applyTimeline:empty];
  if (self.onTimelineMutated)
    self.onTimelineMutated(empty);

  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    RoundedTriggerFCPZoomToFit();
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
          KKLogInfo(@"[FullWalkthrough] post-resize forced param write to "
                    @"retrigger drawOSC at final geometry");
          KKTimeline *settle = [KKTimeline timeline];
          [s->_basicView applyTimeline:settle];
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
