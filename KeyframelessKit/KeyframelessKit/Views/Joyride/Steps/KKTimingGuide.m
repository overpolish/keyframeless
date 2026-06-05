/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimingGuide.h"

#import "KKLocalized.h"
#import <KeyframelessKit/KKHelpSection.h>
#import <KeyframelessKit/KKJoyrideController.h>
#import <KeyframelessKit/KKJoyrideDragStep.h>
#import <KeyframelessKit/KKJoyrideLanesBinder.h>
#import <KeyframelessKit/KKJoyrideTrigger.h>
#import <KeyframelessKit/KKMiniCanvasView.h>
#import <KeyframelessKit/KKSegmentEditView+Guide.h>
#import <KeyframelessKit/KKTimelineAdvancedView.h>
#import <KeyframelessKit/KKTimelineBasicView+Guide.h>
#import <KeyframelessKit/KKTimelineBasicView.h>
#import <KeyframelessKit/KKTimelineInspectorView+Guide.h>
#import <KeyframelessKit/KKTimelineLanesView+Guide.h>
#import <KeyframelessKit/KKTimelineLanesView.h>
#import <KeyframelessKit/KKTimingStage.h>

// Spring == KKIntervalCurveElastic (Linear=0, EaseIn=1, EaseOut=2,
// EaseInOut=3, Elastic=4, Bounce=5) - presented to users as "Spring".
static const NSInteger kSpringCurveType = 4;
// KKBasicSectionIn - the In phase gap section in the Basic graph.
static const NSInteger kBasicSectionIn = 1;
// Chronologically the second diamond once In is on (the hold-start / In-end
// keypose the user just watched appear).
static const NSInteger kDiamondTarget = 2;
// Watch-back: play this long before auto-pausing + advancing.
static const double kWatchBackSeconds = 1.0;
// Drag the In-end diamond toward 1.0s; snap windows for magnet + release.
static const double kDragTargetSeconds = 1.0;
static const double kDragSnapSeconds = 0.05;
static const CGFloat kDragSnapPx = 14.0;

@implementation KKTimingGuide

+ (NSArray<KKHelpGuide *> *)
    standardHelpGuidesForInspectorProvider:
        (KKTimelineInspectorView * (^)(void))inspectorProvider
                           enabledProvider:(BOOL (^)(void))enabledProvider {
  // Introduction == the Basic timing walkthrough every plugin teaches.
  __block __weak KKHelpGuide *weakIntro = nil;
  KKHelpGuide *intro = [KKHelpGuide
      guideWithTitle:KKLoc(@"Introduction",
                           @"Help guide title: basic timing walkthrough.")
            subtitle:KKLoc(@"Learn the basics of timing",
                           @"Help guide subtitle: Introduction.")
             onStart:^{
               KKTimelineInspectorView *iv =
                   inspectorProvider ? inspectorProvider() : nil;
               if (!iv)
                 return;
               // Strong-capture so completion still marks even after the help
               // window (and its weak ref) goes away.
               KKHelpGuide *live = weakIntro;
               iv.onGuideCompleted = ^{
                 [live markCompleted];
               };
               [iv restartBasicTimingGuide];
             }];
  weakIntro = intro;
  intro.identifier = @"timing.intro"; // stable across localized titles

  __block __weak KKHelpGuide *weakAdvanced = nil;
  KKHelpGuide *advanced = [KKHelpGuide
      guideWithTitle:KKLoc(@"Advanced Timing",
                           @"Help guide title: advanced timing walkthrough.")
            subtitle:KKLoc(@"Add keyposes anywhere and shape transitions per "
                           @"property",
                           @"Help guide subtitle: Advanced Timing.")
             onStart:^{
               KKTimelineInspectorView *iv =
                   inspectorProvider ? inspectorProvider() : nil;
               if (!iv)
                 return;
               KKHelpGuide *live = weakAdvanced;
               iv.onGuideCompleted = ^{
                 [live markCompleted];
               };
               [iv restartAdvancedTimingGuide];
             }];
  weakAdvanced = advanced;
  advanced.identifier = @"timing.advanced";

  // The final Basic step's cutout unions the play button with the FCP viewer
  // rect, which only resolves once the OSC bridge has a draw tick - so both
  // guides gate on the same canvas reference the plugin supplies.
  NSString *disabled =
      KKLoc(@"Guides are disabled. Click the effect's header on a clip to "
            @"select it (it highlights yellow), then move your mouse over the "
            @"viewer to enable them.",
            @"Help guide disabled subtitle (no OSC canvas reference yet).");
  for (KKHelpGuide *g in @[ intro, advanced ]) {
    g.enabledProvider = enabledProvider;
    g.disabledSubtitle = disabled;
  }
  return @[ intro, advanced ];
}

