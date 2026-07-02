/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasAnchorSelectionSync.h" // cross-process selection sync
#import "CanvasLayerTree.h"           // CanvasDeleteLayersByID
#import "CanvasMiniViewerRenderer_Internal.h"
#import "CanvasPathMorph.h"  // CanvasPathMorphedAtFraction
#import "CanvasPathOSC.h"    // CanvasDrawPathEditOSC / CanvasDrawPathOpPreview
#import "CanvasPathOps.h"    // CanvasPathOpPreview
#import "CanvasPenCursors.h" // shared pen cursor set
#import "CanvasPenMarquee.h" // shared dashed-marquee perimeter walk
#import "CanvasToolbar.h"    // CanvasToolbarToolPen
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/NSColor+KKColors.h>
#import <Metal/Metal.h>

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

- (BOOL)miniViewerToolDrawingActive:(KKMiniViewerView *)canvas {
  return self.toolbarTool == CanvasToolbarToolPen || [self _shapeToolActive];
}

- (NSInteger)miniViewerGuidePenPointCount:(KKMiniViewerView *)canvas {
  return [self.penController inProgressPointCount];
}

- (NSPoint)miniViewerGuideLastPenPointView:(KKMiniViewerView *)canvas {
  CGPoint obj;
  if (![self.penController lastInProgressPointObj:&obj])
    return NSZeroPoint;
  // penContentRect maps object (y-up) -> the mini's view points (the content
  // rect the delegate is fed), so this is the anchor in view space.
  return NSPointFromCGPoint([self penSurfacePointFromObj:obj]);
}

