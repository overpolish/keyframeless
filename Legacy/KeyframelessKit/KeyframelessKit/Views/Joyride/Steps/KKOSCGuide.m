/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKOSCGuide.h"

#import "KKLocalized.h"
#import <KeyframelessKit/KKJoyrideController.h>
#import <KeyframelessKit/KKJoyrideOSCSegment.h>
#import <KeyframelessKit/KKJoyrideTrigger.h>
#import <KeyframelessKit/KKMiniViewerView.h>
#import <KeyframelessKit/KKOSCGuideBridge.h>
#import <KeyframelessKit/KKOSCGuideStrategy.h>
#import <KeyframelessKit/KKTimelineAdvancedView.h>
#import <KeyframelessKit/KKTimelineInspectorView+Guide.h>
#import <KeyframelessKit/KKTimelineLanesView+Guide.h>
#import <KeyframelessKit/KKTimelineLanesView.h>
#import <KeyframelessKit/KKTimingGuide.h>
#import <objc/runtime.h>

// Pins the drag segment alive for the run (in a class method `_cmd` is the
// selector, so a dedicated key avoids a clash).
static const char kKKOSCGuideSegmentKey = 0;

static NSRect KKOSCGuideCanvasScreenRect(KKMiniViewerView *c) {
  NSWindow *w = c.window;
  if (!c || !w)
    return NSZeroRect;
  return [w convertRectToScreen:[c convertRect:c.bounds toView:nil]];
}

@implementation KKOSCGuide