+ (KKTimeline *)basicSeedTimelineForConfig:(KKTimingGuideConfig *)config {
  KKTimeline *tl = [KKTimeline timeline];
  KKLane *primary = [KKLane laneWithLabel:config.primaryLabel];
  primary.enabled = NO; // constant until the user opts it in to animation
  primary.valueType = (KKLaneValueType)config.primaryValueType;
  primary.keyposes = @[ [KKKeyPose keyposeAtTime:0.0
                                          values:config.primarySeedValues] ];
  tl.lanes = @[ primary ];
  return tl;
}

+ (KKLane *)_seedLaneWithLabel:(NSString *)label
                     valueType:(NSInteger)valueType
                        values:(NSArray<NSNumber *> *)values {
  KKLane *lane = [KKLane laneWithLabel:label];
  lane.enabled = YES; // animatable
  lane.valueType = (KKLaneValueType)valueType;
  lane.keyposes = @[
    [KKKeyPose keyposeAtTime:0.0 values:values],
    [KKKeyPose keyposeAtTime:1.0 values:values],
  ];
  return lane;
}

+ (KKTimeline *)advancedSeedTimelineForConfig:(KKTimingGuideConfig *)config {
  KKTimeline *tl = [KKTimeline timeline];
  KKLane *primary = [self _seedLaneWithLabel:config.primaryLabel
                                   valueType:config.primaryValueType
                                      values:config.primarySeedValues];
  NSMutableArray<KKLane *> *lanes = [NSMutableArray array];
  if (config.secondaryLabel) {
    KKLane *secondary = [self _seedLaneWithLabel:config.secondaryLabel
                                       valueType:config.secondaryValueType
                                          values:config.secondarySeedValues];
    [lanes addObject:secondary];
  }
  [lanes addObject:primary];
  // KKTimelineLanesView sorts lanes alphabetically for display; order the
  // seed to match so guide row lookups land on the right row.
  [lanes sortUsingComparator:^NSComparisonResult(KKLane *a, KKLane *b) {
    return [a.label compare:b.label];
  }];
  tl.lanes = lanes;
  return tl;
}

