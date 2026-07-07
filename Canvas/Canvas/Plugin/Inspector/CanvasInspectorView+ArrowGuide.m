/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The "Animating an Arrow" end-to-end walkthrough, split out of
// CanvasInspectorView.m to keep the inspector file focused. Runs entirely in the
// Constants popover + Basic graph, mirroring the Basic timing guide's structure.

#import "CanvasInspectorView+ArrowGuide.h"

#import "CanvasInspectorView.h"
#import "CanvasLocalized.h" // CLoc (guide step messages)
#import "CanvasOSCGuide.h"  // CanvasSharedOSCGuideBridge (viewer rect)
#import "CanvasToolbar.h"   // CanvasToolbarToolPen
#import <KeyframelessKit/KKJoyrideController.h>
#import <KeyframelessKit/KKJoyrideDragStep.h>
#import <KeyframelessKit/KKJoyrideGuideHost.h>
#import <KeyframelessKit/KKJoyrideLanesBinder.h>
#import <KeyframelessKit/KKJoyrideTrigger.h>
#import <KeyframelessKit/KKMiniViewerView.h>
#import <KeyframelessKit/KKTimelineBasicView+Guide.h>
#import <KeyframelessKit/KKTimelineInspectorView+Guide.h>
#import <KeyframelessKit/KKTimelineLanesView+Guide.h>

// "Animating an Arrow" guide step indices (see -_arrowGuideStepsForGuide:binder:).
// Only steps that check their own index or bind at it are named; the three draw
// steps (indices 2-4) advance imperatively from the pen point count, so the gap
// 1 -> 5 is intentional.
static const NSInteger kArrowGuideStepOpenConstants = 0; // open Constants panel
static const NSInteger kArrowGuideStepPen = 1;     // switch to the Pen tool
static const NSInteger kArrowGuideStepStrokeGroup = 5; // open the Stroke category
static const NSInteger kArrowGuideStepMarker = 6;    // set End Marker -> Arrow
static const NSInteger kArrowGuideStepAnimate = 7;   // Draw On End -> Animated
static const NSInteger kArrowGuideStepIn = 8;        // turn the In phase on
static const NSInteger kArrowGuideStepKeypose = 9;   // click KP1 (T=0 keypose)
static const NSInteger kArrowGuideStepSlider = 10;   // drag its value to 0
static const NSInteger kArrowGuideStepPlayback = 11; // play it back

// KP1 is the In-phase start keypose at T=0 - diamond index 1 in the Basic graph
// (see -guideDiamondScreenRectForIndex:, pillFrac 0.0).
static const NSInteger kArrowKeyposeDiamondIndex = 1;
// Auto-pause + advance the watch-back this long after the play tap.
static const double kArrowWatchBackSeconds = 1.5;

// The lane whose animation draws the line on (End 0 -> 100). Moved to Animated
// via its per-lane "add to animated" gutter button, in the Stroke category.
static NSString *const kArrowDrawOnLaneLabel = @"Draw On End";

// The "End Marker" constant lane is a choice pill; "Arrow" is choice index 1
// (None, Arrow, Circle, Square, Arrowhead, Line - see Plugin+LaneDefinitions).
// The lane lives in the "Stroke" category tab of the constants popover.
static NSString *const kArrowMarkerLaneLabel = @"End Marker";
static NSString *const kArrowStrokeCategoryKey = @"Stroke";
static const NSInteger kArrowMarkerArrowChoiceIndex = 1;

// Canvas content-rect fractions for the two-point line the user draws (a roughly
// horizontal stroke, left -> right, so the end marker reads as a forward arrow).
static const CGFloat kArrowDrawStartFx = 0.32, kArrowDrawStartFy = 0.5;
static const CGFloat kArrowDrawEndFx = 0.68, kArrowDrawEndFy = 0.5;

// A small circular spotlight rect centred on a screen point (NSZeroRect when the
// point is unset, so the draw steps degrade gracefully before the canvas maps).
static NSRect KKGuideSpotRectAround(NSPoint p) {
  if (NSEqualPoints(p, NSZeroPoint))
    return NSZeroRect;
  const CGFloat r = 16.0; // spotlight radius, screen points
  return NSMakeRect(p.x - r, p.y - r, r * 2, r * 2);
}

@implementation CanvasInspectorView (ArrowGuide)