+ (NSArray<KKJoyrideStep *> *)stepsForGuide:(KKJoyrideController *)guide
                                     binder:(KKJoyrideLanesBinder *)binder
                                     config:(KKTimingGuideConfig *)config {
  __weak KKJoyrideController *weakGuide = guide;
  __weak KKJoyrideLanesBinder *weakBinder = binder;
  KKTimelineInspectorView *insp = config.inspectorView;
  __weak KKTimelineInspectorView *weakInsp = insp;
  __weak KKTimelineLanesView *weakLanes = config.lanesView;
  __weak KKTimelineAdvancedView *weakAdv = config.lanesView.advancedGraph;
  NSString *featured = config.oscKeepLabels.firstObject ?: config.primaryLabel;
  NSString *primary = config.primaryLabel;
  // Display name for the copy (the featured element is usually the primary
  // lane; fall back to its identity when no display name is set).
  NSString *featuredDisplay = [featured isEqualToString:config.primaryLabel] &&
                                      config.primaryDisplayLabel
                                  ? config.primaryDisplayLabel
                                  : featured;

  KKOSCGuideBridge *bridge =
      config.oscGuideBridge ? config.oscGuideBridge() : nil;
  KKOSCGuideStrategy *strategy =
      config.oscGuideStrategy ? config.oscGuideStrategy() : nil;
  // Let the segment nudge a viewer redraw when the hover emphasis changes (FCP
  // won't re-run drawOSC on its own while the guide panel is frontmost).
  if (strategy && !strategy.requestRedraw && config.requestPreviewRender) {
    void (^previewRender)(void) = config.requestPreviewRender;
    strategy.requestRedraw = ^{
      previewRender();
    };
  }
  BOOL interactive = (bridge != nil && strategy != nil);

  NSRect (^viewerRect)(void) = ^NSRect {
    return config.viewerScreenRect ? config.viewerScreenRect() : NSZeroRect;
  };
  NSRect (^canvasRect)(void) = ^NSRect {
    return KKOSCGuideCanvasScreenRect(weakBinder.latestMiniViewer);
  };
  // Present the mini-viewer's real hover cursor (its angle/move cursor, or the
  // eye/eye.slash under Option) through the pass-through overlay during the
  // opt-hide / re-show steps - its own tracking can't fire while the panel
  // captures the mouse. Off the handle this returns the arrow.
  void (^applyMiniCursor)(NSPoint) = ^(NSPoint p) {
    NSCursor *c = [weakBinder.latestMiniViewer cursorAtScreenPoint:p];
    [(c ?: [NSCursor arrowCursor]) set];
  };

  // drag(2 or 1) + gear, pill, open, opt-hide, peek, reshow, checkbox, re-open,
  // peek-off, where-note
  NSInteger dragVisualCount = interactive ? 2 : 1;
  NSInteger total = dragVisualCount + 10;

  NSMutableArray<KKJoyrideStep *> *steps = [NSMutableArray array];

  // Step 0: edit the control directly in the viewer (interactive
  // drag-to-target, or a narrated pass-through fallback when no OSC strategy is
  // supplied).
  if (interactive) {
    strategy.clickMessage = [NSString
        stringWithFormat:KKLoc(
                             @"Drag <accent>%@</accent> in the viewer to "
                             @"the <warn>glowing target</warn>.",
                             @"OSC guide: drag the handle to the target. %@ = "
                             @"property name."),
                         featuredDisplay];
    strategy.dragMessage =
        KKLoc(@"Keep dragging toward the <warn>glowing target</warn>.",
              @"OSC guide: drag-to-target hint.");
    KKJoyrideOSCSegment *segment =
        [[KKJoyrideOSCSegment alloc] initWithBridge:bridge strategy:strategy];
    objc_setAssociatedObject(guide, &kKKOSCGuideSegmentKey, segment,
                             OBJC_ASSOCIATION_RETAIN_NONATOMIC);
    void (^warmUp)(void) = ^{
      bridge.guideStep = 1;
      if (strategy.currentValue && strategy.setLiveValue)
        strategy.setLiveValue(strategy.currentValue());
      if (config.requestPreviewRender)
        config.requestPreviewRender();
    };
    NSArray<KKJoyrideStep *> *segSteps = [segment stepsForGuide:guide
                                                    displayBase:0
                                                   displayTotal:total
                                               firstStepOnEnter:warmUp];
    if (segSteps.count)
      [steps addObject:segSteps.firstObject];
  } else {
    KKJoyrideStep *sIntro = [KKJoyrideStep
        stepWithMessage:[NSString
                            stringWithFormat:
                                KKLoc(@"Drag <accent>%@</accent> in the viewer "
                                      @"to edit it directly.",
                                      @"OSC guide: edit via the viewer handle. "
                                      @"%@ = property name."),
                                featuredDisplay]
             targetView:nil];
    sIntro.targetScreenRect = viewerRect;
    sIntro.spotlightCircular = NO;
    sIntro.spotlightPassThrough = YES;
    sIntro.showsNext = YES;
    sIntro.displayStepNumber = 1;
    sIntro.displayTotalSteps = total;
    [steps addObject:sIntro];
  }

  KKJoyrideStep * (^numbered)(KKJoyrideStep *) = ^(KKJoyrideStep *s) {
    s.displayStepNumber = (NSInteger)steps.count + dragVisualCount;
    s.displayTotalSteps = total;
    [steps addObject:s];
    return s;
  };

  // --- reusable mini-viewer step builders (the gestures repeat across steps)
  // --

  // The XPC overlay swallows raw clicks/moves, so every mini-viewer gesture is
  // driven from the spotlight handlers below (the move equivalent of the click
  // forwarding). Opt-gated click that hides / re-shows the handle under the
  // cursor (firing the miniViewerOptHide trigger); `ensureReveal` first turns
  // reveal on so a hidden ghost is hit-testable.
  void (^optClickDrive)(NSPoint, BOOL) = ^(NSPoint p, BOOL ensureReveal) {
    if (!(NSEvent.modifierFlags & NSEventModifierFlagOption))
      return;
    if (ensureReveal)
      [weakBinder.latestMiniViewer setGuidePeekActive:YES];
    [weakBinder.latestMiniViewer optHideHandleAtScreenPoint:p];
  };

  // Peek step: hold Option (+ move) reveals the controls; advancing on RELEASE
  // lets the user read + see them and turns reveal back off before moving on
  // (else the renderer stays in peek mode and the master toggle can't hide it).
  KKJoyrideStep * (^peekStep)(NSString *) = ^(NSString *msg) {
    KKJoyrideStep *s = [KKJoyrideStep stepWithMessage:msg targetView:nil];
    s.targetScreenRect = canvasRect;
    s.spotlightCircular = NO;
    s.spotlightPassThrough = YES;
    s.showsNext = YES; // fallback if the opt-hover doesn't register
    NSInteger idx = (NSInteger)steps.count; // the index this step will land at
    __block BOOL revealed = NO;
    s.spotlightMouseMoved = ^(NSPoint p) {
      BOOL opt = (NSEvent.modifierFlags & NSEventModifierFlagOption) != 0;
      [weakBinder.latestMiniViewer setGuidePeekActive:opt];
      if (opt) {
        revealed = YES;
      } else if (revealed) {
        revealed = NO;
        __strong KKJoyrideController *g = weakGuide;
        if (g && g.currentStepIndex == idx)
          [g advance];
      }
    };
    return s;
  };

  // Open-keypose step: spotlight the featured keypose; the caller binds it to
  // advance on the boundary popover opening.
  KKJoyrideStep * (^openKeyposeStep)(NSString *, void (^)(void)) =
      ^(NSString *msg, void (^onEnter)(void)) {
        KKJoyrideStep *s = [KKJoyrideStep stepWithMessage:msg targetView:nil];
        s.onEnter = onEnter;
        s.targetScreenRect = ^NSRect {
          __strong KKTimelineAdvancedView *a = weakAdv;
          return a ? [a guideKeyposeScreenRectForLabel:primary atIndex:0]
                   : NSZeroRect;
        };
        return s;
      };

  // Step: open the OSC settings gear (inspector).
  KKJoyrideStep *sSettings = [KKJoyrideStep
      stepWithMessage:KKLoc(@"Open <accent>settings</accent> to hide controls "
                            @"one at a time.",
                            @"OSC guide: open the OSC settings gear.")
           targetView:nil];
  sSettings.targetScreenRect = ^NSRect {
    __strong KKTimelineInspectorView *v = weakInsp;
    return v ? [v guideOSCSettingsButtonScreenRect] : NSZeroRect;
  };
  numbered(sSettings);
  NSInteger ixSettings = (NSInteger)steps.count - 1;

  // Step: toggle one element's pill off (inspector popover). Spotlight ONLY the
  // safe (non-featured) control's pill so the user can't disable the featured
  // one the mini-viewer needs (clicks outside the spotlight aren't forwarded).
  NSString *disableLabel = config.oscDisableLabel;
  KKJoyrideStep *sPill = [KKJoyrideStep
      stepWithMessage:KKLoc(@"Switch a control <warn>off</warn> to hide just "
                            @"that one.",
                            @"OSC guide: toggle a per-element pill off.")
           targetView:nil];
  sPill.spotlightCircular = NO;
  sPill.targetScreenRect = ^NSRect {
    __strong KKTimelineInspectorView *v = weakInsp;
    if (!v)
      return NSZeroRect;
    return disableLabel
               ? [v guideOSCSettingsPillScreenRectForLabel:disableLabel]
               : [v guideOSCSettingsPillBarScreenRect];
  };
  numbered(sPill);
  NSInteger ixPill = (NSInteger)steps.count - 1;

  // Step: open a keypose's mini viewer (the in-process OSC surface where real
  // mouse events - opt-click + opt-move peek - actually reach the controls; the
  // FCP viewer only reacts to its own hitTest, so the opt gestures can't live
  // there). Close the settings popover first.
  KKJoyrideStep *sOpen = openKeyposeStep(
      KKLoc(
          @"The controls are on the <accent>mini viewer</accent> too. Click a "
          @"keypose to open it.",
          @"OSC guide: open a keypose mini viewer."),
      ^{
        [weakInsp guideCloseOSCSettingsPopover];
      });
  NSInteger ixOpen = (NSInteger)steps.count;
  numbered(sOpen);

  // Step: opt-click a handle in the mini viewer to hide it (master still on).
  KKJoyrideStep *sOptHide = [KKJoyrideStep
      stepWithMessage:KKLoc(
                          @"Hold <kbd>⌥</kbd> and click a control to hide it.",
                          @"OSC guide: opt-click a mini-viewer handle to hide.")
           targetView:nil];
  // Spotlight the handle itself (not the whole canvas) so it's clear what to
  // click; fall back to the canvas if the handle isn't located yet.
  sOptHide.targetScreenRect = ^NSRect {
    NSRect h = [weakBinder.latestMiniViewer pointHandleScreenRect];
    return NSIsEmptyRect(h) ? canvasRect() : h;
  };
  sOptHide.spotlightCircular = YES;
  sOptHide.spotlightPassThrough = YES;
  // Drive opt-reveal on hover (the renderer's own opt-tracking can't fire while
  // the panel captures the mouse) so the eye.slash hide affordance + cursor
  // show over the still-visible handle, then present that cursor.
  sOptHide.spotlightMouseMoved = ^(NSPoint screenPt) {
    [weakBinder.latestMiniViewer
        setGuidePeekActive:(NSEvent.modifierFlags &
                            NSEventModifierFlagOption) != 0];
    applyMiniCursor(screenPt);
  };
  sOptHide.spotlightMouseExited = ^(NSPoint screenPt) {
    applyMiniCursor(screenPt);
  };
  sOptHide.spotlightMouseDown = ^(NSPoint screenPt) {
    optClickDrive(screenPt, NO);
  };
  NSInteger ixOptHide = (NSInteger)steps.count;
  numbered(sOptHide);

  // Step: opt-peek in the mini viewer. Master is still on and one control is
  // hidden (from the step above), so holding Option + moving reveals that
  // hidden control as a ghost.
  numbered(peekStep(
      KKLoc(@"Hold <kbd>⌥</kbd> and move to reveal the control you hid. "
            @"<warn>Release ⌥</warn> to continue.",
            @"OSC guide: opt-peek a hidden control.")));

  // Step: opt-click the revealed ghost to bring the hidden control back.
  // Holding Option reveals it (move monitor -> setGuidePeekActive), and the
  // opt-click toggles it visible again (optHide... toggles either way). Fires
  // the miniViewerOptHide trigger -> advance.
  KKJoyrideStep *sReshow = [KKJoyrideStep
      stepWithMessage:KKLoc(
                          @"Hold <kbd>⌥</kbd> and click the dimmed control to "
                          @"bring it back.",
                          @"OSC guide: opt-click a ghost to re-show it.")
           targetView:nil];
  sReshow.targetScreenRect = canvasRect;
  sReshow.spotlightCircular = NO;
  sReshow.spotlightPassThrough = YES;
  sReshow.spotlightMouseMoved = ^(NSPoint screenPt) {
    // Keep the ghost revealed so it's clickable.
    [weakBinder.latestMiniViewer
        setGuidePeekActive:(NSEvent.modifierFlags &
                            NSEventModifierFlagOption) != 0];
    applyMiniCursor(screenPt); // eye (show) over the revealed ghost
  };
  sReshow.spotlightMouseExited = ^(NSPoint screenPt) {
    applyMiniCursor(screenPt);
  };
  // ensureReveal: the hidden handle is only hit-testable while reveal is on, so
  // turn it on before the toggle (the click may land without a preceding move).
  sReshow.spotlightMouseDown = ^(NSPoint screenPt) {
    optClickDrive(screenPt, YES);
  };
  NSInteger ixReshow = (NSInteger)steps.count;
  numbered(sReshow);

  // Step: master checkbox off - hide them all (inspector). Close the keypose
  // popover on enter so it can't cover the checkbox (hard-lock).
  KKJoyrideStep *sHideAll = [KKJoyrideStep
      stepWithMessage:KKLoc(@"Turn the <accent>checkbox</accent> off to hide "
                            @"them all.",
                            @"OSC guide: master toggle off.")
           targetView:nil];
  sHideAll.onEnter = ^{
    // Clear any lingering peek reveal (the reshow step may have advanced with
    // Option still held), else the renderer stays in peek mode and the master
    // toggle can't hide it.
    [weakBinder.latestMiniViewer setGuidePeekActive:NO];
    [weakLanes guideCloseContentPopover];
  };
  sHideAll.targetScreenRect = ^NSRect {
    __strong KKTimelineInspectorView *v = weakInsp;
    return v ? [v guideOSCCheckboxScreenRect] : NSZeroRect;
  };
  numbered(sHideAll);
  NSInteger ixHideAll = (NSInteger)steps.count - 1;

  // Step: re-open the keypose mini viewer for the disabled-peek demo (the
  // checkbox step closed it).
  KKJoyrideStep *sOpen2 =
      openKeyposeStep(KKLoc(@"Open the keypose again.",
                            @"OSC guide: re-open the keypose mini viewer."),
                      nil);
  NSInteger ixOpen2 = (NSInteger)steps.count;
  numbered(sOpen2);

  // Step: opt-peek with the master OFF - the distinct "peek and use" mode. All
  // controls are hidden, so holding Option reveals every enabled one AND lets
  // you use it transiently (vs the master-on peek above, which only re-shows
  // the one you hid).
  numbered(peekStep(
      KKLoc(@"With them all off, hold <kbd>⌥</kbd> and move to reveal them, "
            @"still usable. <warn>Release ⌥</warn> to continue.",
            @"OSC guide: opt-peek when OSCs are off.")));

  // Final step: where the viewer controls show. Re-show the OSCs and park the
  // playhead on the keypose on enter so the viewer actually displays them while
  // the note is read; close the popover.
  KKJoyrideStep *sWhere = [KKJoyrideStep
      stepWithMessage:KKLoc(
                          @"On-screen controls show in the viewer only where "
                          @"the property is <accent>constant</accent> or on a "
                          @"<accent>keypose</accent>.",
                          @"OSC guide: closing note on viewer OSC visibility.")
           targetView:nil];
  sWhere.onEnter = ^{
    [weakLanes guideCloseContentPopover];
    __strong KKTimelineInspectorView *v = weakInsp;
    void (^reshow)(BOOL) = v.onOSCVisibleToggled;
    if (reshow)
      reshow(YES); // master back on so the viewer draws the controls
    if (config.scrubToFraction)
      config.scrubToFraction(0.0); // park on the keypose (drag left one at 0)
  };
  sWhere.targetScreenRect = viewerRect;
  sWhere.spotlightCircular = NO;
  sWhere.showsNext = YES;
  numbered(sWhere);

  // Advance the inspector steps on the real user action.
  weakInsp.onGuideOSCSettingsPopoverWillOpen = ^(NSView *content) {
    __strong KKJoyrideController *g = weakGuide;
    if (!g || g.currentStepIndex != ixSettings)
      return;
    g.additionalPassthroughWindow = content.window;
    [g advance];
  };
  weakInsp.onGuideOSCElementToggled = ^(NSString *label, BOOL visible) {
    __strong KKJoyrideController *g = weakGuide;
    if (!g || g.currentStepIndex != ixPill)
      return;
    // Only advance on the safe control (its compound master or a child of it),
    // so a stray toggle of another pill doesn't skip ahead.
    if (disableLabel && ![label isEqualToString:disableLabel] &&
        ![label hasPrefix:[disableLabel stringByAppendingString:@"."]])
      return;
    [g advance];
  };
  weakInsp.onGuideOSCMasterToggled = ^(BOOL visible) {
    __strong KKJoyrideController *g = weakGuide;
    if (g && g.currentStepIndex == ixHideAll && !visible)
      [g advance];
  };

  // Advance the mini-viewer steps on the canvas's own events (via the binder).
  [binder bindStep:sOpen
           atIndex:ixOpen
         advanceOn:[KKJoyrideTrigger staticValuesPopoverWillOpen]
         dismissOn:nil];
  [binder bindStep:sOptHide
           atIndex:ixOptHide
         advanceOn:[KKJoyrideTrigger miniViewerOptHide]
         dismissOn:nil];
  // sPeek / sPeekOff advance from their own move handler (on Option release),
  // not a trigger, so the reveal is read + turned off first.
  [binder bindStep:sReshow
           atIndex:ixReshow
         advanceOn:[KKJoyrideTrigger miniViewerOptHide]
         dismissOn:nil];
  [binder bindStep:sOpen2
           atIndex:ixOpen2
         advanceOn:[KKJoyrideTrigger staticValuesPopoverWillOpen]
         dismissOn:nil];

  return steps;
}

@end
