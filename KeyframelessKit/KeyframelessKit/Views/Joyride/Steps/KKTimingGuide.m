/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimingGuide.h"

#import "KKEasing.h"
#import "KKLocalized.h"
#import "KKTimelineInspectorView+Presets.h"
#import <KeyframelessKit/KKHelpSection.h>
#import <KeyframelessKit/KKJoyrideController.h>
#import <KeyframelessKit/KKJoyrideDragStep.h>
#import <KeyframelessKit/KKJoyrideLanesBinder.h>
#import <KeyframelessKit/KKJoyrideTrigger.h>
#import <KeyframelessKit/KKMiniViewerView.h>
#import <KeyframelessKit/KKSegmentEditView+Guide.h>
#import <KeyframelessKit/KKTimelineAdvancedView.h>
#import <KeyframelessKit/KKTimelineBasicView+Guide.h>
#import <KeyframelessKit/KKTimelineBasicView.h>
#import <KeyframelessKit/KKTimelineInspectorView+Guide.h>
#import <KeyframelessKit/KKTimelineLanesView+Guide.h>
#import <KeyframelessKit/KKTimelineLanesView.h>
#import <KeyframelessKit/KKTimingStage.h>

NSString *const KKTimingIntroGuideIdentifier = @"timing.intro";

// The Elastic curve (Linear=0, EaseIn=1, EaseOut=2, EaseInOut=3, Elastic=4,
// Bounce=5). Its user-facing name comes from KKEasingCurveDisplayName.
static const NSInteger kElasticCurveType = 4;
// KKBasicSectionIn - the In phase gap section in the Basic graph.
static const NSInteger kBasicSectionIn = 1;
// Chronologically the second diamond once In is on (the hold-start / In-end
// keypose the user just watched appear).
static const NSInteger kDiamondTarget = 2;
// Watch-back: play this long before auto-pausing + advancing.
static const double kWatchBackSeconds = 1.0;
// Drag the In-end diamond toward 1.0s; snap windows for magnet + release.
static const double kDragTargetSeconds = 1.0;
// Release-acceptance half-window (seconds) around the target. This step has NO
// cursor magnet (the adaptive/log-warped Basic timeline fights snapping), so
// the diamond never clicks into place - keep the window generous (+/-0.2s) so
// landing near 1.0s advances, instead of stranding the user on a boundary that
// "looks right" but is just outside a tight tolerance.
static const double kDragSnapSeconds = 0.2;
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
  intro.identifier =
      KKTimingIntroGuideIdentifier; // stable across localized titles

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

  __block __weak KKHelpGuide *weakMiniViewer = nil;
  KKHelpGuide *miniViewer = [KKHelpGuide
      guideWithTitle:KKLoc(@"Mini Viewer",
                           @"Help guide title: mini-viewer walkthrough.")
            subtitle:KKLoc(@"Preview keyposes, with filmstrip and onion-skin",
                           @"Help guide subtitle: Mini Viewer.")
             onStart:^{
               KKTimelineInspectorView *iv =
                   inspectorProvider ? inspectorProvider() : nil;
               if (!iv)
                 return;
               KKHelpGuide *live = weakMiniViewer;
               iv.onGuideCompleted = ^{
                 [live markCompleted];
               };
               [iv restartMiniViewerGuide];
             }];
  weakMiniViewer = miniViewer;
  miniViewer.identifier = @"miniviewer";

  __block __weak KKHelpGuide *weakOSC = nil;
  KKHelpGuide *osc = [KKHelpGuide
      guideWithTitle:KKLoc(@"On-Screen Controls",
                           @"Help guide title: on-screen-control walkthrough.")
            subtitle:KKLoc(@"Hide, reveal, and peek the viewer controls",
                           @"Help guide subtitle: On-Screen Controls.")
             onStart:^{
               KKTimelineInspectorView *iv =
                   inspectorProvider ? inspectorProvider() : nil;
               if (!iv)
                 return;
               KKHelpGuide *live = weakOSC;
               iv.onGuideCompleted = ^{
                 [live markCompleted];
               };
               [iv restartOSCGuide];
             }];
  weakOSC = osc;
  osc.identifier = @"osc";

  __block __weak KKHelpGuide *weakPresets = nil;
  KKHelpGuide *presets = [KKHelpGuide
      guideWithTitle:KKLoc(@"Presets",
                           @"Help guide title: presets walkthrough.")
            subtitle:KKLoc(@"Apply, insert, and save animations",
                           @"Help guide subtitle: Presets.")
             onStart:^{
               KKTimelineInspectorView *iv =
                   inspectorProvider ? inspectorProvider() : nil;
               if (!iv)
                 return;
               KKHelpGuide *live = weakPresets;
               iv.onGuideCompleted = ^{
                 [live markCompleted];
               };
               [iv runPresetsGuide];
             }];
  weakPresets = presets;
  presets.identifier = @"presets";

  // The guides cut out the FCP viewer / boundary popover, which only resolve
  // once the OSC bridge has a draw tick - so they gate on the same canvas
  // reference the plugin supplies.
  NSString *disabled =
      KKLoc(@"Guides are disabled. Click the effect's header on a clip to "
            @"select it (it highlights yellow), then move your mouse over the "
            @"viewer to enable them.",
            @"Help guide disabled subtitle (no OSC canvas reference yet).");
  for (KKHelpGuide *g in @[ intro, advanced, miniViewer, osc, presets ]) {
    g.enabledProvider = enabledProvider;
    g.disabledSubtitle = disabled;
  }
  return @[ intro, advanced, miniViewer, osc, presets ];
}

