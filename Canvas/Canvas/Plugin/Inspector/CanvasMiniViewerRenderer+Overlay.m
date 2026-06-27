/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasAnchorSelectionSync.h" // CanvasConsumeAnchorSelection
#import "CanvasMiniViewerRenderer_Internal.h"
#import "CanvasPathMorph.h" // CanvasPathMorphedAtFraction / GeometryEditable
#import "CanvasPathOSC.h" // CanvasDrawPathEditOSC / CanvasDrawLayerBoxOSC / fill
#import "CanvasPathOps.h" // CanvasPathOpPreview
#import "CanvasToolbar.h" // CanvasToolbarTool*
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKBezierPath.h>
#import <Metal/Metal.h>

// The mini's tool-overlay DRAW pass: the delegate entry
// (miniViewerDrawToolOverlay:) and the overlay layers it composites - the
// path-op fill preview, the multi-select highlight boxes, the rubber-band
// marquee, and the selected path's edit OSC. Split from the pen-surface
// primitives + event hooks (CanvasMiniViewerRenderer+Pen.m) so each file stays
// focused.
@implementation CanvasMiniViewerRenderer (Overlay)

- (void)miniViewerDrawToolOverlay:(KKMiniViewerView *)canvas
                      contentRect:(CGRect)cr {
  self.penContentRect = cr;
  self.penDrawCanvas = canvas;
  if ([self _shapeToolActive]) {
    // Like the viewer's shape branch: just the drag-out box preview, no gizmo
    // or path-edit OSC.
    [self.shapeController draw];
    self.penDrawCanvas = nil;
    return;
  }
  [self.penController confirmIfContextLost]; // tool / layer switch finalises
  // Path-edit OSC FIRST (so the cursor tool edits it AND the pen can target a
  // segment), then the pen overlay on top so its endpoint highlight sits over
  // the normal anchors.
  if (!self.penController.active) {
    NSUInteger nsel = [self _miniSelectedIDs].count;
    if (nsel >= 2)
      [self _drawMultiSelectHighlight];
    else if (nsel == 1)
      [self _drawSelectedPathEditOSC];
    // The marquee draws over any selection state (0/1/2+), so draw it
    // separately.
    [self _drawMarquee];
  }
  [self _drawPathOpHoverPreview];
  [self.penController draw];
  self.penDrawCanvas = nil;
}

// Path-op hover preview (operands red / result green, FILLED), mirroring the
// viewer. The pointer is over a path-op toolbar button (hoveredTag). Renders
// the shared CG fill to a drawable-sized texture (object -> drawable px via the
// mini projection) and blits it through the kit's tool-overlay encoder.
- (void)_drawPathOpHoverPreview {
  BOOL outline = NO, centerline = NO;
  KKBooleanOp op = KKBooleanOpUnion;
  if (!CanvasToolbarTagToPathOp(self.toolbar.hoveredTag, &outline, &op,
                                &centerline) ||
      centerline)
    return; // centerline has no fill preview (its result is a stroke)
  CGFloat aspect = (self.renderHeight > 0 && self.renderWidth > 0)
                       ? self.renderWidth / self.renderHeight
                       : 16.0 / 9.0;
  // TRUE output px (strokeWidth's reference) - same as the outline op uses.
  CGFloat refW = self.outputWidth > 0 ? self.outputWidth : 1080.0 * aspect;
  CGFloat refH = self.outputHeight > 0 ? self.outputHeight : 1080.0;
  NSArray<KKBezierPath *> *paths = self.layers ?: @[];
  NSArray<KKBezierPath *> *operands = nil, *results = nil;
  if (!CanvasPathOpPreview(paths, [self _miniSelectedIDs], outline, op, refW,
                           refH, self.editFraction, &operands, &results))
    return;
  KKMiniViewerView *canvas = self.penDrawCanvas;
  if (!canvas)
    return;
  CGSize d = canvas.drawableSize;
  NSInteger w = (NSInteger)d.width, h = (NSInteger)d.height;
  if (w <= 0 || h <= 0)
    return;
  CGFloat s = canvas.window.backingScaleFactor;
  if (s <= 0)
    s = 2.0;
  __weak typeof(self) weakSelf = self;
  CGFloat bmH = (CGFloat)h;
  CGContextRef ctx = CanvasRenderPathOpFillBitmap(
      operands, results, paths, self.editFraction,
      (float)[self penCanvasAspect], w, h, refW, ^CGPoint(simd_float2 objYUp) {
        CGPoint pv =
            [weakSelf penSurfacePointFromObj:CGPointMake(objYUp.x, objYUp.y)];
        // The mini's drawable Y runs opposite the CG-bitmap/quad orientation
        // used by the blit (unlike the viewer's projection), so flip Y here.
        return CGPointMake(pv.x * s, bmH - pv.y * s);
      });
  if (!ctx)
    return;
  id<MTLTexture> tex = CanvasFillBitmapToTexture(ctx, canvas.device, w, h);
  CGContextRelease(ctx);
  [canvas encodeToolFillTexture:tex];
}

