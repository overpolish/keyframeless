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

@implementation RoundedInspectorView (BasicTimingGuide)

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

@end
