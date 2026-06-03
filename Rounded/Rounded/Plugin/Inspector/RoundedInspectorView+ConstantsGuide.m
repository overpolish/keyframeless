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

@implementation RoundedInspectorView (ConstantsGuide)

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

@end