// Dimmed, non-editable point OSC of every selected vector layer (Shift-click
// multi-selection), shown regardless of the Points visibility toggle - mirrors
// the viewer OSC's multi-select highlight. No-op for a single selection.
- (void)_drawMultiSelectHighlight {
  // The dimmed indicator marks layers that the body-drag will MOVE, so use the
  // movable set (excludes the scope's non-selectable layers, e.g. constants
  // move-lane-animated) - a manually multi-selected excluded layer stays
  // selected in the list but shows no movable indicator here.
  NSArray<NSString *> *sel = [self _miniMovableSelectedIDs];
  // The caller already gates on the FULL selection being 2+; here just skip
  // when nothing in it is movable (all excluded by the scope).
  if (sel.count < 1)
    return;
  float aspect = (float)[self penCanvasAspect];
  for (KKBezierPath *p in self.layers) {
    if (![sel containsObject:(p.layerID ?: @"")])
      continue;
    // Images have no points to outline - draw a dimmed box as their indicator.
    if (p.isImage) {
      CanvasDrawLayerBoxOSC(self, self.layers ?: @[], p, self.editFraction,
                            aspect);
      continue;
    }
    if (p.isGroup || p.count < 1)
      continue;
    if (!CanvasPathGeometryEditableAtFraction(p, self.editFraction))
      continue;
    CanvasDrawPathEditOSC(self, self.layers ?: @[],
                          CanvasPathMorphedAtFraction(p, self.editFraction),
                          self.editFraction, aspect, /*selected=*/nil,
                          /*marqueeActive=*/NO, CGRectZero, /*ghost=*/YES,
                          /*showCornerWidgets=*/NO);
  }
}

// The marquee rubber-band, drawn independently of the selection count (mirrors
// the viewer's _drawMarqueeInDestination:).
- (void)_drawMarquee {
  if (!self.pathEditController.marqueeActive)
    return;
  [self penDrawMarqueeRect:self.pathEditController.marqueeSurfaceRect];
}

- (void)_drawSelectedPathEditOSC {
  if (![self labelVisibleOrRevealing:@"Points"])
    return; // hidden and not being Opt-revealed
  // Constants popover shows only constant lanes; keypose popover only the
  // animated one (matches the transform OSCs via isConstantLabel +
  // boundaryEditing).
  if (![self isConstantLabel:@"Points"])
    return;
  NSString *sel = self.selectedLayerID;
  if (!sel.length)
    return;
  // Pick up an anchor selection published by the viewer (cross-process sync).
  NSIndexSet *synced = CanvasConsumeAnchorSelection(@"mini", sel);
  if (synced)
    [self.pathEditController setSelectedAnchorIndexes:synced];
  KKBezierPath *path = nil;
  for (KKBezierPath *p in self.layers)
    if ([p.layerID isEqualToString:sel]) {
      path = p;
      break;
    }
  if (!path || path.isImage || path.isGroup ||
      (!path.strokeEnabled && !path.fillEnabled) || path.count < 1)
    return;
  // OSC rule: anchors show only when constant or on a Points keypose.
  if (!CanvasPathGeometryEditableAtFraction(path, self.editFraction))
    return;
  // Dim ghost for a master-on reveal (Opt-click re-shows); full alpha when
  // fully visible or in master-off peek-and-use - same rule as the transform
  // handles.
  BOOL ghost = [self ghostAlphaForLabel:@"Points"] < 1.0;
  // Corner-radius widgets are their own OSC element ("Corners"), toggleable
  // separately from the anchors. Gate the draw + the controller's hit-test on
  // the same visibility so a hidden widget isn't grabbable.
  BOOL cornersShown = [self labelVisibleOrRevealing:@"Corners"];
  self.pathEditController.cornerWidgetsActive = cornersShown;
  CanvasDrawPathEditOSC(
      self, self.layers ?: @[],
      CanvasPathMorphedAtFraction(path, self.editFraction), self.editFraction,
      (float)[self penCanvasAspect], self.pathEditController.selectedAnchors,
      /*marqueeActive=*/NO, CGRectZero, ghost,
      cornersShown &&
          (self.toolbarTool ?: CanvasToolbarToolCursor) ==
              CanvasToolbarToolCursor);
}

@end
