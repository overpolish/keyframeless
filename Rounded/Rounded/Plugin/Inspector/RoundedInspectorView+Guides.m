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
