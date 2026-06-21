/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasMiniViewerRenderer_Internal.h"
#import "CanvasPathMorph.h"  // CanvasPathMorphedAtFraction
#import "CanvasPathOSC.h"    // CanvasDrawPathEditOSC
#import "CanvasPenCursors.h" // shared pen cursor set
#import "CanvasPenMarquee.h" // shared dashed-marquee perimeter walk
#import "CanvasToolbar.h"    // CanvasToolbarToolPen
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/NSColor+KKColors.h>

// An NSColor as straight sRGB RGBA.
static simd_float4 CanvasMiniColorRGBA(NSColor *color) {
  NSColor *c = [color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
  CGFloat r = 1, g = 1, b = 1, a = 1;
  [c getRed:&r green:&g blue:&b alpha:&a];
  return simd_make_float4((float)r, (float)g, (float)b, (float)a);
}

// Host accent, for the selected-anchor + marquee stroke.
static simd_float4 CanvasMiniAccentRGBA(void) {
  return CanvasMiniColorRGBA([NSColor accentMatchingHost]);
}

static CanvasPenModifiers PenModsFromNS(NSEventModifierFlags m) {
  CanvasPenModifiers o = CanvasPenModNone;
  if (m & NSEventModifierFlagShift)
    o |= CanvasPenModShift;
  if (m & NSEventModifierFlagCommand)
    o |= CanvasPenModCmd;
  if (m & NSEventModifierFlagControl)
    o |= CanvasPenModCtrl;
  if (m & NSEventModifierFlagOption)
    o |= CanvasPenModOpt;
  return o;
}

@implementation CanvasMiniViewerRenderer (Pen)

#pragma mark - Tool-drawing delegate hooks (from KKMiniViewerOverlay)

- (BOOL)miniViewerToolDrawingActive:(KKMiniViewerView *)canvas {
  return self.toolbarTool == CanvasToolbarToolPen;
}

- (void)miniViewer:(KKMiniViewerView *)canvas
    toolDownAtPoint:(CGPoint)point
        contentRect:(CGRect)cr
          modifiers:(NSEventModifierFlags)mods {
  self.penContentRect = cr;
  // Opt-click an existing anchor removes it (auto-delete cascade); only
  // consumes when an anchor was under it, so Opt elsewhere falls through to
  // normal pen.
  if (!self.penController.active && (mods & NSEventModifierFlagOption) &&
      [self.pathEditController removeAnchorAtX:point.x y:point.y])
    return;
  // Context-sensitive: not mid-draw + over the selected path's segment ->
  // insert an anchor (and begin dragging it via the path-edit controller).
  if (!self.penController.active &&
      [self.pathEditController penInsertAtX:point.x y:point.y])
    return;
  [self.penController mouseDownAtX:point.x
                                 y:point.y
                         modifiers:PenModsFromNS(mods)];
}

- (void)miniViewer:(KKMiniViewerView *)canvas
    toolDraggedToPoint:(CGPoint)point
           contentRect:(CGRect)cr
             modifiers:(NSEventModifierFlags)mods {
  self.penContentRect = cr;
  if (self.pathEditController
          .dragging) { // a pen-insert is dragging the new anchor
    [self.pathEditController mouseDraggedAtX:point.x
                                           y:point.y
                                   modifiers:PenModsFromNS(mods)];
    return;
  }
  [self.penController mouseDraggedAtX:point.x
                                    y:point.y
                            modifiers:PenModsFromNS(mods)];
}

- (void)miniViewer:(KKMiniViewerView *)canvas
     toolUpAtPoint:(CGPoint)point
       contentRect:(CGRect)cr {
  self.penContentRect = cr;
  if (self.pathEditController
          .dragging) { // end the pen-insert (commit one undo)
    [self.pathEditController mouseUp];
    return;
  }
  [self.penController mouseUp];
}

- (void)miniViewer:(KKMiniViewerView *)canvas
    toolMovedToPoint:(CGPoint)point
         contentRect:(CGRect)cr {
  self.penContentRect = cr;
  [self.penController mouseMovedAtX:point.x y:point.y];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas toolKeyDown:(unsigned short)key {
  // Delete / Backspace removes the selected path anchors (cursor tool),
  // matching the viewer's keyDown. Pen keys (Esc/Return) go to the pen
  // controller.
  if ((key == 127 || key == 8) &&
      (self.toolbarTool ?: CanvasToolbarToolCursor) != CanvasToolbarToolPen &&
      self.pathEditController.selectedAnchors.count > 0)
    return [self.pathEditController
        removeAnchorsAtIndexes:self.pathEditController.selectedAnchors
                     breakPath:YES];
  return [self.penController keyDown:key];
}

- (NSCursor *)miniViewer:(KKMiniViewerView *)canvas
       toolCursorAtPoint:(CGPoint)point
             contentRect:(CGRect)cr {
  self.penContentRect = cr;
  if (!self.penController.active) {
    // Opt over an existing anchor -> "remove point" (matches the Opt-click).
    if (([NSEvent modifierFlags] & NSEventModifierFlagOption) &&
        [self.pathEditController hitTestAtX:point.x
                                          y:point.y] == CanvasPathEditHitAnchor)
      return CanvasPenCursorForRole(CanvasPenCursorRoleDelete);
    // Hovering the selected path's curve -> "add point".
    if ([self.pathEditController segmentHitAtX:point.x y:point.y])
      return CanvasPenCursorForRole(CanvasPenCursorRoleAdd);
  }
  return [self.penController cursorKindAtX:point.x
                                         y:point.y] == CanvasPenCursorClose
             ? CanvasPenCursorForRole(CanvasPenCursorRoleClose)
             : CanvasPenCursorForRole(CanvasPenCursorRolePen);
}

- (void)miniViewerDrawToolOverlay:(KKMiniViewerView *)canvas
                      contentRect:(CGRect)cr {
  self.penContentRect = cr;
  self.penDrawCanvas = canvas;
  [self.penController confirmIfContextLost]; // tool / layer switch finalises
  // Path-edit OSC FIRST (so the cursor tool edits it AND the pen can target a
  // segment), then the pen overlay on top so its endpoint highlight sits over
  // the normal anchors.
  if (!self.penController.active)
    [self _drawSelectedPathEditOSC];
  [self.penController draw];
  self.penDrawCanvas = nil;
}

- (void)_drawSelectedPathEditOSC {
  if (![self labelVisibleOrRevealing:@"Points"])
    return; // hidden and not being Opt-revealed
  NSString *sel = self.selectedLayerID;
  if (!sel.length)
    return;
  KKBezierPath *path = nil;
  for (KKBezierPath *p in self.layers)
    if ([p.layerID isEqualToString:sel]) {
      path = p;
      break;
    }
  if (!path || path.isImage || path.isGroup || !path.strokeEnabled ||
      path.count < 1)
    return;
  // OSC rule: anchors show only when constant or on a Points keypose.
  if (!CanvasPathGeometryEditableAtFraction(path, self.editFraction))
    return;
  // Dim ghost for a master-on reveal (Opt-click re-shows); full alpha when
  // fully visible or in master-off peek-and-use - same rule as the transform
  // handles.
  BOOL ghost = [self ghostAlphaForLabel:@"Points"] < 1.0;
  CanvasDrawPathEditOSC(self, self.layers ?: @[],
                        CanvasPathMorphedAtFraction(path, self.editFraction),
                        self.editFraction, (float)[self penCanvasAspect],
                        self.pathEditController.selectedAnchors,
                        self.pathEditController.marqueeActive,
                        self.pathEditController.marqueeSurfaceRect, ghost);
}

#pragma mark - CanvasPenSurface (coords)

// The pen + path-edit OSC use the RAW content-rect map (the base class linear
// map), NOT the gizmo's handlePointForContentRect override: the gizmo folds in
// a geometry-centre offset that would shift mid-draw (the in-progress path's
// bbox centre keeps changing), and the path-edit OSC already projects through
// the full layer transform before it gets here. Position space is Y-DOWN;
// KKBezierPath points are Y-UP - flip Y.
- (CGPoint)penObjFromSurfaceX:(double)x y:(double)y {
  CGRect cr = self.penContentRect;
  if (cr.size.width <= 0 || cr.size.height <= 0)
    return CGPointMake(0.5, 0.5);
  double px = (x - cr.origin.x) / cr.size.width;
  double py = (y - cr.origin.y) / cr.size.height; // Y-down normalized
  return CGPointMake(px, 1.0 - py);               // Y-up object
}

- (CGPoint)penSnappedObjFromSurfaceX:(double)x y:(double)y {
  CGPoint o = [self penObjFromSurfaceX:x y:y]; // Y-up
  simd_float2 ydown = simd_make_float2((float)o.x, (float)(1.0 - o.y));
  simd_float2 sn = [self _penRawSnapToGrid:ydown
                               contentRect:self.penContentRect];
  return CGPointMake(sn.x, 1.0 - sn.y);
}

- (CGPoint)penSurfacePointFromObj:(CGPoint)objYUp {
  return [super handlePointForContentRect:self.penContentRect
                                 position:@[ @(objYUp.x), @(1.0 - objYUp.y) ]];
}

// Raw grid snap for the pen: snap a Y-down normalized point to the drawn grid
// cells directly (no gizmo homography). Mirrors the cell sizing the grid draws.
- (simd_float2)_penRawSnapToGrid:(simd_float2)p contentRect:(CGRect)cr {
  if (!self.gridEnabled || !self.gridSnap)
    return p;
  double nx = self.drawnGridNX, ny = self.drawnGridNY;
  if (nx <= 0 || ny <= 0)
    return p;
  return simd_make_float2((float)(round(p.x / nx) * nx),
                          (float)(round(p.y / ny) * ny));
}

- (BOOL)penGridSnapping {
  return self.gridEnabled && self.gridSnap;
}

- (double)penCanvasAspect {
  return self.renderHeight > 0 ? self.renderWidth / self.renderHeight : 1.0;
}

- (BOOL)penToolActive {
  return self.toolbarTool == CanvasToolbarToolPen;
}

#pragma mark - CanvasPenSurface (blob)

- (KKBezierPath *)penLayerWithID:(NSString *)layerID {
  for (KKBezierPath *p in self.layers)
    if ([p.layerID isEqualToString:layerID])
      return p;
  return nil;
}

- (NSString *)penSelectedLayerID {
  return self.selectedLayerID;
}

- (void)penMutateBlob:(void (^)(NSMutableArray<KKBezierPath *> *paths))mutate
        selectLayerID:(NSString *)selectID {
  NSMutableArray<KKBezierPath *> *paths =
      [self.layers mutableCopy] ?: [NSMutableArray array];
  mutate(paths);
  self.layers =
      paths; // immediate so penLayerWithID sees it on the next draw/click
  if (self.onPersistLayers)
    self.onPersistLayers(paths, selectID);
}

- (NSArray<KKBezierPath *> *)penAllLayers {
  return self.layers ?: @[];
}

- (double)penEditFraction {
  return self.editFraction;
}

- (void)penSetLiveLayers:(NSArray<KKBezierPath *> *)paths {
  self.layers =
      paths; // mini renders from self.layers -> live preview, no persist
}

- (void)penPreviewLayers:(NSArray<KKBezierPath *> *)paths {
  self.layers =
      paths; // mini never persists live; mouseUp's commit is the one undo
}

- (void)penCommitLiveLayers {
  if (self.onPersistLayers)
    self.onPersistLayers(self.layers, nil);
}

#pragma mark - CanvasPenSurface (draw primitives, Metal pass - match motion path)

// Anchor dots: white glyphs at the motion-path's anchor size (0.6). The ghost
// (next-point preview) is the same glyph dimmed. Uniform size - no grow on
// hover/active, so it reads the same as the path OSC.
- (void)penDrawDotAtObj:(CGPoint)objYUp
                  ghost:(BOOL)ghost
                hovered:(BOOL)hovered
                 active:(BOOL)active {
  simd_float4 fill =
      active ? CanvasMiniAccentRGBA()
             : simd_make_float4(1.0f, 1.0f, 1.0f, ghost ? 0.4f : 1.0f);
  [self.penDrawCanvas encodeToolDotAtPoint:[self penSurfacePointFromObj:objYUp]
                                      fill:fill
                                 sizeScale:0.6];
}

- (void)penDrawWarnDotAtObj:(CGPoint)objYUp {
  // Same dot glyph as an anchor, filled in the warning colour - flags the open
  // endpoint the pen will continue from.
  [self.penDrawCanvas
      encodeToolDotAtPoint:[self penSurfacePointFromObj:objYUp]
                      fill:CanvasMiniColorRGBA([NSColor warning])
                 sizeScale:0.6];
}

// Marquee rubber-band. `r` is in SURFACE points (view points) - drawn directly,
// no obj projection. Port of Attic's drawDashedRect: a two-tone dashed
// rectangle (light dash over dark gap), each dash emitted as a 2-point strip.
// Snap corners to whole points + 0.5 so the four edges land consistently.
- (void)penDrawMarqueeRect:(CGRect)r {
  simd_float4 lightColor = {1.0f, 1.0f, 1.0f, 0.9f};
  simd_float4 darkColor = {0.0f, 0.0f, 0.0f, 0.6f};
  // Same stroke-relative ratio as the viewer (the mini stroke is half the
  // viewer's, 0.75 vs 1.5, so dash/gap halve too: 8/5 -> 4/2.5), keeping the
  // dashes visually consistent across both surfaces. The perimeter walk is
  // shared (CanvasPenMarqueeWalk); the mini draws each dash as its own strip.
  KKMiniViewerView *canvas = self.penDrawCanvas;
  CanvasPenMarqueeWalk(r, 4.0, 2.5, ^(CGPoint from, CGPoint to, BOOL light) {
    [canvas
        encodeToolLineStrip:@[
          [NSValue valueWithPoint:from], [NSValue valueWithPoint:to]
        ]
                      color:(light ? lightColor : darkColor)halfWidthPt:0.75];
  });
}

- (void)penDrawCurveObjPoints:(const CGPoint *)objPts count:(NSUInteger)count {
  if (count < 2)
    return;
  NSMutableArray<NSValue *> *pts = [NSMutableArray arrayWithCapacity:count];
  for (NSUInteger i = 0; i < count; i++)
    [pts addObject:[NSValue
                       valueWithPoint:[self penSurfacePointFromObj:objPts[i]]]];
  simd_float4 red = {1.0f, 0.25f, 0.25f, 0.9f}; // matches the motion path
  [self.penDrawCanvas encodeToolLineStrip:pts color:red halfWidthPt:1.0];
}

- (void)penDrawHandleFromObj:(CGPoint)aObj toObj:(CGPoint)bObj {
  CGPoint a = [self penSurfacePointFromObj:aObj];
  CGPoint b = [self penSurfacePointFromObj:bObj];
  simd_float4 white = {1.0f, 1.0f, 1.0f, 0.85f};
  [self.penDrawCanvas
      encodeToolLineStrip:@[
        [NSValue valueWithPoint:a], [NSValue valueWithPoint:b]
      ]
                    color:white
              halfWidthPt:0.75]; // matches the motion path's tangent segments
  simd_float4 dot = {1.0f, 1.0f, 1.0f, 1.0f};
  [self.penDrawCanvas encodeToolDotAtPoint:b fill:dot sizeScale:0.5];
}

@end