// The arrow workflow runs entirely in the Constants (static-values) popover -
// Canvas's main editing surface - mirroring the Basic timing guide's structure
// (open Constants, draw in the mini, style, move to animated, keypose, playback).
// The steps are grouped into per-phase sub-builders below.
- (NSArray<KKJoyrideStep *> *)
    _arrowGuideStepsForGuide:(KKJoyrideController *)guide
                      binder:(KKJoyrideLanesBinder *)binder {
  NSMutableArray<KKJoyrideStep *> *steps = [NSMutableArray array];
  [steps addObjectsFromArray:[self _arrowSetupStepsForGuide:guide binder:binder]];
  [steps addObjectsFromArray:[self _arrowDrawStepsForGuide:guide binder:binder]];
  [steps addObjectsFromArray:[self _arrowStyleStepsForGuide:guide binder:binder]];
  [steps
      addObjectsFromArray:[self _arrowTimingStepsForGuide:guide binder:binder]];
  return steps;
}

// Steps 0-1: open the Constants popover, then pick the Pen tool in its mini.
- (NSArray<KKJoyrideStep *> *)_arrowSetupStepsForGuide:(KKJoyrideController *)guide
                                               binder:
                                                   (KKJoyrideLanesBinder *)binder {
  __weak typeof(self) weak = self;
  __weak KKJoyrideLanesBinder *weakBinder = binder;

  KKJoyrideStep *sOpenConstants = [KKJoyrideStep
      stepWithMessage:CLoc(@"Open the <accent>Constants</accent> panel - it's "
                           @"where you draw and shape a layer.",
                           @"Arrow guide: open the Constants panel.")
           targetView:^NSView * {
             __strong typeof(weak) s = weak;
             return s.constantsButton;
           }];
  [binder bindStep:sOpenConstants
           atIndex:kArrowGuideStepOpenConstants
         advanceOn:[KKJoyrideTrigger staticValuesPopoverWillOpen]
         dismissOn:nil];

  // Select the Pen tool in the popover mini-viewer's toolbar. The XPC overlay
  // swallows raw mini clicks, so the press is synthesized from the spotlight
  // (like the OSC guide's mini steps); the tool change round-trips through
  // kParamUIState and advances via -setToolbarTool: (-_arrowGuideAdvanceIf...).
  KKJoyrideStep *sPen = [KKJoyrideStep
      stepWithMessage:CLoc(@"Pick the <accent>Pen</accent> tool to start "
                           @"drawing your shape.",
                           @"Arrow guide: select the Pen tool in the mini.")
           targetView:nil];
  sPen.spotlightCircular = YES;
  sPen.spotlightPassThrough = YES;
  sPen.targetScreenRect = ^NSRect {
    return [weakBinder.latestMiniViewer
        guideToolbarButtonScreenRectForTag:CanvasToolbarToolPen];
  };
  sPen.spotlightMouseDown = ^(NSPoint screenPt) {
    [weakBinder.latestMiniViewer guidePressToolbarAtScreenPoint:screenPt];
  };
  sPen.spotlightMouseMoved = ^(NSPoint screenPt) {
    [[NSCursor arrowCursor] set]; // toolbar buttons use the arrow cursor
  };

  return @[ sOpenConstants, sPen ];
}

// Present the pen's real hover cursor (place / close glyph) through the
// pass-through overlay - the mini's own tracking can't fire while the spotlight
// captures the mouse - and feed the hover point so the rubber-band preview
// follows (mirrors the OSC peek guide's applyMiniCursor / move drive).
- (void (^)(NSPoint))_arrowPenHoverForBinder:(KKJoyrideLanesBinder *)binder {
  __weak KKJoyrideLanesBinder *weakBinder = binder;
  return ^(NSPoint screenPt) {
    KKMiniViewerView *mini = weakBinder.latestMiniViewer;
    [mini guideToolMoveToScreenPoint:screenPt];
    [([mini cursorAtScreenPoint:screenPt] ?: [NSCursor arrowCursor]) set];
  };
}

