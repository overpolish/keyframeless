/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The pen / path-edit OVERLAY draw orchestration, split out of CanvasOSC+Pen.m:
// the in-progress pen preview, the multi-select silhouette, the marquee band,
// and the selected path's point-edit OSC. These compose the surface draw
// primitives (which stay in CanvasOSC+Pen.m) into the per-tick overlay.

#import "CanvasAnchorSelectionSync.h" // cross-process selection sync
#import "CanvasLayerRender.h"         // CanvasProjectLayerPointsObj
#import "CanvasLayerTimeline.h"       // blob + UIState snapshots
#import "CanvasOSC_Private.h"
#import "CanvasPathMorph.h" // CanvasPathMorphedAtFraction
#import "CanvasPathOSC.h"   // CanvasDrawPathEditOSC
#import "CanvasPenController.h"
#import <AppKit/AppKit.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/NSColor+KKColors.h>

@implementation CanvasOSC (PenDraw)

- (void)_drawPenInProgressWithWidth:(NSInteger)width
                             height:(NSInteger)height
                   destinationImage:(FxImageTile *)destinationImage
                             atTime:(CMTime)time {
  self.penDrawDest = destinationImage;
  self.penDrawTime = time;
  [self.penController draw];
  self.penDrawDest = nil;
}

// Multi-selection display: the point OSC (anchors + curve) of EVERY selected
// vector layer, drawn dimmed (ghost) so it reads as "selected, not editable" -
// shown regardless of the Points OSC visibility toggle. Point editing is gated
// off while more than one layer is selected (it's a layer-level selection). The
// per-anchor display still follows the keypose rule (anchors only where the
// geometry is editable at this fraction). No-op for a single selection.
- (void)_drawMultiSelectHighlightInDestination:(FxImageTile *)destinationImage
                                        atTime:(CMTime)time {
  NSArray<NSString *> *sel = [self _selectedLayerIDs];
  if (sel.count < 2)
    return;
  NSArray<KKBezierPath *> *paths = [self _snapshotPaths];
  double frac = [self fractionAtTime:time];
  float aspect = (float)[self _canvasAspect];
  self.penDrawDest = destinationImage;
  self.penDrawTime = time;
  for (KKBezierPath *p in paths) {
    if (![sel containsObject:(p.layerID ?: @"")])
      continue;
    // Images have no points to outline - draw a dimmed box as their indicator.
    if (p.isImage) {
      CanvasDrawLayerBoxOSC(self, paths, p, frac, aspect);
      continue;
    }
    if (p.isGroup || p.count < 1)
      continue;
    if (!CanvasPathGeometryEditableAtFraction(p, frac))
      continue;
    CanvasDrawPathEditOSC(self, paths, CanvasPathMorphedAtFraction(p, frac),
                          frac, aspect, /*selected=*/nil, /*marqueeActive=*/NO,
                          CGRectZero, /*ghost=*/YES, /*showCornerWidgets=*/NO);
  }
  self.penDrawDest = nil;
}

// The marquee rubber-band, drawn independently of the selection (the marquee can
// run with 0, 1, or 2+ layers selected, so it can't ride on the single-path
// point OSC's draw - that's why it vanished while multi-selected).
- (void)_drawMarqueeInDestination:(FxImageTile *)destinationImage {
  if (!self.pathEditController.marqueeActive)
    return;
  self.penDrawDest = destinationImage;
  [self penDrawMarqueeRect:self.pathEditController.marqueeSurfaceRect];
  self.penDrawDest = nil;
}

- (void)_drawSelectedPathEditOSCInDestination:(FxImageTile *)destinationImage
                                       atTime:(CMTime)time {
  BOOL visible = [self kkOSCElementVisible:@"Points"];
  // Hidden but an Opt-peek wants to reveal it, like the transform handles:
  //  - master ON  + individually hidden -> dimmed re-show ghost (Opt-click
  //  re-shows)
  //  - master OFF (all off) -> "peek and use": revealed at FULL alpha +
  //  draggable
  BOOL reveal =
      !visible && self.optRevealActive && [self kkOSCRevealEligible:@"Points"];
  if (!visible && !reveal)
    return; // toggled off in the OSC-visibility popover and not being revealed
  BOOL ghost = reveal && ![self kkOSCMasterOff];
  NSString *sel = [self _resolvedSelectedLayerID];
  if (!sel.length)
    return;
  // Pick up an anchor selection published by the mini (cross-process sync).
  NSIndexSet *synced = CanvasConsumeAnchorSelection(@"osc", sel);
  if (synced)
    [self.pathEditController setSelectedAnchorIndexes:synced];
  KKBezierPath *path = nil;
  NSArray<KKBezierPath *> *paths = [self _snapshotPaths];
  for (KKBezierPath *p in paths)
    if ([p.layerID isEqualToString:sel]) {
      path = p;
      break;
    }
  if (!path || path.isImage || path.isGroup ||
      (!path.strokeEnabled && !path.fillEnabled) || path.count < 1)
    return;
  double frac = [self fractionAtTime:time];
  // OSC rule: anchors show only when the path is constant or the playhead is on
  // a Points keypose - hidden between keyposes (the stroke still morphs).
  if (!CanvasPathGeometryEditableAtFraction(path, frac))
    return;
  self.penDrawDest = destinationImage;
  self.penDrawTime = time;
  CanvasDrawPathEditOSC(self, paths, CanvasPathMorphedAtFraction(path, frac),
                        frac, (float)[self _canvasAspect],
                        self.pathEditController.selectedAnchors,
                        /*marqueeActive=*/NO, CGRectZero, ghost,
                        [self _activeTool] == CanvasToolbarToolCursor);
  self.penDrawDest = nil;
}

@end
