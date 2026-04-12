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
                       [KKToolbarItem itemWithIcon:@"rectangle"
                                               tag:kOSCToolbarRect],
                     ]];
    self.toolbar.activeTag = kOSCToolbarPen;

    self.sizeLabel = [[KKOSCLabel alloc] initWithAPIManager:apiManager];
    self.sizeLabel.monospaced = YES;
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
    if (path.closed && path.count >= 3)
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
  if (path.closed && path.count >= 3)
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
  if (!blob || blob.length < 4)
    return [NSMutableArray array];

  const uint8_t *bytes = blob.bytes;
  NSUInteger offset = 0;
  uint32_t pathCount;
  memcpy(&pathCount, bytes + offset, 4);
  offset += 4;

  if (pathCount > 10000 || offset + pathCount * 4 > blob.length) {
    KKBezierPath *single = [KKBezierPath pathWithData:blob];
    if (single && single.count > 0)
      return [NSMutableArray arrayWithObject:single];
    return [NSMutableArray array];
  }

  NSMutableArray *result = [NSMutableArray arrayWithCapacity:pathCount];
  for (uint32_t i = 0; i < pathCount; i++) {
    if (offset + 4 > blob.length)
      break;
    uint32_t len;
    memcpy(&len, bytes + offset, 4);
    offset += 4;
    if (offset + len > blob.length)
      break;
    NSData *pathData = [blob subdataWithRange:NSMakeRange(offset, len)];
    KKBezierPath *path = [KKBezierPath pathWithData:pathData];
    if (path)
      [result addObject:path];
    offset += len;
  }
  return result;
}

- (void)writePaths:(NSArray<KKBezierPath *> *)paths {
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSMutableData *blob = [NSMutableData data];
  uint32_t pathCount = (uint32_t)paths.count;
  [blob appendBytes:&pathCount length:4];
  for (KKBezierPath *path in paths) {
    NSData *pathData = [path dataRepresentation];
    uint32_t len = (uint32_t)pathData.length;
    [blob appendBytes:&len length:4];
    [blob appendData:pathData];
  }
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

- (CGPoint)cornerRadiusHandlePositionForPath:(KKBezierPath *)path {
  simd_float2 min, max;
  [self boundsOfPath:path min:&min max:&max];
  // Work in canvas space for correct aspect ratio
  CGPoint cornerCanvas =
      [self canvasPointFromObjectPoint:(simd_float2){max.x, max.y}];
  float r = path.cornerRadius;
  if (r < 0.0001f) {
    // At zero radius, offset inside the rect with padding
    // Canvas Y increases upward, so -Y moves inward (down on screen)
    float inset = (float)[self strokeWidth] * 0.5f + 20.0f;
    return (CGPoint){cornerCanvas.x - inset, cornerCanvas.y - inset};
  }
  // Compute pixel radius from object-space ry
  CGPoint minCanvas = [self canvasPointFromObjectPoint:min];
  CGPoint maxCanvas = [self canvasPointFromObjectPoint:max];
  float canvasH = (float)fabs(maxCanvas.y - minCanvas.y);
  float objH = max.y - min.y;
  float pixelR = (objH > 0.0001f) ? (r / objH) * canvasH : 0;
  float insetPx = (float)[self strokeWidth] * 0.5f + 20.0f;
  float diag = pixelR * 0.7071067812f + insetPx;
  // Inward from top-right: -X and -Y in canvas coords
  return (CGPoint){cornerCanvas.x - diag, cornerCanvas.y - diag};
}

@end
