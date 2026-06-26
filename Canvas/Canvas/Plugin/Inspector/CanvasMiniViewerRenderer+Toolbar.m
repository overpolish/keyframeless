/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Toolbar chrome for the mini viewer, split from CanvasMiniViewerRenderer.m:
// tool switching, the shared bar's per-draw state + Metal draw, the hit / mouse
// / drag / keyboard / hover / cursor delegate hooks, and the path-op (boolean /
// outline) runners those buttons trigger.

#import "CanvasMiniViewerRenderer_Internal.h"

#import "CanvasCenterline.h" // CanvasApplyCenterlineOp
#import "CanvasPathOps.h"    // shared boolean / outline op cores
#import "CanvasToolbar.h"
#import <KeyframelessKit/KKToolbar.h>
#import <Metal/Metal.h>

@implementation CanvasMiniViewerRenderer (Toolbar)

- (void)setToolbarTool:(NSInteger)toolbarTool {
  // Switching INTO the pen tool drops any lingering cursor-mode point selection
  // (matches the viewer; a multi-point selection means nothing to the pen).
  if (toolbarTool == CanvasToolbarToolPen &&
      _toolbarTool != CanvasToolbarToolPen)
    [self.pathEditController clearSelection];
  _toolbarTool = toolbarTool;
  // The transform gizmo is for the cursor tool only (see
  // -_transformHandlesActive, which gates the scale / anchor / position
  // delegates). The rotation rings are drawn + hit-tested by the kit renderer
  // keyed on rotationLabel, bypassing that gate, so an Opt-peek would reveal
  // them under a drawing tool. Suppress the Rotation handle whenever a drawing
  // tool (pen / rect / ellipse) owns the canvas - matching the viewer, which
  // skips the whole gizmo for those tools.
  BOOL drawingTool = (toolbarTool == CanvasToolbarToolPen ||
                      toolbarTool == CanvasToolbarToolRect ||
                      toolbarTool == CanvasToolbarToolEllipse);
  self.suppressedHandleLabels = drawingTool ? @[ @"Rotation" ] : @[];
}

// Toolbar chrome: drive the per-draw state from the shared kParamUIState the
// inspector mirrors onto us, then render the SAME bar as the viewer into the
// mini's Metal pass via KKToolbar's shared encoder path.
- (void)miniViewer:(KKMiniViewerView *)canvas
    drawToolbarInEncoder:(id<MTLRenderCommandEncoder>)encoder
                  device:(id<MTLDevice>)device
                pipeline:(id<MTLRenderPipelineState>)pipeline
           viewportWidth:(float)width
                  height:(float)height {
  if (!self.toolbar)
    return;
  // Rebuild the bar when the selection brings in / drops the conditional
  // path-op groups (mirrors the viewer; KKToolbar's items are fixed at init).
  BOOL wantBooleans = NO, wantOutline = NO, wantCenterline = NO;
  [self _miniPathOpFlagsBooleans:&wantBooleans
                         outline:&wantOutline
                      centerline:&wantCenterline];
  if (wantBooleans != self.toolbarShowsBooleans ||
      wantOutline != self.toolbarShowsOutline ||
      wantCenterline != self.toolbarShowsCenterline) {
    self.toolbar =
        CanvasMakeToolbar(nil, wantOutline, wantBooleans, wantCenterline);
    self.toolbarShowsBooleans = wantBooleans;
    self.toolbarShowsOutline = wantOutline;
    self.toolbarShowsCenterline = wantCenterline;
  }
  // The mini's MTKView pass is Y-flipped vs the viewer's FxPlug surface.
  self.toolbar.flipVertical = YES;
  // Scale the bar with the popover like the OSC glyphs (baseline 230pt). The
  // 0.75 factor matches the bar's on-screen weight to the viewer's (the mini
  // surface is small, so native size is proportionally too big).
  CGFloat ratio = canvas.oscSizingHeight / 230.0;
  self.toolbar.uiScale = (ratio > 0.1 ? ratio : 1.0) * 0.75;
  NSInteger tool = self.toolbarTool ?: CanvasToolbarToolCursor;
  CanvasToolbarApplyState(self.toolbar, tool, self.gridEnabled,
                          self.gridAdaptive, self.gridSnap, self.gridSpacing);

  if (self.toolbarNormPos.x >= 0 && self.toolbarNormPos.y >= 0) {
    self.toolbar.usesAnchorCenter = YES;
    self.toolbar.anchorCenter = CGPointMake(self.toolbarNormPos.x * width,
                                            self.toolbarNormPos.y * height);
  } else {
    self.toolbar.usesAnchorCenter = NO;
  }
  [self.toolbar drawInEncoder:encoder
                       device:device
                     pipeline:pipeline
                viewportWidth:width
                       height:height];
}

