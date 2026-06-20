/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerTimeline.h" // blob + UIState snapshots
#import "CanvasOSC_Private.h"
#import "CanvasPenController.h"
#import "Constants.h" // kParamLayerData / kParamUIState
#import <FxPlug/FxPlugSDK.h>

// Preview colours: the Position OSC red core under the grid's dark halo, so the
// guide is consistent with the other OSCs AND legible over any footage.
static const simd_float4 kPenHalo = {0.0f, 0.0f, 0.0f, 0.55f};
static const simd_float4 kPenCore = {1.0f, 0.25f, 0.25f, 1.0f};
static const simd_float4 kPenHandleLine = {1.0f, 1.0f, 1.0f, 0.85f};
static const float kPenLineHaloHalfPx = 2.3f;
static const float kPenLineCoreHalfPx = 1.2f;

static NSCursor *PenCursor(NSString *name, NSPoint hot) {
  NSBundle *bundle = [NSBundle bundleForClass:[CanvasOSC class]];
  NSImage *image = [bundle imageForResource:name];
  return image ? [[NSCursor alloc] initWithImage:image hotSpot:hot]
               : [NSCursor crosshairCursor];
}

static CanvasPenModifiers PenModsFromFx(NSUInteger m) {
  CanvasPenModifiers out = CanvasPenModNone;
  if (m & kFxModifierKey_SHIFT)
    out |= CanvasPenModShift;
  if (m & kFxModifierKey_COMMAND)
    out |= CanvasPenModCmd;
  if (m & kFxModifierKey_CONTROL)
    out |= CanvasPenModCtrl;
  return out;
}

@implementation CanvasOSC (Pen)

- (BOOL)_penToolActive {
  return [self _activeTool] == CanvasToolbarToolPen;
}

#pragma mark - Input forwarding (called by CanvasOSC+Input)

- (BOOL)_penMouseDownAtX:(double)x
                       y:(double)y
               modifiers:(NSUInteger)modifiers
                  atTime:(CMTime)time {
  return [self.penController mouseDownAtX:x y:y modifiers:PenModsFromFx(modifiers)];
}

- (void)_penMouseMovedAtX:(double)x y:(double)y {
  [self.penController mouseMovedAtX:x y:y];
}

- (void)_penMouseDraggedAtX:(double)x y:(double)y modifiers:(NSUInteger)modifiers {
  [self.penController mouseDraggedAtX:x y:y modifiers:PenModsFromFx(modifiers)];
}

- (void)_penMouseUp {
  [self.penController mouseUp];
}

- (BOOL)_penKeyDown:(unsigned short)asciiKey
          modifiers:(NSUInteger)modifiers
             atTime:(CMTime)time {
  return [self.penController keyDown:asciiKey];
}

- (void)_penConfirmIfContextLost {
  [self.penController confirmIfContextLost];
}

- (NSCursor *)_penCursorForCanvasX:(double)x y:(double)y {
  static NSCursor *pen, *close;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    pen = PenCursor(@"Pen", NSMakePoint(15, 5));
    close = PenCursor(@"PenCloseShape", NSMakePoint(10, 5));
  });
  return [self.penController cursorKindAtX:x y:y] == CanvasPenCursorClose ? close
                                                                         : pen;
}

- (void)_drawPenInProgressWithWidth:(NSInteger)width
                             height:(NSInteger)height
                   destinationImage:(FxImageTile *)destinationImage
                             atTime:(CMTime)time {
  self.penDrawDest = destinationImage;
  self.penDrawTime = time;
  [self.penController draw];
  self.penDrawDest = nil;
}

#pragma mark - CanvasPenSurface (coordinate + snap)

// render-object (Y-up) <-> CANVAS px. The coordinate helpers use FCP's OBJECT
// space (Y-down), so flip Y crossing the boundary (as in CanvasOSC+AutoSelect).
- (CGPoint)_penCanvasFromObj:(CGPoint)objYUp {
  return [self canvasPointFromObjectPoint:simd_make_float2((float)objYUp.x,
                                                           1.0f -
                                                               (float)objYUp.y)];
}

- (CGPoint)penSurfacePointFromObj:(CGPoint)objYUp {
  return [self _penCanvasFromObj:objYUp];
}

- (CGPoint)penObjFromSurfaceX:(double)x y:(double)y {
  simd_float2 fcp = [self objectPointFromCanvasPoint:CGPointMake(x, y)];
  return CGPointMake(fcp.x, 1.0f - fcp.y);
}

- (CGPoint)penSnappedObjFromSurfaceX:(double)x y:(double)y {
  CGPoint cp = [self _snapCanvasPointToGrid:CGPointMake(x, y)];
  return [self penObjFromSurfaceX:cp.x y:cp.y];
}