+ (KKTimeline *)basicSeedTimelineForConfig:(KKTimingGuideConfig *)config {
  KKTimeline *tl = [KKTimeline timeline];
  KKLane *primary = [KKLane laneWithLabel:config.primaryLabel];
  primary.enabled = NO; // constant until the user opts it in to animation
  primary.valueType = (KKLaneValueType)config.primaryValueType;
  // Mirror the real lane's aspect-link so OSC drags during the guide follow the
  // same path the plugin uses (e.g. Glow's radius ring: uniform when linked).
  primary.aspectLinkable = config.primaryAspectLinked;
  primary.aspectLinked = config.primaryAspectLinked;
  primary.keyposes = @[ [KKKeyPose keyposeAtTime:0.0
                                          values:config.primarySeedValues] ];
  tl.lanes = @[ primary ];
  return tl;
}

+ (KKLane *)_seedLaneWithLabel:(NSString *)label
                     valueType:(NSInteger)valueType
                  aspectLinked:(BOOL)aspectLinked
                   startValues:(NSArray<NSNumber *> *)startValues
                     endValues:(NSArray<NSNumber *> *)endValues {
  KKLane *lane = [KKLane laneWithLabel:label];
  lane.enabled = YES; // animatable
  lane.valueType = (KKLaneValueType)valueType;
  lane.aspectLinkable = aspectLinked;
  lane.aspectLinked = aspectLinked;
  lane.keyposes = @[
    [KKKeyPose keyposeAtTime:0.0 values:startValues],
    [KKKeyPose keyposeAtTime:1.0 values:endValues],
  ];
  return lane;
}