// One pen-click step at a canvas-content fraction: a glowing target (pill
// coincident with the spotlight) whose synthesized click-through advances once
// the pen has placed `count` points.
- (KKJoyrideStep *)_arrowDrawStepForGuide:(KKJoyrideController *)guide
                                   binder:(KKJoyrideLanesBinder *)binder
                                fractionX:(CGFloat)fx
                                        y:(CGFloat)fy
                                  message:(NSString *)message
                           advanceAtCount:(NSInteger)count
                                 penHover:(void (^)(NSPoint))penHover {
  __weak KKJoyrideController *weakGuide = guide;
  __weak KKJoyrideLanesBinder *weakBinder = binder;
  KKJoyrideStep *step = [KKJoyrideStep stepWithMessage:message targetView:nil];
  step.spotlightCircular = YES;
  step.spotlightPassThrough = YES;
  NSRect (^rect)(void) = ^NSRect {
    return KKGuideSpotRectAround([weakBinder.latestMiniViewer
        guideScreenPointForContentFractionX:fx
                                          y:fy]);
  };
  step.targetScreenRect = rect;
  step.pillToScreenRect = rect;
  step.spotlightMouseMoved = penHover;
  step.spotlightMouseDown = ^(NSPoint screenPt) {
    KKMiniViewerView *mini = weakBinder.latestMiniViewer;
    [mini guideToolClickAtScreenPoint:
              [mini guideScreenPointForContentFractionX:fx y:fy]];
    if ([mini guidePenPointCount] >= count)
      [weakGuide advance];
  };
  return step;
}

// Steps 2-4: the three pen clicks in the mini - start, end, then the last
// anchor again to finish the OPEN path (clicking the FIRST anchor would close
// it; clicking the LAST ends it as-is, within the pen's close radius).
- (NSArray<KKJoyrideStep *> *)_arrowDrawStepsForGuide:(KKJoyrideController *)guide
                                              binder:
                                                  (KKJoyrideLanesBinder *)binder {
  __weak KKJoyrideController *weakGuide = guide;
  __weak KKJoyrideLanesBinder *weakBinder = binder;
  void (^penHover)(NSPoint) = [self _arrowPenHoverForBinder:binder];

  KKJoyrideStep *sDrawStart = [self
      _arrowDrawStepForGuide:guide
                      binder:binder
                   fractionX:kArrowDrawStartFx
                           y:kArrowDrawStartFy
                     message:CLoc(@"Click the <warn>glowing point</warn> to "
                                  @"start your line.",
                                  @"Arrow guide: click to place the first point.")
              advanceAtCount:1
                    penHover:penHover];

  KKJoyrideStep *sDrawEnd = [self
      _arrowDrawStepForGuide:guide
                      binder:binder
                   fractionX:kArrowDrawEndFx
                           y:kArrowDrawEndFy
                     message:CLoc(@"Click the <warn>second point</warn> to draw "
                                  @"the line.",
                                  @"Arrow guide: click to place the end point.")
              advanceAtCount:2
                    penHover:penHover];

  KKJoyrideStep *sDrawDone = [KKJoyrideStep
      stepWithMessage:CLoc(@"Click the <warn>last point</warn> once more to "
                           @"finish the line.",
                           @"Arrow guide: click the last anchor to finish.")
           targetView:nil];
  sDrawDone.spotlightCircular = YES;
  sDrawDone.spotlightPassThrough = YES;
  NSRect (^drawDoneRect)(void) = ^NSRect {
    return KKGuideSpotRectAround(
        [weakBinder.latestMiniViewer guideLastPenPointScreen]);
  };
  sDrawDone.targetScreenRect = drawDoneRect;
  sDrawDone.pillToScreenRect = drawDoneRect;
  sDrawDone.spotlightMouseMoved = penHover;
  sDrawDone.spotlightMouseDown = ^(NSPoint screenPt) {
    KKMiniViewerView *mini = weakBinder.latestMiniViewer;
    [mini guideToolClickAtScreenPoint:[mini guideLastPenPointScreen]];
    if ([mini guidePenPointCount] == 0) // path finished (pen went idle)
      [weakGuide advance];
  };

  return @[ sDrawStart, sDrawEnd, sDrawDone ];
}

