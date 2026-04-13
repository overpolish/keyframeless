/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC_Private.h"

NSCursor *cursorFromBundle(NSString *name, NSPoint hotSpot) {
  NSBundle *bundle = [NSBundle bundleForClass:[CanvasOSC class]];
  NSImage *image = [bundle imageForResource:name];
  if (!image)
    return [NSCursor crosshairCursor];
  return [[NSCursor alloc] initWithImage:image hotSpot:hotSpot];
}

NSUInteger selKey(NSUInteger pathIdx, NSUInteger ptIdx) {
  return pathIdx * 100000 + ptIdx;
}

@implementation CanvasOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;
    self.paths = [NSMutableArray array];
    self.activePathIndex = -1;
    self.dragIndex = -1;
    self.lastClickIndex = -1;
    self.selectedPoints = [NSMutableIndexSet indexSet];
    self.selectedPathIndices = [NSMutableIndexSet indexSet];

    self.pathPointOSC = [[KKPointOSC alloc] initWithAPIManager:apiManager];
    self.pathPointOSC.clearsOnDraw = NO;
    self.pathPointOSC.oscRadius = 5.0f;
    self.pathPointOSC.outlineWidth = 1.5f;

    self.pathHandleOSC = [[KKPointOSC alloc] initWithAPIManager:apiManager];
    self.pathHandleOSC.clearsOnDraw = NO;
    self.pathHandleOSC.oscRadius = 3.0f;
    self.pathHandleOSC.outlineWidth = 1.0f;

    self.penCursor = cursorFromBundle(@"Pen", NSMakePoint(15, 5));
    self.penCloseCursor =
        cursorFromBundle(@"PenCloseShape", NSMakePoint(10, 5));
    self.penAddCursor =
        cursorFromBundle(@"PenAddControlPoint", NSMakePoint(10, 5));
    self.moveCursor = cursorFromBundle(@"Move", NSMakePoint(8, 7));
    self.editPointsCursor = cursorFromBundle(@"EditPoints", NSMakePoint(11, 8));
    self.penDeleteCursor = cursorFromBundle(@"PenX", NSMakePoint(15, 5));

    self.toolbar = [[KKToolbar alloc]
        initWithAPIManager:apiManager
                     items:@[
                       [KKToolbarItem itemWithIcon:@"cursorarrow"
                                               tag:kOSCToolbarCursor],
                       [KKToolbarItem itemWithIcon:@"pencil.and.outline"
                                               tag:kOSCToolbarPen],
                       [KKToolbarItem itemWithIcon:@"rectangle.fill"
                                               tag:kOSCToolbarRect],
                       [KKToolbarItem itemWithIcon:@"circle.fill"
                                               tag:kOSCToolbarEllipse],
                       [KKToolbarItem itemWithIcon:@"line.diagonal"
                                               tag:kOSCToolbarLine],
                     ]];
    self.toolbar.activeTag = kOSCToolbarCursor;

    self.sizeLabel = [[KKOSCLabel alloc] initWithAPIManager:apiManager];
    self.sizeLabel.monospaced = YES;

    self.borderOSC = [[KKRectBorderOSC alloc] initWithAPIManager:apiManager];
    self.borderOSC.clearsOnDraw = NO;
    NSMutableArray *handles = [NSMutableArray arrayWithCapacity:8];
    for (int i = 0; i < 8; i++) {
      KKPointOSC *h = [[KKPointOSC alloc] initWithAPIManager:apiManager];
      h.clearsOnDraw = NO;
      h.oscRadius = 5.0f;
      h.outlineWidth = 1.5f;
      [handles addObject:h];
    }
    self.resizeHandleOSCs = handles;
    self.dragResizeHandle = -1;
  }
  return self;
}

- (CGPoint)oscPositionAtTime:(CMTime)time {
  return CGPointZero;
}

- (KKBezierPath *)activePath {
  if (self.activePathIndex >= 0 &&
      self.activePathIndex < (NSInteger)self.paths.count)
    return self.paths[self.activePathIndex];
  return nil;
}