- (void)miniViewer:(KKMiniViewerView *)canvas
    toolDownAtPoint:(CGPoint)point
        contentRect:(CGRect)cr
          modifiers:(NSEventModifierFlags)mods {
  self.penContentRect = cr;
  if ([self _shapeToolActive]) {
    [self _syncShapeKind];
    [self.shapeController mouseDownAtX:point.x
                                     y:point.y
                             modifiers:PenModsFromNS(mods)];
    return;
  }
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
  if ([self _shapeToolActive]) {
    [self.shapeController mouseDraggedAtX:point.x
                                        y:point.y
                                modifiers:PenModsFromNS(mods)];
    [canvas setNeedsDisplay:YES];
    return;
  }
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
  if ([self _shapeToolActive]) {
    [self.shapeController mouseUp];
    return;
  }
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
  if ([self _shapeToolActive])
    return; // the shape tool has no hover state (box exists only mid-drag)
  [self.penController mouseMovedAtX:point.x y:point.y];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas toolKeyDown:(unsigned short)key {
  // Delete / Backspace removes the selected path anchors (cursor tool),
  // matching the viewer's keyDown. Pen keys (Esc/Return) go to the pen
  // controller.
  BOOL isDelete = (key == 127 || key == 8);
  BOOL cursorTool =
      (self.toolbarTool ?: CanvasToolbarToolCursor) == CanvasToolbarToolCursor;
  if (isDelete && cursorTool &&
      self.pathEditController.selectedAnchors.count > 0)
    return [self.pathEditController
        removeAnchorsAtIndexes:self.pathEditController.selectedAnchors
                     breakPath:YES];
  // Delete with a LAYER selected (no anchors) removes the selected layer(s).
  // Returning YES consumes the key so it never reaches FCP (deleting the whole
  // effect) - mirrors the viewer.
  if (isDelete && cursorTool &&
      self.pathEditController.selectedAnchors.count == 0 &&
      [self _miniDeleteSelectedLayers])
    return YES;
  return [self.penController keyDown:key];
}

- (BOOL)_miniDeleteSelectedLayers {
  NSArray<NSString *> *sel = [self _miniSelectedIDs];
  if (sel.count == 0)
    return NO;
  NSMutableArray<KKBezierPath *> *paths =
      [self.layers mutableCopy] ?: [NSMutableArray array];
  NSUInteger before = paths.count;
  CanvasDeleteLayersByID(paths, sel);
  if (paths.count == before)
    return NO; // selection didn't match any layer - nothing removed
  // Clear our own selection immediately for an instant redraw, then persist the
  // blob + cleared selection as ONE undo action via onDeleteLayers (the param
  // round-trip re-applies the empty selection inspector-wide). Leaving the
  // selection EMPTY matches the canvas model.
  self.layers = paths;
  self.selectedLayerIDs = @[];
  self.selectedLayerID = nil;
  if (self.onDeleteLayers)
    self.onDeleteLayers(paths);
  return YES;
}

- (NSCursor *)miniViewer:(KKMiniViewerView *)canvas
       toolCursorAtPoint:(CGPoint)point
             contentRect:(CGRect)cr {
  self.penContentRect = cr;
  if ([self _shapeToolActive])
    return [NSCursor crosshairCursor]; // matches the viewer's shape cursor
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
  // The kit base map (NOT the gizmo override - see penObjFromSurface above),
  // inlined: a busy path-edit OSC projects this once per anchor + handle +
  // curve sample every redraw, so the per-call NSArray/NSNumber boxing of the
  // super-send showed up as allocation churn while panning. This is the exact
  // affine -[KKMiniViewerRenderer handlePointForContentRect:position:] applies.
  CGRect cr = self.penContentRect;
  return CGPointMake(CGRectGetMinX(cr) + objYUp.x * cr.size.width,
                     CGRectGetMinY(cr) + (1.0 - objYUp.y) * cr.size.height);
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

- (KKBezierPath *)penLayerWithID:(NSString *)layerID {
  for (KKBezierPath *p in self.layers)
    if ([p.layerID isEqualToString:layerID])
      return p;
  return nil;
}

- (NSString *)penSelectedLayerID {
  return self.selectedLayerID;
}

- (NSArray<NSString *> *)penSelectedLayerIDs {
  return [self _miniSelectedIDs];
}

- (NSString *)penSurfaceTag {
  return @"mini";
}

- (NSString *)penInstanceUUID {
  return self.instanceUUID;
}

// The popover scope's non-selectable layers for the MARQUEE / body-drag. Uses
// the stricter marquee set (constants: move-lane-animated) when present, else
// the single-click set (keypose: no keypose at that time).
- (NSSet<NSString *> *)penNonSelectableLayerIDs {
  return self.marqueeNonSelectableLayerIDs ?: self.nonSelectableLayerIDs;
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

// Anchor dots: white glyphs at the motion-path's anchor size (0.66 - a touch
// bigger than the base 0.6 to read better in the mini). The ghost (next-point
// preview) is the same glyph dimmed. Uniform size - no grow on hover/active, so
// it reads the same as the path OSC.
- (void)penDrawDotAtObj:(CGPoint)objYUp
                  ghost:(BOOL)ghost
                hovered:(BOOL)hovered
                 active:(BOOL)active {
  simd_float4 fill =
      active ? CanvasMiniAccentRGBA()
             : simd_make_float4(1.0f, 1.0f, 1.0f, ghost ? 0.4f : 1.0f);
  [self.penDrawCanvas encodeToolDotAtPoint:[self penSurfacePointFromObj:objYUp]
                                      fill:fill
                                 sizeScale:0.66];
}

- (void)penDrawWarnDotAtObj:(CGPoint)objYUp {
  // Same dot glyph as an anchor, filled in the warning colour - flags the open
  // endpoint the pen will continue from.
  [self.penDrawCanvas
      encodeToolDotAtPoint:[self penSurfacePointFromObj:objYUp]
                      fill:CanvasMiniColorRGBA([NSColor warning])
                 sizeScale:0.66];
}

- (void)penDrawRingAtObj:(CGPoint)objYUp maxed:(BOOL)maxed {
  KKMiniViewerView *canvas = self.penDrawCanvas;
  if (!canvas)
    return;
  // The shared KKRingOSC shader (same as the viewer ring + Glow's radius ring),
  // tinted accent / error. Scales with the popover via the OSC sizing ratio;
  // the shader is crisp so no manual snap is needed.
  CGFloat scale = canvas.oscSizingHeight / 230.0;
  if (scale <= 0)
    scale = 1.0;
  simd_float4 fill = maxed ? CanvasMiniColorRGBA([NSColor error])
                           : CanvasMiniColorRGBA([NSColor whiteColor]);
  simd_float4 outline = {0.0f, 0.0f, 0.0f, 0.75f};
  // Dim to a ghost while "Corners" is individually hidden but Opt-peeked (master
  // on) - the cue that an Opt-click re-shows it, like the other handles. Full
  // alpha when visible or in master-off peek-and-use.
  float ghostA = (float)[self ghostAlphaForLabel:@"Corners"];
  fill.w *= ghostA;
  outline.w *= ghostA;
  [canvas encodeToolRingAtPoint:[self penSurfacePointFromObj:objYUp]
                       radiusPt:2.3 * scale
                           fill:fill
                    strokeColor:outline
                    fillWidthPt:1.0 * scale
                 outlineWidthPt:0.5 * scale];
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
    CGPoint seg[2] = {from, to};
    [canvas encodeToolLineStripPoints:seg
                                count:2
                                color:(light ? lightColor
                                             : darkColor)halfWidthPt:0.75];
  });
}

// CanvasPenSurface: a plain empty-canvas click clears the whole selection,
// matching the main viewer. The inspector's onSelectLayers handler routes the
// empty set to the no-layer state.
- (void)penDeselectAll {
  self.selectedLayerIDs = @[];
  self.selectedLayerID = nil;
  if (self.onSelectLayers)
    self.onSelectLayers(@[], @"");
}

// CanvasPenSurface: commit a marquee layer selection. Plain replaces the set
// with the enclosed layers (primary = topmost), Shift unions them into the
// current selection. Routes through onSelectLayers so the inspector + viewer
// follow, mirroring the mini's background-click multi-select.
- (void)penSelectLayerIDs:(NSArray<NSString *> *)layerIDs
                 additive:(BOOL)additive {
  if (!layerIDs.count)
    return;
  NSMutableArray<NSString *> *set;
  NSString *primary;
  if (additive) {
    set = [[self _miniSelectedIDs] mutableCopy] ?: [NSMutableArray array];
    for (NSString *lid in layerIDs)
      if (![set containsObject:lid])
        [set addObject:lid];
    primary = set.firstObject;
  } else {
    set = [layerIDs mutableCopy];
    primary = layerIDs.firstObject;
  }
  self.selectedLayerIDs = set;
  self.selectedLayerID = primary;
  if (self.onSelectLayers)
    self.onSelectLayers(set, primary);
  else if (self.onSelectLayer)
    self.onSelectLayer(primary);
}

- (void)penDrawCurveObjPoints:(const CGPoint *)objPts count:(NSUInteger)count {
  if (count < 2)
    return;
  CGPoint *sp = malloc(sizeof(CGPoint) * count);
  for (NSUInteger i = 0; i < count; i++)
    sp[i] = [self penSurfacePointFromObj:objPts[i]];
  simd_float4 red = {1.0f, 0.25f, 0.25f, 0.9f}; // matches the motion path
  [self.penDrawCanvas encodeToolLineStripPoints:sp
                                          count:count
                                          color:red
                                    halfWidthPt:1.0];
  free(sp);
}

- (void)penDrawColoredCurveObjPoints:(const CGPoint *)objPts
                               count:(NSUInteger)count
                               color:(simd_float4)color {
  if (count < 2)
    return;
  CGPoint *sp = malloc(sizeof(CGPoint) * count);
  for (NSUInteger i = 0; i < count; i++)
    sp[i] = [self penSurfacePointFromObj:objPts[i]];
  [self.penDrawCanvas encodeToolLineStripPoints:sp
                                          count:count
                                          color:color
                                    halfWidthPt:1.0];
  free(sp);
}

- (void)penDrawSnappedLoopObjPoints:(const CGPoint *)objPts
                              count:(NSUInteger)count
                              color:(simd_float4)color {
  if (count < 2)
    return;
  KKMiniViewerView *canvas = self.penDrawCanvas;
  CGFloat s = canvas.window.backingScaleFactor;
  if (s <= 0)
    s = 1.0;
  CGPoint *sp = malloc(sizeof(CGPoint) * count);
  for (NSUInteger i = 0; i < count; i++) {
    CGPoint p = [self penSurfacePointFromObj:objPts[i]];
    // Snap to a whole DRAWABLE pixel centre (the mini works in points, so round
    // in px = pt * backingScale, then convert back), matching the grid's crisp
    // floor + 0.5 so the box edges aren't soft.
    sp[i] = CGPointMake((floor(p.x * s) + 0.5) / s, (floor(p.y * s) + 0.5) / s);
  }
  [canvas encodeToolLineStripPoints:sp count:count color:color halfWidthPt:1.0];
  free(sp);
}

- (void)penDrawHandleFromObj:(CGPoint)aObj toObj:(CGPoint)bObj {
  CGPoint seg[2] = {[self penSurfacePointFromObj:aObj],
                    [self penSurfacePointFromObj:bObj]};
  simd_float4 white = {1.0f, 1.0f, 1.0f, 0.85f};
  // matches the motion path's tangent segments
  [self.penDrawCanvas encodeToolLineStripPoints:seg
                                          count:2
                                          color:white
                                    halfWidthPt:0.75];
  simd_float4 dot = {1.0f, 1.0f, 1.0f, 1.0f};
  [self.penDrawCanvas encodeToolDotAtPoint:seg[1] fill:dot sizeScale:0.5];
}

@end