// Steps 5-7: open the Stroke group, set End Marker = Arrow, animate Draw On End.
- (NSArray<KKJoyrideStep *> *)_arrowStyleStepsForGuide:(KKJoyrideController *)guide
                                               binder:
                                                   (KKJoyrideLanesBinder *)binder {
  __weak typeof(self) weak = self;

  // Switch to the Stroke category tab (where the marker lanes live). The
  // category nav pill is an in-process control (the popover window is already a
  // passthrough), so the real click lands; advance on the category trigger.
  KKJoyrideStep *sStrokeGroup = [KKJoyrideStep
      stepWithMessage:CLoc(@"Open the <accent>Stroke</accent> group to shape "
                           @"the line's ends.",
                           @"Arrow guide: open the Stroke category tab.")
           targetView:nil];
  sStrokeGroup.spotlightCircular = YES;
  // Force the popover to Core on entry (the drawn path now guarantees a Core
  // category), so switching to Stroke is a real, teachable transition whatever
  // tab the popover happened to open on.
  sStrokeGroup.onEnter = ^{
    __strong typeof(weak) s = weak;
    [s.basicLanesView guideSelectConstantCategory:@"Core"];
  };
  sStrokeGroup.targetScreenRect = ^NSRect {
    __strong typeof(weak) s = weak;
    return s ? [s.basicLanesView
                   guideConstantCategoryPillScreenRectForKey:kArrowStrokeCategoryKey]
             : NSZeroRect;
  };
  [binder bindStep:sStrokeGroup
           atIndex:kArrowGuideStepStrokeGroup
         advanceOn:[KKJoyrideTrigger
                       staticCategorySelectedForKey:kArrowStrokeCategoryKey]
         dismissOn:nil];

  // Set the End Marker to Arrow. The End Marker constant lane is a choice pill
  // in the popover (an in-process control - the binder already registers the
  // popover window as passthrough, so the real click lands); scroll it into
  // view on enter, spotlight the Arrow segment, advance on the choice trigger.
  KKJoyrideStep *sMarker = [KKJoyrideStep
      stepWithMessage:CLoc(@"Set the <accent>End Marker</accent> to "
                           @"<warn>Arrow</warn> to tip your line.",
                           @"Arrow guide: pick the Arrow end marker.")
           targetView:nil];
  sMarker.spotlightCircular = NO;
  sMarker.onEnter = ^{
    __strong typeof(weak) s = weak;
    [s.basicLanesView
        guideScrollConstantRowIntoViewForLabel:kArrowMarkerLaneLabel];
  };
  sMarker.targetScreenRect = ^NSRect {
    __strong typeof(weak) s = weak;
    return s ? [s.basicLanesView
                   guideConstantChoicePillScreenRectForLabel:kArrowMarkerLaneLabel
                                                     atIndex:kArrowMarkerArrowChoiceIndex]
             : NSZeroRect;
  };
  [binder bindStep:sMarker
           atIndex:kArrowGuideStepMarker
         advanceOn:[KKJoyrideTrigger
                       staticChoiceSelectedForLabel:kArrowMarkerLaneLabel
                                              index:kArrowMarkerArrowChoiceIndex]
         dismissOn:nil];

  // Move Draw On End to Animated via its per-lane gutter button (the shortcut
  // next to the lane, vs the manage dropdown). Scroll it into view on enter,
  // spotlight the button, advance when the lane opts into animation, then close
  // the Constants popover - the timing steps that follow are on the Basic graph.
  KKJoyrideStep *sAnimate = [KKJoyrideStep
      stepWithMessage:CLoc(@"Click the <accent>curve</accent> button to animate "
                           @"<warn>Draw On End</warn> - that's what draws the "
                           @"line on.",
                           @"Arrow guide: add Draw On End to animated.")
           targetView:nil];
  sAnimate.spotlightCircular = YES;
  sAnimate.onEnter = ^{
    __strong typeof(weak) s = weak;
    [s.basicLanesView
        guideScrollConstantRowIntoViewForLabel:kArrowDrawOnLaneLabel];
  };
  sAnimate.targetScreenRect = ^NSRect {
    __strong typeof(weak) s = weak;
    return s ? [s.basicLanesView
                   guideConstantAddToAnimatedButtonScreenRectForLabel:
                       kArrowDrawOnLaneLabel]
             : NSZeroRect;
  };
  [binder bindStep:sAnimate
           atIndex:kArrowGuideStepAnimate
         advanceOn:[KKJoyrideTrigger laneOptedIn:kArrowDrawOnLaneLabel]
         dismissOn:nil];
  [binder setCloseOnAdvance:KKJoyrideCloseOnAdvanceContentPopover
                    forStep:sAnimate];

  return @[ sStrokeGroup, sMarker, sAnimate ];
}

