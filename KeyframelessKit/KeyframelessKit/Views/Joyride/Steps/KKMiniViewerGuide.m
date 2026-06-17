/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMiniViewerGuide.h"

#import "KKLocalized.h"
#import <KeyframelessKit/KKJoyrideController.h>
#import <KeyframelessKit/KKJoyrideLanesBinder.h>
#import <KeyframelessKit/KKJoyrideTrigger.h>
#import <KeyframelessKit/KKMiniViewerGuideScroll.h>
#import <KeyframelessKit/KKMiniViewerView.h>
#import <KeyframelessKit/KKTimelineAdvancedView.h>
#import <KeyframelessKit/KKTimelineLanesView+Guide.h>
#import <KeyframelessKit/KKTimelineLanesView.h>
#import <KeyframelessKit/KKTimingGuide.h>
#import <KeyframelessKit/KKTimingStage.h>

// Spotlight the keypose at this index (a middle one, so the boundary popover
// opens with frames on both sides in the filmstrip).
static const NSInteger kOpenKeyposeIndex = 1;

static NSRect KKMiniViewerCanvasScreenRect(KKMiniViewerView *c) {
  NSWindow *w = c.window;
  if (!c || !w)
    return NSZeroRect;
  return [w convertRectToScreen:[c convertRect:c.bounds toView:nil]];
}

@implementation KKMiniViewerGuide

+ (KKTimeline *)seedTimelineForConfig:(KKTimingGuideConfig *)config {
  KKTimeline *tl = [KKTimeline timeline];
  KKLane *primary = [KKLane laneWithLabel:config.primaryLabel];
  primary.enabled = YES; // animatable, so the Advanced sequencer shows keyposes
  primary.valueType = (KKLaneValueType)config.primaryValueType;
  // Mirror the real lane's aspect-link so OSC drags during the guide follow the
  // same path the plugin uses (e.g. Glow's radius ring: uniform when linked).
  primary.aspectLinkable = config.primaryAspectLinked;
  primary.aspectLinked = config.primaryAspectLinked;
  NSArray<NSArray<NSNumber *> *> *frames = config.miniViewerSeedValues;
  NSMutableArray<KKKeyPose *> *kps = [NSMutableArray array];
  NSUInteger n = frames.count;
  for (NSUInteger i = 0; i < n; i++) {
    double frac = n > 1 ? (double)i / (double)(n - 1) : 0.0;
    [kps addObject:[KKKeyPose keyposeAtTime:frac values:frames[i]]];
  }
  primary.keyposes = kps;
  tl.lanes = @[ primary ];
  return tl;
}