- (BOOL)penGridSnapping {
  return [self _gridEnabled] && [self _gridSnap];
}

- (double)penCanvasAspect {
  return [self _canvasAspect];
}

- (BOOL)penToolActive {
  return [self _penToolActive];
}

#pragma mark - CanvasPenSurface (blob)

- (KKBezierPath *)penLayerWithID:(NSString *)layerID {
  for (KKBezierPath *p in [self _snapshotPaths])
    if ([p.layerID isEqualToString:layerID])
      return p;
  return nil;
}

- (NSString *)penSelectedLayerID {
  return [self _resolvedSelectedLayerID];
}

// Action-scoped read-modify-write of the layer blob (the OSC can't READ the
// custom param, so it round-trips the inspector snapshot). When `selectID` is
// set, the selection is written in the SAME action so it undoes together.
- (void)penMutateBlob:(void (^)(NSMutableArray<KKBezierPath *> *paths))mutate
        selectLayerID:(NSString *)selectID {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!actionAPI || !setAPI)
    return;
  [actionAPI startAction:self];
  NSString *b64 = CanvasLayerBlobSnapshot();
  NSMutableArray<KKBezierPath *> *paths =
      b64.length
          ? [KKBezierPath
                pathsFromBlob:[[NSData alloc] initWithBase64EncodedString:b64
                                                                  options:0]]
          : [NSMutableArray array];
  mutate(paths);
  NSString *newBlob =
      [[KKBezierPath blobFromPaths:paths] base64EncodedStringWithOptions:0];
  KKWriteCustomParamString(setAPI, newBlob, kParamLayerData);
  NSString *newState = nil;
  if (selectID.length) {
    NSMutableDictionary *state = [[self _uiStateDict] mutableCopy];
    state[@"selectedLayerID"] = selectID;
    newState = [[NSString alloc]
        initWithData:[NSJSONSerialization dataWithJSONObject:state
                                                     options:0
                                                       error:nil]
            encoding:NSUTF8StringEncoding];
    KKWriteCustomParamString(setAPI, newState, kParamUIState);
  }
  [actionAPI endAction:self];
  CanvasSetLayerBlobSnapshot(newBlob);
  if (newState)
    CanvasSetUIStateSnapshot(newState);
}

#pragma mark - CanvasPenSurface (draw primitives)

- (void)_penHaloStroke:(const CGPoint *)pts
                 count:(NSUInteger)n
      destinationImage:(FxImageTile *)dest {
  [self drawLineStripWithPoints:pts
                          count:n
                          color:kPenHalo
                      halfWidth:kPenLineHaloHalfPx
               destinationImage:dest];
  [self drawLineStripWithPoints:pts
                          count:n
                          color:kPenCore
                      halfWidth:kPenLineCoreHalfPx
               destinationImage:dest];
}

- (void)penDrawDotAtObj:(CGPoint)objYUp
                  ghost:(BOOL)ghost
                hovered:(BOOL)hovered
                 active:(BOOL)active {
  if (!self.penDrawDest)
    return;
  self.penAnchorOSC.ghostAlpha = ghost ? 0.4f : 1.0f;
  [self.penAnchorOSC drawAtCanvasPosition:[self _penCanvasFromObj:objYUp]
                                isHovered:hovered
                                 isActive:active
                         destinationImage:self.penDrawDest
                                   atTime:self.penDrawTime];
  self.penAnchorOSC.ghostAlpha = 1.0f;
}

- (void)penDrawCurveObjPoints:(const CGPoint *)objPts count:(NSUInteger)count {
  if (!self.penDrawDest || count < 2)
    return;
  CGPoint *pts = malloc(sizeof(CGPoint) * count);
  for (NSUInteger i = 0; i < count; i++)
    pts[i] = [self _penCanvasFromObj:objPts[i]];
  [self _penHaloStroke:pts count:count destinationImage:self.penDrawDest];
  free(pts);
}

- (void)penDrawHandleFromObj:(CGPoint)aObj toObj:(CGPoint)bObj {
  if (!self.penDrawDest)
    return;
  CGPoint line[2] = {[self _penCanvasFromObj:aObj], [self _penCanvasFromObj:bObj]};
  [self drawLineStripWithPoints:line
                          count:2
                          color:kPenHandleLine
                      halfWidth:1.5f
               destinationImage:self.penDrawDest];
  [self.penHandleOSC drawAtCanvasPosition:line[1]
                                isHovered:NO
                                 isActive:NO
                         destinationImage:self.penDrawDest
                                   atTime:self.penDrawTime];
}

@end