// The slider-to-0 step (drag Draw On End's keypose value down to 0 so the line
// starts undrawn). A synthesized slider drag like the Basic guide's keypose
// edit: the begin/dragTo/end blocks drive the popover slider, committing on
// release; it advances on its own release hit and dismisses if the popover
// closes.
- (KKJoyrideStep *)_arrowSliderStepForGuide:(KKJoyrideController *)guide
                                     binder:(KKJoyrideLanesBinder *)binder {
  __weak typeof(self) weak = self;
  NSString *drawOn = kArrowDrawOnLaneLabel;
  NSRect (^sliderTargetRect)(void) = ^NSRect {
    __strong typeof(weak) s = weak;
    if (!s)
      return NSZeroRect;
    NSRect track =
        [s.basicLanesView guideConstantSliderTrackScreenRectForLabel:drawOn];
    if (NSIsEmptyRect(track))
      return NSZeroRect;
    CGFloat x = [s.basicLanesView guideConstantSliderScreenXForValue:0.0
                                                            forLabel:drawOn];
    return NSMakeRect(x - 8.0, NSMidY(track) - 8.0, 16.0, 16.0);
  };
  KKJoyrideStep *sSlider = [KKJoyrideDragStep stepForGuide:guide
      atIndex:kArrowGuideStepSlider
      isLast:NO
      clickMessage:CLoc(@"Drag <warn>Draw On End</warn> down to <warn>0</warn> "
                        @"so the line starts undrawn.",
                        @"Arrow guide: drag the start value to 0.")
      dragMessage:CLoc(@"Keep dragging to <warn>0</warn>.",
                       @"Arrow guide: drag-to-zero hint.")
      circular:YES
      spotRect:^NSRect {
        __strong typeof(weak) s = weak;
        return s ? [s.basicLanesView
                       guideConstantSliderKnobScreenRectForLabel:drawOn]
                 : NSZeroRect;
      }
      targetRect:sliderTargetRect
      begin:^(NSPoint p) {
        __strong typeof(weak) s = weak;
        [s.basicLanesView beginGuideConstantDrag];
      }
      dragTo:^(NSPoint p) {
        __strong typeof(weak) s = weak;
        if (!s)
          return;
        NSPoint sp = KKJoyrideSnapToTarget(p, sliderTargetRect(), 9.0);
        double v = [s.basicLanesView guideConstantSliderValueForScreenX:sp.x
                                                               forLabel:drawOn];
        [s.basicLanesView applyGuideConstantValues:@[ @(v) ] forLabel:drawOn];
      }
      end:^{
        __strong typeof(weak) s = weak;
        [s.basicLanesView endGuideConstantDrag];
      }
      hitOnRelease:^BOOL(NSPoint p) {
        NSRect t = sliderTargetRect();
        double dpx =
            NSIsEmptyRect(t) ? 1e9 : hypot(p.x - NSMidX(t), p.y - NSMidY(t));
        return dpx <= 16.0;
      }];
  [binder bindStep:sSlider
           atIndex:kArrowGuideStepSlider
         advanceOn:nil
         dismissOn:[KKJoyrideTrigger staticValuesPopoverClosed]];
  return sSlider;
}

// The watch-back step + its auto-pause machine. The user's play tap (forwarded
// via the binder) schedules a single auto-pause + advance after a beat - the
// same machine as the Basic guide.
- (KKJoyrideStep *)_arrowPlaybackStepForGuide:(KKJoyrideController *)guide
                                       binder:(KKJoyrideLanesBinder *)binder {
  __weak typeof(self) weak = self;
  __weak KKJoyrideController *weakGuide = guide;
  KKJoyrideStep *sPlayback = [KKJoyrideStep
      stepWithMessage:CLoc(@"Watch it back: press "
                           @"<symbol play.fill color=accent />.",
                           @"Arrow guide: play the animation back.")
           targetView:nil];
  sPlayback.spotlightCircular = NO;
  sPlayback.targetScreenRect = ^NSRect {
    __strong typeof(weak) s = weak;
    NSRect play = s ? [s guidePlayButtonScreenRect] : NSZeroRect;
    NSRect viewer = CanvasSharedOSCGuideBridge().estimatedViewerScreenRect;
    if (NSIsEmptyRect(viewer))
      return play;
    if (NSIsEmptyRect(play))
      return viewer;
    return NSUnionRect(play, viewer);
  };
  sPlayback.onEnter = ^{
    __strong typeof(weak) s = weak;
    // Close the keypose popover left open by the slider step, reset to the start.
    [s.basicLanesView guideCloseContentPopover];
    if (s.onScrub)
      s.onScrub(0.0);
    if (s.onBoundaryPreviewNeedsRender)
      s.onBoundaryPreviewNeedsRender();
  };
  __block BOOL watchBackScheduled = NO;
  binder.playToggleTapped = ^{
    __strong KKJoyrideController *g = weakGuide;
    if (!g || g.currentStepIndex != kArrowGuideStepPlayback || watchBackScheduled)
      return;
    watchBackScheduled = YES;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(kArrowWatchBackSeconds * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          __strong KKJoyrideController *g2 = weakGuide;
          __strong typeof(weak) s2 = weak;
          if (!g2 || g2.currentStepIndex != kArrowGuideStepPlayback)
            return;
          if (s2.onTogglePlayback)
            s2.onTogglePlayback(); // auto-pause
          [s2 guideSetPlayingAccent:NO];
          [g2 advance];            // last step -> completes the guide
        });
  };
  [binder bindStep:sPlayback
           atIndex:kArrowGuideStepPlayback
         advanceOn:nil
         dismissOn:nil];
  return sPlayback;
}