+ (KKTimeline *)advancedSeedTimelineForConfig:(KKTimingGuideConfig *)config {
  KKTimeline *tl = [KKTimeline timeline];
  // Seed a real transition (start -> target) rather than a flat hold, so the
  // demo timeline shows motion the user can retime - and so the Dynamic step
  // has an actual transition to space out. Falls back to a flat hold if no
  // target is configured.
  NSArray<NSNumber *> *primaryEnd = config.primaryTargetValues.count
                                        ? config.primaryTargetValues
                                        : config.primarySeedValues;
  KKLane *primary = [self _seedLaneWithLabel:config.primaryLabel
                                   valueType:config.primaryValueType
                                aspectLinked:config.primaryAspectLinked
                                 startValues:config.primarySeedValues
                                   endValues:primaryEnd];
  primary.categoryKey = config.primaryCategoryKey;
  NSMutableArray<KKLane *> *lanes = [NSMutableArray array];
  if (config.secondaryLabel) {
    KKLane *secondary = [self _seedLaneWithLabel:config.secondaryLabel
                                       valueType:config.secondaryValueType
                                    aspectLinked:NO
                                     startValues:config.secondarySeedValues
                                       endValues:config.secondarySeedValues];
    secondary.categoryKey = config.secondaryCategoryKey;
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
  // Identity (`primary`) drives lookups + the seed lane; the display name is
  // what the user reads (they differ when the lane is keyed by an internal id,
  // e.g. Shader's GLSL uniform @"uCenter" shown as "Center").
  NSString *primaryDisplay = config.primaryDisplayLabel ?: primary;

  const NSInteger ixIntro = 0, ixOpenConstants = 1, ixEditConstant = 2,
                  ixAdd = 3, ixAddPrimary = 4, ixPhases = 5, ixToggleIn = 6,
                  ixGraphNotice = 7, ixDiamondClick = 8, ixEdit = 9,
                  ixGapClick = 10, ixElasticPick = 11, ixDragBoundary = 12,
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
    __strong KKMiniViewerView *c = weakBinder.latestMiniViewer;
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
                           primaryDisplay]
      dragMessage:KKLoc(@"Drag toward the <warn>glowing target</warn>.",
                        @"Timing guide: drag-to-target hint.")
      circular:YES
      spotRect:^NSRect {
        __strong KKMiniViewerView *c = weakBinder.latestMiniViewer;
        return c ? [c pointHandleScreenRect] : NSZeroRect;
      }
      targetRect:editTargetRect
      begin:^(NSPoint p) {
        // Press at the handle's exact centre, not the captured click: the
        // arc ring is large, so an off-centre press would carry a grab offset
        // through the delta-based drag and land the handle off the target.
        __strong KKMiniViewerView *c = weakBinder.latestMiniViewer;
        NSRect spot = [c pointHandleScreenRect];
        [c beginPointHandleDragAtScreenPoint:NSIsEmptyRect(spot)
                                                 ? p
                                                 : NSMakePoint(NSMidX(spot),
                                                               NSMidY(spot))];
      }
      dragTo:^(NSPoint p) {
        [weakBinder.latestMiniViewer
            dragPointHandleToScreenPoint:KKJoyrideSnapToTarget(
                                             p, editTargetRect(), 9.0)];
      }
      end:^{
        [weakBinder.latestMiniViewer endPointHandleDrag];
      }
      hitOnRelease:^BOOL(NSPoint p) {
        NSRect t = editTargetRect();
        double dpx =
            NSIsEmptyRect(t) ? 1e9 : hypot(p.x - NSMidX(t), p.y - NSMidY(t));
        return dpx <= 14.0;
      }];
  // Present the mini-viewer's real hover cursor through the pass-through
  // overlay (its own tracking can't fire while the panel captures the mouse).
  KKJoyrideStepAttachCursor(sEditConstant, ^NSCursor *(NSPoint pt) {
    return [weakBinder.latestMiniViewer cursorAtScreenPoint:pt];
  });

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
                                     primaryDisplay]
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
    __strong KKMiniViewerView *c = weakBinder.latestMiniViewer;
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
        __strong KKMiniViewerView *c = weakBinder.latestMiniViewer;
        return c ? [c pointHandleScreenRect] : NSZeroRect;
      }
      targetRect:kpTargetRect
      begin:^(NSPoint p) {
        // Press at the handle's exact centre, not the captured click: the
        // arc ring is large, so an off-centre press would carry a grab offset
        // through the delta-based drag and land the handle off the target.
        __strong KKMiniViewerView *c = weakBinder.latestMiniViewer;
        NSRect spot = [c pointHandleScreenRect];
        [c beginPointHandleDragAtScreenPoint:NSIsEmptyRect(spot)
                                                 ? p
                                                 : NSMakePoint(NSMidX(spot),
                                                               NSMidY(spot))];
      }
      dragTo:^(NSPoint p) {
        [weakBinder.latestMiniViewer
            dragPointHandleToScreenPoint:KKJoyrideSnapToTarget(
                                             p, kpTargetRect(), 9.0)];
      }
      end:^{
        [weakBinder.latestMiniViewer endPointHandleDrag];
      }
      hitOnRelease:^BOOL(NSPoint p) {
        NSRect t = kpTargetRect();
        double dpx =
            NSIsEmptyRect(t) ? 1e9 : hypot(p.x - NSMidX(t), p.y - NSMidY(t));
        return dpx <= 14.0;
      }];
  KKJoyrideStepAttachCursor(sEdit, ^NSCursor *(NSPoint pt) {
    return [weakBinder.latestMiniViewer cursorAtScreenPoint:pt];
  });

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

  KKJoyrideStep *sElastic = [KKJoyrideStep
      stepWithMessage:
          [NSString
              stringWithFormat:KKLoc(@"Pick <accent>%@</accent> for a lively "
                                     @"overshoot.",
                                     @"Timing guide: choose the Elastic easing "
                                     @"curve. %@ is the localized curve name."),
                               KKEasingCurveDisplayName(KKEasingCurveElastic)]
           targetView:nil];
  sElastic.targetScreenRect = ^NSRect {
    __strong KKSegmentEditView *e = weakBinder.latestGapSegmentEditor;
    return e ? [e guideCurvePillScreenRectForCurve:kElasticCurveType]
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

  // Introduction-only closing step: point the user at the Help button, where
  // the other interactive guides + docs live. Appended only when the plugin
  // supplies a help-button rect (config.helpButtonScreenRect); when present it
  // becomes the final step, so sDone advances into it with a "Next".
  KKJoyrideStep *sHelp = nil;
  if (config.helpButtonScreenRect) {
    sDone.showsNext = YES;
    sHelp = [KKJoyrideStep
        stepWithMessage:
            KKLoc(@"More interactive guides and docs live in <symbol "
                  @"questionmark.circle color=accent /> Help - open it "
                  @"anytime.",
                  @"Timing guide: closing step pointing at the Help "
                  @"button.")
             targetView:nil];
    sHelp.spotlightCircular = YES;
    sHelp.targetScreenRect = ^NSRect {
      return config.helpButtonScreenRect ? config.helpButtonScreenRect()
                                         : NSZeroRect;
    };
  }

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
  [binder bindStep:sElastic
           atIndex:ixElasticPick
         advanceOn:[KKJoyrideTrigger gapPopoverCurveChanged:kElasticCurveType]
         dismissOn:nil];
  [binder setCloseOnAdvance:KKJoyrideCloseOnAdvanceContentPopover
                    forStep:sElastic];

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

  NSMutableArray<KKJoyrideStep *> *steps = [@[
    sIntro, sOpenConstants, sEditConstant, sAdd, sAddPrimary, sPhases,
    sToggleIn, sGraphNotice, sDiamond, sEdit, sGap, sElastic, sDrag, sWatchBack,
    sDone
  ] mutableCopy];
  if (sHelp)
    [steps addObject:sHelp];
  return steps;
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

  // The lane-filter step is only meaningful (and only has a visible filter bar
  // to spotlight) when the seed has two lanes, so include it only then. It sits
  // after the lane-editing steps, so a user hiding a lane there can't strand an
  // earlier step that targets a specific lane row. Its presence shifts the
  // Dynamic/Overview/Done indices by one.
  const BOOL includeFilter = config.secondaryLabel != nil;
  const NSInteger ixSwitch = 0, ixIntro = 1, ixCmdClick = 2, ixPopover = 3,
                  ixDrag = 4, ixMarquee = 5, ixGroupDrag = 6;
  // The filter is two steps (open the button, then toggle a row in the
  // popover), present only with a second lane; they shift Dynamic + the rest
  // down by two.
  const NSInteger ixFilterOpen = includeFilter ? 7 : -1;
  const NSInteger ixFilterToggle = includeFilter ? 8 : -1;
  const NSInteger ixDynamic = includeFilter ? 9 : 7;
  (void)ixSwitch;
  (void)ixIntro;

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

  // Marquee: sweep a box across the lanes to multi-select keyposes. The press
  // lands anywhere in a big start zone left of the moved keyposes (frac
  // 0.06 - 0.46, full row height); the box is pinned to span every row
  // vertically, so the user only drags right to the end target (frac 1.0). That
  // encloses the keyposes in the right of the timeline but not the t=0 start
  // poses. The end target stays HIDDEN until the press (dragMessage != nil), so
  // its amber glow can't pull the press to the wrong (right) end of the track.
  const double kMarqueeZoneStartFrac = 0.06;
  const double kMarqueeZoneEndFrac = 0.46;
  const double kMarqueeEndFrac = 1.0;
  NSRect (^marqueeSpot)(void) = ^NSRect {
    __strong KKTimelineAdvancedView *a = weakAdv;
    return a ? [a guideTracksRegionScreenRectFromFraction:kMarqueeZoneStartFrac
                                               toFraction:kMarqueeZoneEndFrac]
             : NSZeroRect;
  };
  NSRect (^marqueeTarget)(void) = ^NSRect {
    __strong KKTimelineAdvancedView *a = weakAdv;
    return a ? [a guideMarqueeTargetScreenRectAtFraction:kMarqueeEndFrac]
             : NSZeroRect;
  };
  KKJoyrideStep *sMarquee = [KKJoyrideDragStep stepForGuide:guide
      atIndex:ixMarquee
      isLast:NO
      clickMessage:
          KKLoc(@"Start a drag in the <accent>highlighted region</accent>"
                @" and move right to box-select several keyposes.",
                @"Advanced timing guide: start a marquee selection.")
      dragMessage:KKLoc(
                      @"Keep dragging right, past the keyposes, then release.",
                      @"Advanced timing guide: finish the marquee drag.")
      circular:NO
      spotRect:marqueeSpot
      targetRect:marqueeTarget
      begin:^(NSPoint p) {
        [weakAdv guideBeginMarqueeAtScreenPoint:p];
      }
      dragTo:^(NSPoint p) {
        [weakAdv
            guideDragMarqueeToScreenPoint:KKJoyrideSnapToTarget(
                                              p, marqueeTarget(), kDragSnapPx)];
      }
      end:^{
        [weakAdv guideEndMarquee];
      }
      hitOnRelease:^BOOL(NSPoint p) {
        __strong KKTimelineAdvancedView *a = weakAdv;
        return a.selectionCount >= 2;
      }];

  // Group retime: drag the whole selection. We grab the selected primary
  // keypose nearest the moved (~0.55) pose the marquee enclosed - resolved by
  // value, not a hardcoded index, so reordering the seed / earlier steps can't
  // silently make this press the wrong keypose. The index is latched at press
  // (`groupKPIdx`) so it stays stable while the keypose travels during the
  // drag.
  const double kGroupGrabFrac = 0.55;
  const double kGroupTargetFrac = 0.35;
  const double kGroupSnapFrac = 0.06;
  __block NSInteger groupKPIdx = NSNotFound;
  NSInteger (^groupKP)(void) = ^NSInteger {
    if (groupKPIdx != NSNotFound)
      return groupKPIdx;
    __strong KKTimelineAdvancedView *a = weakAdv;
    return a ? [a guideSelectedKeyposeIndexNearestFraction:kGroupGrabFrac
                                                  forLabel:primary]
             : NSNotFound;
  };
  NSRect (^groupSpot)(void) = ^NSRect {
    __strong KKTimelineAdvancedView *a = weakAdv;
    NSInteger idx = groupKP();
    return (a && idx != NSNotFound)
               ? [a guideKeyposeScreenRectForLabel:primary atIndex:idx]
               : NSZeroRect;
  };
  NSRect (^groupTarget)(void) = ^NSRect {
    __strong KKTimelineAdvancedView *a = weakAdv;
    return a ? [a guideKeyposeScreenRectForLabel:primary
                                      atFraction:kGroupTargetFrac]
             : NSZeroRect;
  };
  KKJoyrideStep *sGroupDrag = [KKJoyrideDragStep stepForGuide:guide
      atIndex:ixGroupDrag
      isLast:NO
      clickMessage:KKLoc(
                       @"Drag any <accent>selected</accent> keypose - they all "
                       @"retime together.",
                       @"Advanced timing guide: drag the multi-selection to "
                       @"retime.")
      dragMessage:nil
      circular:YES
      spotRect:groupSpot
      targetRect:groupTarget
      begin:^(NSPoint p) {
        groupKPIdx = groupKP(); // latch for the duration of this drag
        if (groupKPIdx == NSNotFound)
          return;
        NSRect spot = groupSpot();
        NSPoint press =
            NSIsEmptyRect(spot) ? p : NSMakePoint(NSMidX(spot), NSMidY(spot));
        [weakAdv guideBeginSelectionDragForLabel:primary
                                         atIndex:groupKPIdx
                                   atScreenPoint:press];
      }
      dragTo:^(NSPoint p) {
        [weakAdv
            guideDragSelectionToScreenPoint:KKJoyrideSnapToTarget(
                                                p, groupTarget(), kDragSnapPx)];
      }
      end:^{
        [weakAdv guideEndSelectionDrag];
        // Keep groupKPIdx latched: hitOnRelease runs after end(), and a retry
        // should re-grab the same keypose (it has since moved off
        // kGroupGrabFrac).
      }
      hitOnRelease:^BOOL(NSPoint p) {
        __strong KKTimelineAdvancedView *a = weakAdv;
        if (groupKPIdx == NSNotFound)
          return NO;
        double now = [a guideKeyposeFractionForLabel:primary
                                             atIndex:groupKPIdx];
        if (isnan(now))
          return NO;
        return fabs(now - kGroupTargetFrac) <= kGroupSnapFrac;
      }];

  KKJoyrideStep *sFilterOpen = [KKJoyrideStep
      stepWithMessage:KKLoc(@"Open the <accent>filter</accent> to show or hide "
                            @"properties on the timeline.",
                            @"Advanced timing guide: open the lane-visibility "
                            @"filter.")
           targetView:nil];
  sFilterOpen.spotlightCircular = YES;
  sFilterOpen.targetScreenRect = ^NSRect {
    __strong KKTimelineLanesView *l = weakLanes;
    return l ? [l guideLaneFilterBarScreenRect] : NSZeroRect;
  };

  KKJoyrideStep *sFilterToggle = [KKJoyrideStep
      stepWithMessage:KKLoc(@"Uncheck a <accent>property</accent> to hide its "
                            @"lane and focus the timeline.",
                            @"Advanced timing guide: toggle a property in the "
                            @"filter checklist.")
           targetView:nil];
  sFilterToggle.spotlightCircular = NO;
  sFilterToggle.targetScreenRect = ^NSRect {
    __strong NSView *content = weakBinder.latestFilterPopoverContent;
    NSWindow *w = content.window;
    if (!content || !w)
      return NSZeroRect;
    return [w convertRectToScreen:[content convertRect:content.bounds
                                                toView:nil]];
  };

  KKJoyrideStep *sDynamic = [KKJoyrideStep
      stepWithMessage:KKLoc(@"Tap <accent>Dynamic</accent> to space out short "
                            @"transitions so they stay easy to grab on a long "
                            @"clip.",
                            @"Advanced timing guide: try the Dynamic display "
                            @"toggle.")
           targetView:nil];
  sDynamic.spotlightCircular = YES;
  sDynamic.targetScreenRect = ^NSRect {
    __strong KKTimelineLanesView *l = weakLanes;
    return l ? [l guideDynamicButtonScreenRect] : NSZeroRect;
  };

  KKJoyrideStep *sOverview = [KKJoyrideStep
      stepWithMessage:KKLoc(@"Now you can see and edit every transition "
                            @"<accent>without zooming in</accent>.",
                            @"Advanced timing guide: Dynamic value (no zooming "
                            @"to reach each transition).")
           targetView:^NSView * {
             return weakAdv;
           }];
  sOverview.showsNext = YES;

  KKJoyrideStep *sMaintain = [KKJoyrideStep
      stepWithMessage:KKLoc(
                          @"<accent>Maintain Timing</accent> locks the "
                          @"animation to absolute time - trimming or splitting "
                          @"the clip then retimes the keyposes to hold their "
                          @"position.",
                          @"Advanced timing guide: the Maintain Timing lock "
                          @"toggle.")
           targetView:nil];
  sMaintain.spotlightCircular = YES;
  sMaintain.showsNext = YES;
  sMaintain.targetScreenRect = ^NSRect {
    KKTimelineInspectorView *insp = config.inspectorView;
    return insp ? [insp guideMaintainTimingButtonScreenRect] : NSZeroRect;
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
  // The filter is a button that opens a checklist popover: advance the first
  // step when the popover opens, then make the popover interactive
  // (passthrough) and advance the second when the user toggles a row -
  // mirroring the Animated dropdown's open-then-toggle pair. Close the popover
  // on advance.
  if (includeFilter) {
    [binder bindStep:sFilterOpen
             atIndex:ixFilterOpen
           advanceOn:[KKJoyrideTrigger filterPopoverWillOpen]
           dismissOn:nil];
    [binder bindStep:sFilterToggle
             atIndex:ixFilterToggle
           advanceOn:[KKJoyrideTrigger laneFilterToggled]
           dismissOn:[KKJoyrideTrigger filterPopoverClosed]];
    [binder setCloseOnAdvance:KKJoyrideCloseOnAdvanceFilterPopover
                      forStep:sFilterToggle];
  }
  [binder bindStep:sDynamic
           atIndex:ixDynamic
         advanceOn:[KKJoyrideTrigger dynamicToggled]
         dismissOn:nil];

  NSMutableArray<KKJoyrideStep *> *steps =
      [@[ sSwitch, sIntro, sCmdClick, sPopover, sDrag, sMarquee, sGroupDrag ]
          mutableCopy];
  if (includeFilter)
    [steps addObjectsFromArray:@[ sFilterOpen, sFilterToggle ]];
  [steps addObjectsFromArray:@[ sDynamic, sOverview, sMaintain, sDone ]];
  return steps;
}

@end

@implementation KKTimingGuideConfig
@end