+ (NSArray<KKJoyrideStep *> *)stepsForGuide:(KKJoyrideController *)guide
                                     binder:(KKJoyrideLanesBinder *)binder
                                     config:(KKTimingGuideConfig *)config {
  __weak KKJoyrideController *weakGuide = guide;
  __weak KKJoyrideLanesBinder *weakBinder = binder;
  KKTimelineLanesView *lanes = config.lanesView;
  __weak KKTimelineLanesView *weakLanes = lanes;
  __weak KKTimelineAdvancedView *weakAdv = lanes.advancedGraph;
  NSString *primary = config.primaryLabel;

  const NSInteger ixOpen = 0, ixIntro = 1, ixDrag = 2, ixZoom = 3, ixReset = 4,
                  ixFilmstrip = 5, ixFilmstripZoom = 6, ixNavigate = 7,
                  ixOnion = 8, ixOnionExplain = 9, ixSize = 10, ixDone = 11;
  (void)ixIntro;
  (void)ixOnionExplain;
  (void)ixDone;

  // Large segment of the size pill (sm/md/lg = 0/1/2); the guide resets the
  // size to sm at start, so this step teaches growing it to the largest.
  const NSInteger kSizeLargeIndex = 2;

  NSRect (^canvasRect)(void) = ^NSRect {
    return KKMiniViewerCanvasScreenRect(weakBinder.latestMiniViewer);
  };
  // Most steps spotlight the live mini-viewer rect (non-circular). Pass an
  // already-localized message so KKLoc stays at the call site for extraction.
  KKJoyrideStep * (^canvasStep)(NSString *) = ^(NSString *msg) {
    KKJoyrideStep *s = [KKJoyrideStep stepWithMessage:msg targetView:nil];
    s.targetScreenRect = canvasRect;
    s.spotlightCircular = NO;
    return s;
  };

  // Scroll/pinch don't reach the canvas natively while the guide overlay sits
  // over the popover, so route them through the canvas's public apply* methods
  // for the duration of the run. Rebuilt for each popover open (filmstrip cell
  // navigation re-opens); torn down with the binder when the guide ends.
  __block KKMiniViewerGuideScroll *scroll = nil;
  binder.staticValuesPopoverDidOpen =
      ^(NSView *content, KKMiniViewerView *_Nullable canvas) {
        [scroll teardown];
        if (!canvas)
          return;
        scroll = [[KKMiniViewerGuideScroll alloc]
            initWithCanvas:canvas
                activeWhen:^BOOL {
                  __strong KKJoyrideController *g = weakGuide;
                  return g.isActive;
                }];
        [scroll install];
      };

  KKJoyrideStep *sOpen = [KKJoyrideStep
      stepWithMessage:KKLoc(
                          @"Click a <accent>keypose</accent> to open the mini "
                          @"viewer.",
                          @"Mini-viewer guide: open the boundary popover.")
           targetView:nil];
  sOpen.targetScreenRect = ^NSRect {
    __strong KKTimelineAdvancedView *a = weakAdv;
    return a ? [a guideKeyposeScreenRectForLabel:primary
                                         atIndex:kOpenKeyposeIndex]
             : NSZeroRect;
  };

  KKJoyrideStep *sIntro =
      canvasStep(KKLoc(@"The <accent>mini viewer</accent> previews your "
                       @"clip at this keypose.",
                       @"Mini-viewer guide: what the preview shows."));
  sIntro.showsNext = YES;

  KKJoyrideStep *sDrag =
      canvasStep(KKLoc(@"Drag the preview to <accent>pan</accent> around.",
                       @"Mini-viewer guide: pan the canvas by dragging."));

  KKJoyrideStep *sZoom =
      canvasStep(KKLoc(@"Scroll or pinch to <accent>zoom</accent> in and out.",
                       @"Mini-viewer guide: zoom the canvas."));

  KKJoyrideStep *sReset =
      canvasStep(KKLoc(@"Double-click to <accent>reset</accent> the view.",
                       @"Mini-viewer guide: reset zoom/pan."));

  KKJoyrideStep *sFilmstrip = [KKJoyrideStep
      stepWithMessage:KKLoc(@"Tap <accent>Filmstrip</accent> to lay out every "
                            @"keypose.",
                            @"Mini-viewer guide: switch to filmstrip mode.")
           targetView:nil];
  sFilmstrip.targetScreenRect = ^NSRect {
    __strong KKTimelineLanesView *l = weakLanes;
    return l ? [l guideRenderModePillScreenRectForMode:
                       KKMiniViewerRenderModeFilmstrip]
             : NSZeroRect;
  };

  KKJoyrideStep *sFilmstripZoom =
      canvasStep(KKLoc(@"Zoom out to see the <accent>other keyposes</accent>.",
                       @"Mini-viewer guide: zoom out across the filmstrip."));

  KKJoyrideStep *sNavigate = canvasStep(
      KKLoc(@"Click a frame to <accent>jump</accent> to that keypose.",
            @"Mini-viewer guide: click a filmstrip frame."));

  KKJoyrideStep *sOnion = [KKJoyrideStep
      stepWithMessage:KKLoc(@"Tap <accent>Onion</accent> to stack the frames.",
                            @"Mini-viewer guide: switch to onion-skin mode.")
           targetView:nil];
  sOnion.targetScreenRect = ^NSRect {
    __strong KKTimelineLanesView *l = weakLanes;
    return l ? [l guideRenderModePillScreenRectForMode:
                       KKMiniViewerRenderModeOnion]
             : NSZeroRect;
  };

  KKJoyrideStep *sOnionExplain =
      canvasStep(KKLoc(@"<red>Red</red> frames are before this keypose, "
                       @"<blue>blue</blue> frames after.",
                       @"Mini-viewer guide: onion-skin red/blue meaning."));
  sOnionExplain.showsNext = YES;

  KKJoyrideStep *sSize = [KKJoyrideStep
      stepWithMessage:KKLoc(@"Tap <accent>Large</accent> for a bigger preview.",
                            @"Mini-viewer guide: enlarge the preview.")
           targetView:nil];
  sSize.targetScreenRect = ^NSRect {
    __strong KKTimelineLanesView *l = weakLanes;
    return l ? [l guideSizePillScreenRectForIndex:kSizeLargeIndex] : NSZeroRect;
  };

  KKJoyrideStep *sDone =
      canvasStep(KKLoc(@"Use the <accent>mini viewer</accent> to edit a "
                       @"keypose at its point in time, without scrubbing "
                       @"the timeline there.",
                       @"Mini-viewer guide: closing benefit step."));

  [binder bindStep:sOpen
           atIndex:ixOpen
         advanceOn:[KKJoyrideTrigger staticValuesPopoverWillOpen]
         dismissOn:nil];
  [binder bindStep:sDrag
           atIndex:ixDrag
         advanceOn:[KKJoyrideTrigger miniViewerPanned]
         dismissOn:nil];
  [binder bindStep:sZoom
           atIndex:ixZoom
         advanceOn:[KKJoyrideTrigger miniViewerZoomed]
         dismissOn:nil];
  [binder bindStep:sReset
           atIndex:ixReset
         advanceOn:[KKJoyrideTrigger miniViewerViewReset]
         dismissOn:nil];
  [binder bindStep:sFilmstrip
           atIndex:ixFilmstrip
         advanceOn:[KKJoyrideTrigger
                       renderModeChanged:KKMiniViewerRenderModeFilmstrip]
         dismissOn:nil];
  [binder bindStep:sFilmstripZoom
           atIndex:ixFilmstripZoom
         advanceOn:[KKJoyrideTrigger miniViewerZoomed]
         dismissOn:nil];
  [binder bindStep:sNavigate
           atIndex:ixNavigate
         advanceOn:[KKJoyrideTrigger filmstripCellActivated]
         dismissOn:nil];
  [binder
       bindStep:sOnion
        atIndex:ixOnion
      advanceOn:[KKJoyrideTrigger renderModeChanged:KKMiniViewerRenderModeOnion]
      dismissOn:nil];
  [binder bindStep:sSize
           atIndex:ixSize
         advanceOn:[KKJoyrideTrigger miniViewerSizeChanged:kSizeLargeIndex]
         dismissOn:nil];

  return @[
    sOpen, sIntro, sDrag, sZoom, sReset, sFilmstrip, sFilmstripZoom, sNavigate,
    sOnion, sOnionExplain, sSize, sDone
  ];
}

@end