// Steps 8-12: turn In on, click KP1, drag its value to 0, watch back, closer.
- (NSArray<KKJoyrideStep *> *)_arrowTimingStepsForGuide:(KKJoyrideController *)guide
                                                binder:
                                                    (KKJoyrideLanesBinder *)binder {
  __weak typeof(self) weak = self;

  // Turn the In phase on (Basic graph), easing Draw On End from its start value
  // - the same phase toggle the Basic timing guide teaches.
  KKJoyrideStep *sIn = [KKJoyrideStep
      stepWithMessage:CLoc(@"Turn <accent>In</accent> on so the line eases on "
                           @"from the start.",
                           @"Arrow guide: enable the In transition.")
           targetView:nil];
  sIn.targetScreenRect = ^NSRect {
    __strong typeof(weak) s = weak;
    return s ? [s.basicLanesView.basicGraph guidePhaseToggleScreenRectForPhase:0]
             : NSZeroRect;
  };
  [binder bindStep:sIn
           atIndex:kArrowGuideStepIn
         advanceOn:[KKJoyrideTrigger phaseToggled:0 on:YES]
         dismissOn:nil];

  // Click KP1 (the T=0 keypose) to edit where the line begins - opens the
  // keypose popover. Same diamond-then-popover advance as the Basic guide.
  KKJoyrideStep *sKeypose = [KKJoyrideStep
      stepWithMessage:CLoc(@"Click the <accent>first keypose</accent> to set "
                           @"where the line begins.",
                           @"Arrow guide: click the T=0 keypose.")
           targetView:nil];
  sKeypose.targetScreenRect = ^NSRect {
    __strong typeof(weak) s = weak;
    return s ? [s.basicLanesView.basicGraph
                   guideDiamondScreenRectForIndex:kArrowKeyposeDiamondIndex]
             : NSZeroRect;
  };
  [binder bindStep:sKeypose
           atIndex:kArrowGuideStepKeypose
         advanceOn:[[KKJoyrideTrigger diamondTapped:kArrowKeyposeDiamondIndex]
                       thenWaitFor:[KKJoyrideTrigger staticValuesPopoverWillOpen]]
         dismissOn:nil];

  KKJoyrideStep *sSlider = [self _arrowSliderStepForGuide:guide binder:binder];
  KKJoyrideStep *sPlayback = [self _arrowPlaybackStepForGuide:guide
                                                       binder:binder];

  // Closer: after the watch-back advances here, this is the last step, so the
  // overlay shows a "Done" button (no binding needed).
  KKJoyrideStep *sClose = [KKJoyrideStep
      stepWithMessage:CLoc(@"That's it - you drew a line, tipped it with an "
                           @"arrow, and animated it drawing on.",
                           @"Arrow guide: closing step.")
           targetView:^NSView * {
             __strong typeof(weak) s = weak;
             return s.basicLanesView.basicGraph;
           }];

  return @[ sIn, sKeypose, sSlider, sPlayback, sClose ];
}

// Advance the Pen-tool step once the tool becomes Pen (the plugin calls
// -setToolbarTool: on every kParamUIState tool change - the mini toolbar shares
// the same tool key). Wired in a later increment when the Pen step exists.
- (void)_arrowGuideAdvanceIfPenSelected:(NSInteger)tool {
  if (!self.arrowGuideActive || tool != CanvasToolbarToolPen)
    return;
  KKJoyrideController *g = [self timingGuideHost].currentGuide;
  if (g && g.currentStepIndex == kArrowGuideStepPen)
    [g advance];
}

@end
