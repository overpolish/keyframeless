/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasMiniViewerRenderer_Internal.h"
#import "CanvasToolbar.h" // CanvasToolbarToolPen
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKBezierPath.h>

static CanvasPenModifiers PenModsFromNS(NSEventModifierFlags m) {
  CanvasPenModifiers o = CanvasPenModNone;
  if (m & NSEventModifierFlagShift)
    o |= CanvasPenModShift;
  if (m & NSEventModifierFlagCommand)
    o |= CanvasPenModCmd;
  if (m & NSEventModifierFlagControl)
    o |= CanvasPenModCtrl;
  return o;
}

// Pen cursors from the plugin bundle's flattened Resources (same assets + hot
// spots as the viewer).
static NSCursor *MiniPenCursor(NSString *name, NSPoint hot) {
  NSBundle *bundle = [NSBundle bundleForClass:[CanvasMiniViewerRenderer class]];
  NSImage *image = [bundle imageForResource:name];
  return image ? [[NSCursor alloc] initWithImage:image hotSpot:hot]
               : [NSCursor crosshairCursor];
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
  [self.penController mouseDownAtX:point.x y:point.y modifiers:PenModsFromNS(mods)];
}

- (void)miniViewer:(KKMiniViewerView *)canvas
    toolDraggedToPoint:(CGPoint)point
           contentRect:(CGRect)cr
             modifiers:(NSEventModifierFlags)mods {
  self.penContentRect = cr;
  [self.penController mouseDraggedAtX:point.x
                                   y:point.y
                           modifiers:PenModsFromNS(mods)];
}

- (void)miniViewer:(KKMiniViewerView *)canvas
     toolUpAtPoint:(CGPoint)point
       contentRect:(CGRect)cr {
  self.penContentRect = cr;
  [self.penController mouseUp];
}

- (void)miniViewer:(KKMiniViewerView *)canvas
    toolMovedToPoint:(CGPoint)point
         contentRect:(CGRect)cr {
  self.penContentRect = cr;
  [self.penController mouseMovedAtX:point.x y:point.y];
}

- (BOOL)miniViewer:(KKMiniViewerView *)canvas toolKeyDown:(unsigned short)key {
  return [self.penController keyDown:key];
}

- (NSCursor *)miniViewer:(KKMiniViewerView *)canvas
       toolCursorAtPoint:(CGPoint)point
             contentRect:(CGRect)cr {
  static NSCursor *pen, *close;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    pen = MiniPenCursor(@"Pen", NSMakePoint(15, 5));
    close = MiniPenCursor(@"PenCloseShape", NSMakePoint(10, 5));
  });
  self.penContentRect = cr;
  return [self.penController cursorKindAtX:point.x y:point.y] ==
                 CanvasPenCursorClose
             ? close
             : pen;
}

- (void)miniViewerDrawToolOverlay:(KKMiniViewerView *)canvas
                      contentRect:(CGRect)cr {
  self.penContentRect = cr;
  self.penDrawCanvas = canvas;
  [self.penController confirmIfContextLost]; // tool / layer switch finalises
  [self.penController draw];
  self.penDrawCanvas = nil;
}

#pragma mark - CanvasPenSurface (coords)

// Position space is Y-DOWN (0 = top); KKBezierPath points are Y-UP - flip Y.
- (CGPoint)penObjFromSurfaceX:(double)x y:(double)y {
  simd_float2 m = [self _memberValueForViewPoint:CGPointMake(x, y)
                                     contentRect:self.penContentRect];
  return CGPointMake(m.x, 1.0 - m.y);
}

- (CGPoint)penSnappedObjFromSurfaceX:(double)x y:(double)y {
  simd_float2 m = [self _memberValueForViewPoint:CGPointMake(x, y)
                                     contentRect:self.penContentRect];
  simd_float2 sn = [self _snapNormalizedPointToGrid:m
                                        contentRect:self.penContentRect];
  return CGPointMake(sn.x, 1.0 - sn.y);
}

- (CGPoint)penSurfacePointFromObj:(CGPoint)objYUp {
  return [self handlePointForContentRect:self.penContentRect
                                position:@[ @(objYUp.x), @(1.0 - objYUp.y) ]];
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
  self.layers = paths; // immediate so penLayerWithID sees it on the next draw/click
  if (self.onPersistLayers)
    self.onPersistLayers(paths, selectID);
}

#pragma mark - CanvasPenSurface (draw primitives, Metal pass - match motion path)

// Anchor dots: white glyphs at the motion-path's anchor size (0.6). The ghost
// (next-point preview) is the same glyph dimmed. Uniform size - no grow on
// hover/active, so it reads the same as the path OSC.
- (void)penDrawDotAtObj:(CGPoint)objYUp
                  ghost:(BOOL)ghost
                hovered:(BOOL)hovered
                 active:(BOOL)active {
  simd_float4 white = {1.0f, 1.0f, 1.0f, ghost ? 0.4f : 1.0f};
  [self.penDrawCanvas encodeToolDotAtPoint:[self penSurfacePointFromObj:objYUp]
                                      fill:white
                                 sizeScale:0.6];
}

- (void)penDrawCurveObjPoints:(const CGPoint *)objPts count:(NSUInteger)count {
  if (count < 2)
    return;
  NSMutableArray<NSValue *> *pts = [NSMutableArray arrayWithCapacity:count];
  for (NSUInteger i = 0; i < count; i++)
    [pts addObject:[NSValue valueWithPoint:[self penSurfacePointFromObj:objPts[i]]]];
  simd_float4 red = {1.0f, 0.25f, 0.25f, 0.9f}; // matches the motion path
  [self.penDrawCanvas encodeToolLineStrip:pts color:red halfWidthPt:1.0];
}

- (void)penDrawHandleFromObj:(CGPoint)aObj toObj:(CGPoint)bObj {
  CGPoint a = [self penSurfacePointFromObj:aObj];
  CGPoint b = [self penSurfacePointFromObj:bObj];
  simd_float4 white = {1.0f, 1.0f, 1.0f, 0.85f};
  [self.penDrawCanvas
      encodeToolLineStrip:@[ [NSValue valueWithPoint:a], [NSValue valueWithPoint:b] ]
                    color:white
              halfWidthPt:0.75]; // matches the motion path's tangent segments
  simd_float4 dot = {1.0f, 1.0f, 1.0f, 1.0f};
  [self.penDrawCanvas encodeToolDotAtPoint:b fill:dot sizeScale:0.5];
}

@end