+ (NSArray<KKJoyrideStep *> *)basicStepsForGuide:(KKJoyrideController *)guide
                                          binder:(KKJoyrideLanesBinder *)binder
                                          config:(KKTimingGuideConfig *)config {
  __weak KKJoyrideController *weakGuide = guide;
  __weak KKJoyrideLanesBinder *weakBinder = binder;
  KKTimelineLanesView *lanes = config.lanesView;
  __weak KKTimelineLanesView *weakLanes = lanes;
  __weak KKTimelineBasicView *weakGraph = lanes.basicGraph;
  NSString *primary = config.primaryLabel;

  const NSInteger ixIntro = 0, ixOpenConstants = 1, ixEditConstant = 2,
                  ixAdd = 3, ixAddPrimary = 4, ixPhases = 5, ixToggleIn = 6,
                  ixGraphNotice = 7, ixDiamondClick = 8, ixEdit = 9,
                  ixGapClick = 10, ixSpringPick = 11, ixDragBoundary = 12,
                  ixWatchBack = 13, ixDone = 14;
  (void)ixIntro;
  (void)ixPhases;
  (void)ixGraphNotice;
  (void)ixDone;

  __block BOOL watchBackScheduled = NO;

  KKJoyrideStep *sIntro = [KKJoyrideStep
      stepWithMessage:KKLoc(@"This is where you shape <accent>timing</accent>: "
                            @"how a property changes over the clip.",
                            @"Timing guide: intro to the timing editor.")
           targetView:^NSView * {
             return weakGraph;
           }];
  sIntro.showsNext = YES;

  KKJoyrideStep *sOpenConstants = [KKJoyrideStep
      stepWithMessage:KKLoc(@"Values you don't animate stay "
                            @"<accent>constant</accent>. Open the "
                            @"<accent>Constants</accent> panel to edit them.",
                            @"Timing guide: open the Constants panel.")
           targetView:^NSView * {
             return config.constantsButtonView ? config.constantsButtonView()
                                               : nil;
           }];

  // The constant edit is a drag-to-destination: the primary handle glows, an
  // amber target marks where to drag it. Scalar lanes (Radius) target a single
  // value; spatial lanes (Position) target the 2D point.
  NSArray<NSNumber *> *targetVals = config.primaryTargetValues;
  NSInteger compCount = config.primaryComponentCount;
  NSRect (^editTargetRect)(void) = ^NSRect {
    __strong KKMiniCanvasView *c = weakBinder.latestMiniCanvas;
    if (!c || targetVals.count == 0)
      return NSZeroRect;
    return compCount >= 2
               ? [c pointHandleScreenRectForValues:targetVals]
               : [c pointHandleScreenRectForValue:targetVals.firstObject
                                                      .doubleValue];
  };
  KKJoyrideStep *sEditConstant = [KKJoyrideDragStep stepForGuide:guide
      atIndex:ixEditConstant
      isLast:NO
      clickMessage:[NSString
                       stringWithFormat:
                           KKLoc(@"Drag <accent>%@</accent> toward the "
                                 @"<warn>target</warn>. It applies straight "
                                 @"away.",
                                 @"Timing guide: drag a constant to a target. "
                                 @"%@ = property name."),
                           primary]
      dragMessage:KKLoc(@"Drag toward the <warn>glowing target</warn>.",
                        @"Timing guide: drag-to-target hint.")
      circular:YES
      spotRect:^NSRect {
        __strong KKMiniCanvasView *c = weakBinder.latestMiniCanvas;
        return c ? [c pointHandleScreenRect] : NSZeroRect;
      }
      targetRect:editTargetRect
      begin:^(NSPoint p) {
        // Press at the handle's exact centre, not the captured click: the
        // arc ring is large, so an off-centre press would carry a grab offset
        // through the delta-based drag and land the handle off the target.
        __strong KKMiniCanvasView *c = weakBinder.latestMiniCanvas;
        NSRect spot = [c pointHandleScreenRect];
        [c beginPointHandleDragAtScreenPoint:NSIsEmptyRect(spot)
                                                 ? p
                                                 : NSMakePoint(NSMidX(spot),
                                                               NSMidY(spot))];
      }
      dragTo:^(NSPoint p) {
        [weakBinder.latestMiniCanvas
            dragPointHandleToScreenPoint:KKJoyrideSnapToTarget(
                                             p, editTargetRect(), 9.0)];
      }
      end:^{
        [weakBinder.latestMiniCanvas endPointHandleDrag];
      }
      hitOnRelease:^BOOL(NSPoint p) {
        NSRect t = editTargetRect();
        double dpx =
            NSIsEmptyRect(t) ? 1e9 : hypot(p.x - NSMidX(t), p.y - NSMidY(t));
        return dpx <= 14.0;
      }];

  KKJoyrideStep *sAdd = [KKJoyrideStep
      stepWithMessage:KKLoc(@"Plugins don't animate by default. Tap <symbol "
                            @"plus.circle.fill color=accent /> to give a "
                            @"property a lane.",
                            @"Timing guide: open the Animated dropdown.")
           targetView:^NSView * {
             return weakLanes.footerView;
           }];
  // Close the constants popover left open by the drag-to-destination step.
  sAdd.onEnter = ^{
    [weakLanes guideCloseContentPopover];
  };

  KKJoyrideStep *sAddPrimary = [KKJoyrideStep
      stepWithMessage:
          [NSString stringWithFormat:KKLoc(@"Add <accent>%@</accent>.",
                                           @"Timing guide: add the named "
                                           @"property. %@ = property name."),
                                     primary]
           targetView:nil];
  sAddPrimary.targetScreenRect = ^NSRect {
    __strong KKTimelineLanesView *l = weakLanes;
    return l ? [l guideManagePopoverItemScreenRectForLabel:primary]
             : NSZeroRect;
  };

  KKJoyrideStep *sPhases = [KKJoyrideStep
      stepWithMessage:KKLoc(
                          @"Basic timing has three phases: <accent>In</accent>"
                          @", <accent>Hold</accent>, <accent>Out</accent>.",
                          @"Timing guide: the three Basic phases.")
           targetView:^NSView * {
             return weakGraph;
           }];
  sPhases.showsNext = YES;

  KKJoyrideStep *sToggleIn = [KKJoyrideStep
      stepWithMessage:KKLoc(@"Turn <accent>In</accent> on to ease into the "
                            @"value from the start.",
                            @"Timing guide: enable the In transition.")
           targetView:nil];
  sToggleIn.targetScreenRect = ^NSRect {
    __strong KKTimelineBasicView *g = weakGraph;
    return g ? [g guidePhaseToggleScreenRectForPhase:0] : NSZeroRect;
  };

  KKJoyrideStep *sGraphNotice = [KKJoyrideStep
      stepWithMessage:KKLoc(@"The <accent>graph</accent> updates to show the "
                            @"movement.",
                            @"Timing guide: the graph reflects the transition.")
           targetView:^NSView * {
             return weakGraph;
           }];
  sGraphNotice.showsNext = YES;

  KKJoyrideStep *sDiamond = [KKJoyrideStep
      stepWithMessage:KKLoc(@"Each <accent>pill</accent> is a keypose, a "
                            @"value at a moment in time. Click one to edit it.",
                            @"Timing guide: edit a keypose pill.")
           targetView:nil];
  sDiamond.targetScreenRect = ^NSRect {
    __strong KKTimelineBasicView *g = weakGraph;
    return g ? [g guideDiamondScreenRectForIndex:kDiamondTarget] : NSZeroRect;
  };

  // Keypose edit is also a drag-to-destination (distinct target so the handle
  // visibly moves from the constant value).
  NSArray<NSNumber *> *kpTargetVals = config.keyposeTargetValues.count
                                          ? config.keyposeTargetValues
                                          : targetVals;
  NSRect (^kpTargetRect)(void) = ^NSRect {
    __strong KKMiniCanvasView *c = weakBinder.latestMiniCanvas;
    if (!c || kpTargetVals.count == 0)
      return NSZeroRect;
    return compCount >= 2
               ? [c pointHandleScreenRectForValues:kpTargetVals]
               : [c pointHandleScreenRectForValue:kpTargetVals.firstObject
                                                      .doubleValue];
  };
  KKJoyrideStep *sEdit = [KKJoyrideDragStep stepForGuide:guide
      atIndex:ixEdit
      isLast:NO
      clickMessage:KKLoc(@"The <accent>mini viewer</accent> shows the clip "
                         @"here. Drag the handle to the <warn>target</warn>.",
                         @"Timing guide: drag the keypose value to a target.")
      dragMessage:KKLoc(@"Drag toward the <warn>glowing target</warn>.",
                        @"Timing guide: drag-to-target hint.")
      circular:YES
      spotRect:^NSRect {
        __strong KKMiniCanvasView *c = weakBinder.latestMiniCanvas;
        return c ? [c pointHandleScreenRect] : NSZeroRect;
      }
      targetRect:kpTargetRect
      begin:^(NSPoint p) {
        // Press at the handle's exact centre, not the captured click: the
        // arc ring is large, so an off-centre press would carry a grab offset
        // through the delta-based drag and land the handle off the target.
        __strong KKMiniCanvasView *c = weakBinder.latestMiniCanvas;
        NSRect spot = [c pointHandleScreenRect];
        [c beginPointHandleDragAtScreenPoint:NSIsEmptyRect(spot)
                                                 ? p
                                                 : NSMakePoint(NSMidX(spot),
                                                               NSMidY(spot))];
      }
      dragTo:^(NSPoint p) {
        [weakBinder.latestMiniCanvas
            dragPointHandleToScreenPoint:KKJoyrideSnapToTarget(
                                             p, kpTargetRect(), 9.0)];
      }
      end:^{
        [weakBinder.latestMiniCanvas endPointHandleDrag];
      }
      hitOnRelease:^BOOL(NSPoint p) {
        NSRect t = kpTargetRect();
        double dpx =
            NSIsEmptyRect(t) ? 1e9 : hypot(p.x - NSMidX(t), p.y - NSMidY(t));
        return dpx <= 14.0;
      }];

  KKJoyrideStep *sGap = [KKJoyrideStep
      stepWithMessage:KKLoc(@"Click the <warn>gap</warn> between keyposes to "
                            @"change its easing.",
                            @"Timing guide: click a gap to edit easing.")
           targetView:nil];
  sGap.targetScreenRect = ^NSRect {
    __strong KKTimelineBasicView *g = weakGraph;
    return g ? [g guideGapScreenRectForSection:kBasicSectionIn] : NSZeroRect;
  };
  // Close the keypose popover left open by the keypose-edit drag step.
  sGap.onEnter = ^{
    [weakLanes guideCloseContentPopover];
  };

  KKJoyrideStep *sSpring = [KKJoyrideStep
      stepWithMessage:KKLoc(@"Pick <accent>Spring</accent> for a lively "
                            @"overshoot.",
                            @"Timing guide: choose the Spring easing curve.")
           targetView:nil];
  sSpring.targetScreenRect = ^NSRect {
    __strong KKSegmentEditView *e = weakBinder.latestGapSegmentEditor;
    return e ? [e guideCurvePillScreenRectForCurve:kSpringCurveType]
             : NSZeroRect;
  };

  NSRect (^dragSpotRect)(void) = ^NSRect {
    __strong KKTimelineBasicView *g = weakGraph;
    return g ? [g guideDiamondScreenRectForIndex:kDiamondTarget] : NSZeroRect;
  };
  NSRect (^dragTargetRect)(void) = ^NSRect {
    __strong KKTimelineBasicView *g = weakGraph;
    return g ? [g guideDiamondScreenRectAtTimeSeconds:kDragTargetSeconds
                                           forDiamond:kDiamondTarget]
             : NSZeroRect;
  };
  KKJoyrideStep *sDrag = [KKJoyrideDragStep stepForGuide:guide
      atIndex:ixDragBoundary
      isLast:NO
      clickMessage:KKLoc(@"Drag the <warn>boundary</warn> to retime where "
                         @"<accent>In</accent> ends.",
                         @"Timing guide: drag the hold boundary to retime.")
      dragMessage:nil
      circular:YES
      spotRect:dragSpotRect
      targetRect:dragTargetRect
      begin:^(NSPoint p) {
        [weakGraph guideBeginDragDiamondAtIndex:kDiamondTarget atScreenPoint:p];
      }
      dragTo:^(NSPoint p) {
        // No magnet: the Basic timeline is adaptive (log-warped), so snapping
        // the cursor to the target fights the remap and springs the diamond
        // on and off. Track the cursor directly; hitOnRelease still gates the
        // completion tolerance.
        [weakGraph guideDragDiamondToScreenPoint:p];
      }
      end:^{
        [weakGraph guideEndDiamondDrag];
      }
      hitOnRelease:^BOOL(NSPoint p) {
        double now =
            [weakGraph guideCurrentDiamondTimeSecondsForIndex:kDiamondTarget];
        if (isnan(now))
          return NO;
        return fabs(now - kDragTargetSeconds) <= kDragSnapSeconds;
      }];

  KKJoyrideStep *sWatchBack = [KKJoyrideStep
      stepWithMessage:KKLoc(@"Watch it back: press <symbol play.fill "
                            @"color=accent />.",
                            @"Timing guide: play the animation back.")
           targetView:nil];
  sWatchBack.spotlightCircular = NO;
  sWatchBack.targetScreenRect = ^NSRect {
    NSRect play = config.playButtonScreenRect ? config.playButtonScreenRect()
                                              : NSZeroRect;
    NSRect viewer =
        config.viewerScreenRect ? config.viewerScreenRect() : NSZeroRect;
    if (NSIsEmptyRect(viewer))
      return play;
    if (NSIsEmptyRect(play))
      return viewer;
    return NSUnionRect(play, viewer);
  };
  sWatchBack.onEnter = ^{
    watchBackScheduled = NO;
    if (config.scrubToFraction)
      config.scrubToFraction(0.0);
    if (config.requestPreviewRender)
      config.requestPreviewRender();
  };

  KKJoyrideStep *sDone = [KKJoyrideStep
      stepWithMessage:KKLoc(@"That's the <accent>basics</accent> of timing.",
                            @"Timing guide: closing step.")
           targetView:^NSView * {
             return weakGraph;
           }];

  // Bindings.
  [binder bindStep:sOpenConstants
           atIndex:ixOpenConstants
         advanceOn:[KKJoyrideTrigger staticValuesPopoverWillOpen]
         dismissOn:nil];
  [binder bindStep:sEditConstant
           atIndex:ixEditConstant
         advanceOn:nil
         dismissOn:[KKJoyrideTrigger staticValuesPopoverClosed]];
  [binder bindStep:sAdd
           atIndex:ixAdd
         advanceOn:[KKJoyrideTrigger managePopoverWillOpen]
         dismissOn:nil];
  [binder bindStep:sAddPrimary
           atIndex:ixAddPrimary
         advanceOn:[KKJoyrideTrigger laneOptedIn:primary]
         dismissOn:[KKJoyrideTrigger managePopoverClosed]];
  [binder setCloseOnAdvance:KKJoyrideCloseOnAdvanceManagePopover
                    forStep:sAddPrimary];
  [binder bindStep:sToggleIn
           atIndex:ixToggleIn
         advanceOn:[KKJoyrideTrigger phaseToggled:0 on:YES]
         dismissOn:nil];
  [binder
       bindStep:sDiamond
        atIndex:ixDiamondClick
      advanceOn:[[KKJoyrideTrigger diamondTapped:kDiamondTarget]
                    thenWaitFor:[KKJoyrideTrigger staticValuesPopoverWillOpen]]
      dismissOn:nil];
  [binder bindStep:sEdit
           atIndex:ixEdit
         advanceOn:nil
         dismissOn:[KKJoyrideTrigger staticValuesPopoverClosed]];
  [binder bindStep:sGap
           atIndex:ixGapClick
         advanceOn:[[KKJoyrideTrigger gapTapped:kBasicSectionIn]
                       thenWaitFor:[KKJoyrideTrigger gapPopoverWillOpen]]
         dismissOn:nil];
  [binder bindStep:sSpring
           atIndex:ixSpringPick
         advanceOn:[KKJoyrideTrigger gapPopoverCurveChanged:kSpringCurveType]
         dismissOn:nil];
  [binder setCloseOnAdvance:KKJoyrideCloseOnAdvanceContentPopover
                    forStep:sSpring];

  // Watch-back: the user's play tap (forwarded through the binder) schedules
  // a single auto-pause + advance after a beat. The plugin owns nothing here
  // beyond forwarding taps via -notifyPlaybackToggleTapped.
  binder.playToggleTapped = ^{
    __strong KKJoyrideController *g = weakGuide;
    if (!g || g.currentStepIndex != ixWatchBack || watchBackScheduled)
      return;
    watchBackScheduled = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,
                                 (int64_t)(kWatchBackSeconds * NSEC_PER_SEC)),
                   dispatch_get_main_queue(), ^{
                     __strong KKJoyrideController *g2 = weakGuide;
                     if (!g2 || g2.currentStepIndex != ixWatchBack)
                       return;
                     if (config.togglePlayback)
                       config.togglePlayback();
                     if (config.setPlayingAccent)
                       config.setPlayingAccent(NO);
                     [g2 advance];
                   });
  };

  return @[
    sIntro, sOpenConstants, sEditConstant, sAdd, sAddPrimary, sPhases,
    sToggleIn, sGraphNotice, sDiamond, sEdit, sGap, sSpring, sDrag, sWatchBack,
    sDone
  ];
}