- (CGPoint)canvasPointForBezierPoint:(KKBezierPoint)pt {
  return [self canvasPointFromObjectPoint:(simd_float2){pt.x, pt.y}];
}

- (CGPoint)canvasPointForBezierPoint:(KKBezierPoint)pt
                      inHandleOffset:(BOOL)useIn {
  if (useIn)
    return [self
        canvasPointFromObjectPoint:(simd_float2){pt.x + pt.inX, pt.y + pt.inY}];
  return [self
      canvasPointFromObjectPoint:(simd_float2){pt.x + pt.outX, pt.y + pt.outY}];
}

- (BOOL)isPointSelected:(NSUInteger)pathIdx point:(NSUInteger)ptIdx {
  return [self.selectedPoints containsIndex:selKey(pathIdx, ptIdx)];
}

- (double)strokeWidth {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  double width = 8.0;
  [paramGetAPI getFloatValue:&width
               fromParameter:kParamStrokeWidth
                      atTime:kCMTimeZero];
  return width;
}

- (double)strokeHitRadius {
  return MAX([self strokeWidth] * 0.5 + 4.0, 12.0);
}

- (NSInteger)pathIndexNearX:(double)x y:(double)y radius:(double)radius {
  for (NSUInteger p = 0; p < self.paths.count; p++) {
    KKBezierPath *path = self.paths[p];
    NSUInteger segCount = path.count - 1;
    if (path.closed && path.count >= 2)
      segCount = path.count;
    for (NSUInteger c = 0; c < segCount; c++) {
      NSUInteger nextIdx = (c + 1) % path.count;
      for (NSUInteger s = 0; s <= 64; s++) {
        float t = (float)s / 64.0f;
        simd_float2 pos = [path evaluatePointAtIndex:c nextIndex:nextIdx atT:t];
        CGPoint cur = [self canvasPointFromObjectPoint:pos];
        if (hypot(x - cur.x, y - cur.y) < radius)
          return (NSInteger)p;
      }
    }
  }
  return -1;
}

- (NSInteger)segmentIndexNearX:(double)x
                             y:(double)y
                        radius:(double)radius
                        inPath:(KKBezierPath *)path {
  if (!path || path.count < 2)
    return -1;
  NSUInteger segCount = path.count - 1;
  if (path.closed && path.count >= 2)
    segCount = path.count;
  for (NSUInteger c = 0; c < segCount; c++) {
    NSUInteger nextIdx = (c + 1) % path.count;
    for (NSUInteger s = 0; s <= 64; s++) {
      float t = (float)s / 64.0f;
      simd_float2 pos = [path evaluatePointAtIndex:c nextIndex:nextIdx atT:t];
      CGPoint cur = [self canvasPointFromObjectPoint:pos];
      if (hypot(x - cur.x, y - cur.y) < radius)
        return (NSInteger)c;
    }
  }
  return -1;
}

- (NSMutableArray<KKBezierPath *> *)readPaths {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSString *str = nil;
  [paramGetAPI getStringParameterValue:&str fromParameter:kParamPathData];
  if (str.length == 0)
    return [NSMutableArray array];
  NSData *blob = [[NSData alloc] initWithBase64EncodedString:str options:0];
  return [KKBezierPath pathsFromBlob:blob];
}

- (void)writePaths:(NSArray<KKBezierPath *> *)paths {
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSData *blob = [KKBezierPath blobFromPaths:paths];
  NSString *str = [blob base64EncodedStringWithOptions:0];
  [paramSetAPI setStringParameterValue:str toParameter:kParamPathData];
}