// View point (y-up) -> the toolbar's hit/layout space (drawable px). The render
// is Y-mirrored AND the view is y-up, so the two flips cancel: (vx*s, vy*s)
// lands directly in the bar's y-down layout rects.
- (CGPoint)_toolbarPointForViewPoint:(CGPoint)vp canvas:(KKMiniViewerView *)c {
  CGFloat s = c.window.backingScaleFactor;
  if (s <= 0)
    s = 2.0;
  return CGPointMake(vp.x * s, vp.y * s);
}

- (NSInteger)miniViewer:(KKMiniViewerView *)canvas
      toolbarTagAtPoint:(CGPoint)viewPoint {
  if (!self.toolbar)
    return 0;
  CGPoint p = [self _toolbarPointForViewPoint:viewPoint canvas:canvas];
  return [self.toolbar hitTestAtX:p.x y:p.y];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    toolbarMouseDownAtPoint:(CGPoint)viewPoint {
  if (!self.toolbar)
    return NO;
  CGPoint p = [self _toolbarPointForViewPoint:viewPoint canvas:canvas];
  NSInteger tag = [self.toolbar hitTestAtX:p.x y:p.y];
  void (^patch)(NSString *, id) = self.onPatchUIState;
  switch (tag) {
  case CanvasToolbarDragHandle: {
    self.toolbarDragging = YES;
    self.toolbarPressMouse = p;
    NSRect f = self.toolbar.toolbarFrame;
    self.toolbarPressAnchor = CGPointMake(NSMidX(f), NSMidY(f));
    return YES;
  }
  case CanvasToolbarToolCursor:
  case CanvasToolbarToolPen:
  case CanvasToolbarToolRect:
  case CanvasToolbarToolEllipse:
    self.toolbarTool = tag;
    if (patch)
      patch(@"tool", @(tag));
    break;
  case CanvasToolbarGrid:
    self.gridEnabled = !self.gridEnabled;
    if (patch)
      patch(@"gridEnabled", @(self.gridEnabled));
    break;
  case CanvasToolbarGridAdaptive:
    self.gridAdaptive = !self.gridAdaptive;
    if (patch)
      patch(@"gridAdaptive", @(self.gridAdaptive));
    break;
  case CanvasToolbarSnap:
    self.gridSnap = !self.gridSnap;
    if (patch)
      patch(@"gridSnap", @(self.gridSnap));
    break;
  case CanvasToolbarGridSpacing: {
    NSInteger next = CanvasToolbarNextGridSpacing(self.gridSpacing);
    self.gridSpacing = next;
    if (patch)
      patch(@"gridSpacing", @(next));
    break;
  }
  case CanvasToolbarPathUnion:
    [self _miniRunBooleanOp:KKBooleanOpUnion];
    break;
  case CanvasToolbarPathSubtract:
    [self _miniRunBooleanOp:KKBooleanOpSubtract];
    break;
  case CanvasToolbarPathIntersect:
    [self _miniRunBooleanOp:KKBooleanOpIntersect];
    break;
  case CanvasToolbarPathXOR:
    [self _miniRunBooleanOp:KKBooleanOpXOR];
    break;
  case CanvasToolbarPathOutline:
    [self _miniRunOutlineOp];
    break;
  case CanvasToolbarPathCenterline:
    [self _miniRunCenterlineOp];
    break;
  default:
    break;
  }
  [canvas setNeedsDisplay:YES];
  return NO;
}

// The full multi-selection (or the single primary as a fallback).
- (NSArray<NSString *> *)_miniSelectedIDs {
  if (self.selectedLayerIDs.count)
    return self.selectedLayerIDs;
  return self.selectedLayerID.length ? @[ self.selectedLayerID ] : @[];
}

// The selected layers that are actually MOVABLE in this popover scope: the
// selection minus the scope's non-selectable set (constants:
// move-lane-animated; keypose: no keypose at this time) - the SAME set the
// marquee respects. A layer manually multi-selected in the list
// (Cmd/Shift-click) is fine to keep selected but must not move or show the
// dimmed move indicator if the scope excludes it.
- (NSArray<NSString *> *)_miniMovableSelectedIDs {
  NSSet<NSString *> *nonMovable = [self penNonSelectableLayerIDs];
  if (!nonMovable.count)
    return [self _miniSelectedIDs];
  NSMutableArray<NSString *> *out = [NSMutableArray array];
  for (NSString *lid in [self _miniSelectedIDs])
    if (![nonMovable containsObject:lid])
      [out addObject:lid];
  return out;
}

- (void)_miniPathOpFlagsBooleans:(BOOL *)outBooleans
                         outline:(BOOL *)outOutline
                      centerline:(BOOL *)outCenterline {
  NSArray<NSString *> *sel = [self _miniSelectedIDs];
  NSUInteger vectorCount = 0;
  BOOL anyStroke = NO, anyFill = NO, anyImage = NO;
  for (KKBezierPath *p in self.layers) {
    if (![sel containsObject:(p.layerID ?: @"")])
      continue;
    if (p.isImage && p.imagePath.length)
      anyImage = YES; // centerline traces an image's silhouette too
    if (!p.isImage && !p.isGroup) {
      vectorCount++;
      if (p.strokeEnabled)
        anyStroke = YES;
      if (p.fillEnabled)
        anyFill = YES;
    }
  }
  *outBooleans = vectorCount >= 2;
  *outOutline = anyStroke;
  *outCenterline = anyFill || anyImage;
}

// Run an op core on a copy of the live layers and persist via onPersistLayers
// (which writes the blob + selects the result). The result becomes the mini's
// live selection so the next draw reflects it immediately.
- (void)_miniRunPathOp:
    (NSArray<NSString *> *_Nullable (^)(NSMutableArray<KKBezierPath *> *paths,
                                        NSArray<NSString *> *sel))block {
  NSMutableArray<KKBezierPath *> *paths =
      [self.layers mutableCopy] ?: [NSMutableArray array];
  NSArray<NSString *> *newSel = block(paths, [self _miniSelectedIDs]);
  if (!newSel)
    return;
  self.layers = paths;
  self.selectedLayerID = newSel.firstObject;
  self.selectedLayerIDs = newSel;
  if (self.onPersistLayers)
    self.onPersistLayers(paths, newSel.firstObject);
}

- (void)_miniRunBooleanOp:(KKBooleanOp)op {
  float aspect = (float)[self penCanvasAspect];
  [self _miniRunPathOp:^NSArray<NSString *> *(
            NSMutableArray<KKBezierPath *> *paths, NSArray<NSString *> *sel) {
    return CanvasApplyBooleanOp(paths, sel, op, aspect);
  }];
}

- (void)_miniRunOutlineOp {
  // Stroke width is px relative to the render output. Use the TRUE output px
  // captured from the full-frame feed source so the baked outline matches the
  // main render at any resolution; fall back to a 1080-tall, aspect-correct
  // reference before the first frame has been composited.
  CGFloat refW, refH;
  if (self.outputWidth > 0 && self.outputHeight > 0) {
    refW = self.outputWidth;
    refH = self.outputHeight;
  } else {
    CGFloat aspect = (self.renderHeight > 0 && self.renderWidth > 0)
                         ? self.renderWidth / self.renderHeight
                         : 16.0 / 9.0;
    refH = 1080.0;
    refW = 1080.0 * aspect;
  }
  [self _miniRunPathOp:^NSArray<NSString *> *(
            NSMutableArray<KKBezierPath *> *paths, NSArray<NSString *> *sel) {
    return CanvasApplyOutlineOp(paths, sel, refW, refH);
  }];
}

- (void)_miniRunCenterlineOp {
  CGFloat refW, refH;
  if (self.outputWidth > 0 && self.outputHeight > 0) {
    refW = self.outputWidth;
    refH = self.outputHeight;
  } else {
    CGFloat aspect = (self.renderHeight > 0 && self.renderWidth > 0)
                         ? self.renderWidth / self.renderHeight
                         : 16.0 / 9.0;
    refH = 1080.0;
    refW = 1080.0 * aspect;
  }
  [self _miniRunPathOp:^NSArray<NSString *> *(
            NSMutableArray<KKBezierPath *> *paths, NSArray<NSString *> *sel) {
    return CanvasApplyCenterlineOp(paths, sel, refW, refH);
  }];
}

// Control+letter tool shortcuts, mirroring the viewer (V=cursor, X=pen,
// B=rect, G=ellipse). charactersIgnoringModifiers gives the plain letter.
- (BOOL)miniViewer:(KKMiniViewerView *)canvas
    toolbarKeyDownChars:(NSString *)chars
              modifiers:(NSEventModifierFlags)modifiers {
  if (!(modifiers & NSEventModifierFlagControl) || chars.length == 0)
    return NO;
  NSInteger tag =
      CanvasToolbarToolTagForLetter([chars.lowercaseString characterAtIndex:0]);
  if (tag == 0)
    return NO;
  self.toolbarTool = tag;
  if (self.onPatchUIState)
    self.onPatchUIState(@"tool", @(tag));
  [canvas setNeedsDisplay:YES];
  return YES;
}

- (void)miniViewer:(KKMiniViewerView *)canvas
    toolbarDraggedToPoint:(CGPoint)viewPoint {
  if (!self.toolbarDragging)
    return;
  CGSize d = canvas.drawableSize;
  if (d.width <= 0 || d.height <= 0)
    return;
  CGPoint p = [self _toolbarPointForViewPoint:viewPoint canvas:canvas];
  CGFloat ax = self.toolbarPressAnchor.x + (p.x - self.toolbarPressMouse.x);
  CGFloat ay = self.toolbarPressAnchor.y + (p.y - self.toolbarPressMouse.y);
  // Clamp to [0,1]: a normalised component must stay >= 0 (the draw hook reads
  // {-1,-1} as "unset -> default anchor", so a negative value when the mouse
  // leaves the bottom/left edge would snap the bar back to its default).
  // KKToolbar still does the fine on-screen clamp of the centre.
  double nx = fmax(0.0, fmin(1.0, ax / d.width));
  double ny = fmax(0.0, fmin(1.0, ay / d.height));
  self.toolbarNormPos = CGPointMake(nx, ny);
  [canvas setNeedsDisplay:YES];
}

- (void)miniViewerToolbarMouseUp:(KKMiniViewerView *)canvas {
  if (!self.toolbarDragging)
    return;
  self.toolbarDragging = NO;
  if (self.onPatchUIState && self.toolbarNormPos.x >= 0)
    self.onPatchUIState(
        @"miniToolbarPos",
        @[ @(self.toolbarNormPos.x), @(self.toolbarNormPos.y) ]);
}

- (void)miniViewer:(KKMiniViewerView *)canvas toolbarHoverTag:(NSInteger)tag {
  if (!self.toolbar || self.toolbar.hoveredTag == tag)
    return;
  self.toolbar.hoveredTag = tag;
  [canvas setNeedsDisplay:YES];
}

- (NSCursor *)miniViewer:(KKMiniViewerView *)canvas
     toolbarCursorForTag:(NSInteger)tag {
  return tag == CanvasToolbarDragHandle ? KKPointMoveCursor() : nil;
}

@end