+ (NSArray<KKJoyrideStep *> *)
    advancedStepsForGuide:(KKJoyrideController *)guide
                   binder:(KKJoyrideLanesBinder *)binder
                   config:(KKTimingGuideConfig *)config {
  KKTimelineLanesView *lanes = config.lanesView;
  __weak KKTimelineLanesView *weakLanes = lanes;
  __weak KKTimelineAdvancedView *weakAdv = lanes.advancedGraph;
  __weak KKJoyrideLanesBinder *weakBinder = binder;
  NSString *primary = config.primaryLabel;
  // Cmd-click the secondary lane when present (so the user adds to a fresh
  // property), else the primary lane.
  NSString *addLabel = config.secondaryLabel ?: config.primaryLabel;

  const NSInteger ixSwitch = 0, ixIntro = 1, ixCmdClick = 2, ixPopover = 3,
                  ixDrag = 4, ixDone = 5;
  (void)ixSwitch;
  (void)ixIntro;
  (void)ixDone;

  KKJoyrideStep *sSwitch = [KKJoyrideStep
      stepWithMessage:KKLoc(@"Tap <accent>Advanced</accent> for the "
                            @"per-property timeline.",
                            @"Advanced timing guide: open the Advanced editor.")
           targetView:nil];
  sSwitch.targetScreenRect = ^NSRect {
    return config.tabSegmentScreenRect ? config.tabSegmentScreenRect(1)
                                       : NSZeroRect;
  };

  KKJoyrideStep *sIntro = [KKJoyrideStep
      stepWithMessage:KKLoc(
                          @"Each row is a property. Drop "
                          @"<accent>keyposes</accent> anywhere and shape each "
                          @"interval independently.",
                          @"Advanced timing guide: per-property lanes.")
           targetView:^NSView * {
             return weakAdv;
           }];
  sIntro.showsNext = YES;

  const double kAddFrac = 0.5;
  KKJoyrideStep *sCmdClick = [KKJoyrideStep
      stepWithMessage:KKLoc(@"<kbd>⌘ click</kbd> the lane to add a "
                            @"<accent>keypose</accent>.",
                            @"Advanced timing guide: add a keypose to a lane.")
           targetView:nil];
  sCmdClick.spotlightCircular = NO;
  sCmdClick.targetScreenRect = ^NSRect {
    __strong KKTimelineAdvancedView *a = weakAdv;
    return a ? [a guideLaneRowScreenRectForLabel:addLabel] : NSZeroRect;
  };
  sCmdClick.pillToScreenRect = ^NSRect {
    __strong KKTimelineAdvancedView *a = weakAdv;
    return a ? [a guideKeyposeScreenRectForLabel:addLabel atFraction:kAddFrac]
             : NSZeroRect;
  };

  KKJoyrideStep *sPopover = [KKJoyrideStep
      stepWithMessage:KKLoc(@"Edit <accent>values</accent> at this point in "
                            @"time.",
                            @"Advanced timing guide: edit keypose values.")
           targetView:nil];
  sPopover.targetScreenRect = ^NSRect {
    __strong NSView *content = weakBinder.latestStaticValuesPopoverContent;
    NSWindow *w = content.window;
    if (!content || !w)
      return NSZeroRect;
    return [w convertRectToScreen:[content convertRect:content.bounds
                                                toView:nil]];
  };
  sPopover.showsNext = YES;

  const NSInteger kDragKPIdx = 1;      // the end keypose (t=1)
  const double kDragTargetFrac = 0.55; // glow target time
  const double kDragSnapFrac = 0.06;   // release tolerance
  NSRect (^sDragSpot)(void) = ^NSRect {
    __strong KKTimelineAdvancedView *a = weakAdv;
    return a ? [a guideKeyposeScreenRectForLabel:primary atIndex:kDragKPIdx]
             : NSZeroRect;
  };
  NSRect (^sDragTarget)(void) = ^NSRect {
    __strong KKTimelineAdvancedView *a = weakAdv;
    return a ? [a guideKeyposeScreenRectForLabel:primary
                                      atFraction:kDragTargetFrac]
             : NSZeroRect;
  };
  KKJoyrideStep *sDrag = [KKJoyrideDragStep stepForGuide:guide
      atIndex:ixDrag
      isLast:NO
      clickMessage:KKLoc(@"Drag a <accent>keypose</accent> toward the "
                         @"<warn>target</warn> to retime it.",
                         @"Advanced timing guide: drag a keypose to retime.")
      dragMessage:nil
      circular:YES
      spotRect:sDragSpot
      targetRect:sDragTarget
      begin:^(NSPoint p) {
        __strong KKTimelineAdvancedView *a = weakAdv;
        [a guideBeginPillDragForLabel:primary
                              atIndex:kDragKPIdx
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
        double now = [a guideKeyposeFractionForLabel:primary
                                             atIndex:kDragKPIdx];
        if (isnan(now))
          return NO;
        return fabs(now - kDragTargetFrac) <= kDragSnapFrac;
      }];
  sDrag.onEnter = ^{
    [weakLanes guideCloseContentPopover];
  };

  KKJoyrideStep *sDone = [KKJoyrideStep
      stepWithMessage:KKLoc(@"That's <accent>Advanced</accent> timing: add "
                            @"keyposes anywhere and shape each one "
                            @"independently.",
                            @"Advanced timing guide: closing step.")
           targetView:^NSView * {
             return weakAdv;
           }];

  [binder bindStep:sCmdClick
           atIndex:ixCmdClick
         advanceOn:[KKJoyrideTrigger staticValuesPopoverWillOpen]
         dismissOn:nil];
  [binder bindStep:sPopover atIndex:ixPopover advanceOn:nil dismissOn:nil];

  return @[ sSwitch, sIntro, sCmdClick, sPopover, sDrag, sDone ];
}

@end

@implementation KKTimingGuideConfig
@end