- (void)boundsOfPath:(KKBezierPath *)path
                 min:(simd_float2 *)outMin
                 max:(simd_float2 *)outMax {
  if (path.count == 0)
    return;
  KKBezierPoint p0 = [path pointAtIndex:0];
  float minX = p0.x, minY = p0.y, maxX = p0.x, maxY = p0.y;
  for (NSUInteger i = 1; i < path.count; i++) {
    KKBezierPoint p = [path pointAtIndex:i];
    minX = fminf(minX, p.x);
    minY = fminf(minY, p.y);
    maxX = fmaxf(maxX, p.x);
    maxY = fmaxf(maxY, p.y);
  }
  *outMin = (simd_float2){minX, minY};
  *outMax = (simd_float2){maxX, maxY};
}

- (BOOL)boundsOfSelectedPaths:(simd_float2 *)outMin max:(simd_float2 *)outMax {
  __block BOOL found = NO;
  __block float minX, minY, maxX, maxY;
  [self.selectedPathIndices
      enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
        if (idx >= self.paths.count)
          return;
        KKBezierPath *path = self.paths[idx];
        if (path.count == 0)
          return;
        simd_float2 pMin, pMax;
        [self boundsOfPath:path min:&pMin max:&pMax];
        if (!found) {
          minX = pMin.x;
          minY = pMin.y;
          maxX = pMax.x;
          maxY = pMax.y;
          found = YES;
        } else {
          minX = fminf(minX, pMin.x);
          minY = fminf(minY, pMin.y);
          maxX = fmaxf(maxX, pMax.x);
          maxY = fmaxf(maxY, pMax.y);
        }
      }];
  if (found) {
    *outMin = (simd_float2){minX, minY};
    *outMax = (simd_float2){maxX, maxY};
  }
  return found;
}

- (CGPoint)cornerRadiusHandlePosition:(NSInteger)corner
                              forPath:(KKBezierPath *)path {
  simd_float2 bmin, bmax;
  [self boundsOfPath:path min:&bmin max:&bmax];
  CGPoint minC = [self canvasPointFromObjectPoint:bmin];
  CGPoint maxC = [self canvasPointFromObjectPoint:bmax];
  float inset = (float)[self strokeWidth] * 0.5f + 20.0f;
  float halfShort =
      fminf((float)fabs(maxC.x - minC.x), (float)fabs(maxC.y - minC.y)) * 0.5f;
  float travel = fminf(100.0f, fmaxf(0.0f, halfShort - inset));

  float fracs[4] = {path.cornerRadiusTL, path.cornerRadiusTR,
                    path.cornerRadiusBR, path.cornerRadiusBL};
  float f = fracs[corner];
  float offset = inset + f * travel;

  // Each corner offsets inward from its respective corner
  // Canvas Y increases upward
  switch (corner) {
  case 0: // TL: corner at (minX, maxY), inward = +X, -Y
    return (CGPoint){minC.x + offset, maxC.y - offset};
  case 1: // TR: corner at (maxX, maxY), inward = -X, -Y
    return (CGPoint){maxC.x - offset, maxC.y - offset};
  case 2: // BR: corner at (maxX, minY), inward = -X, +Y
    return (CGPoint){maxC.x - offset, minC.y + offset};
  case 3: // BL: corner at (minX, minY), inward = +X, +Y
    return (CGPoint){minC.x + offset, minC.y + offset};
  default:
    return CGPointZero;
  }
}

- (CGPoint)resizeHandlePosition:(NSInteger)index
                       topRight:(CGPoint)tr
                     bottomLeft:(CGPoint)bl {
  double mx = (tr.x + bl.x) * 0.5;
  double my = (tr.y + bl.y) * 0.5;
  switch (index) {
  case 0:
    return (CGPoint){bl.x, tr.y}; // TL
  case 1:
    return (CGPoint){mx, tr.y}; // TC
  case 2:
    return (CGPoint){tr.x, tr.y}; // TR
  case 3:
    return (CGPoint){tr.x, my}; // RC
  case 4:
    return (CGPoint){tr.x, bl.y}; // BR
  case 5:
    return (CGPoint){mx, bl.y}; // BC
  case 6:
    return (CGPoint){bl.x, bl.y}; // BL
  case 7:
    return (CGPoint){bl.x, my}; // LC
  default:
    return CGPointZero;
  }
}

@end
