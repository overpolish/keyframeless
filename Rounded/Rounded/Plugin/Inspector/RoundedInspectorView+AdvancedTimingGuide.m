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

@implementation RoundedInspectorView (AdvancedTimingGuide)

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

@end
