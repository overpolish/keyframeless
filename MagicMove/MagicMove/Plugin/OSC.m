/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC.h"
#import "Constants.h"
#import <CoreGraphics/CGEventSource.h>
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKBezierPath.h>

@interface KKArcOSC (FxOSC) <FxOnScreenControl_v4>
@end

#define CLAMP(x, lo, hi) MAX((lo), MIN((hi), (x)))
#define kPointCount 4

static const float kSnapThreshold = 8.0f;
static const float kPathHitThreshold = 10.0f;
static const float kPathPointHitRadius = 8.0f;
static const NSUInteger kPathDrawResolution = 20;

// Returns the parametric t of the intersection between line (from→to) and a
// circle (center, radius).  fromInside == YES means `from` is inside the circle
// (we want the exit t), otherwise `from` is outside (we want the entry t).
static double circleClipT(CGPoint from, CGPoint to, CGPoint center,
                          double radius, BOOL fromInside) {
  double dx = to.x - from.x, dy = to.y - from.y;
  double wx = from.x - center.x, wy = from.y - center.y;
  double a = dx * dx + dy * dy;
  if (a < 1e-12)
    return fromInside ? 1.0 : 0.0;
  double b = 2.0 * (wx * dx + wy * dy);
  double c = wx * wx + wy * wy - radius * radius;
  double disc = b * b - 4.0 * a * c;
  if (disc < 0.0)
    return fromInside ? 1.0 : 0.0;
  double sqrtDisc = sqrt(disc);
  double t =
      fromInside ? (-b + sqrtDisc) / (2.0 * a) : (-b - sqrtDisc) / (2.0 * a);
  return fmax(0.0, fmin(1.0, t));
}

// Path segment config — each A→B, B→Drift, etc. is a segment
typedef struct {
  UInt32 pathParam;
  UInt32 startParam;
  UInt32 endParam;
  NSInteger pathIndex; // 0-3, multiplied by 1000 for part IDs
} PathSegConfig;

// Part ID encoding: pathIndex * 1000 + offset
// offset 50 = curve, 100+i = point, 200+i = inHandle, 300+i = outHandle
static NSInteger pathPartCurve(NSInteger idx) { return idx * 1000 + 50; }
static NSInteger pathPartPoint(NSInteger idx, NSUInteger i) {
  return idx * 1000 + 100 + (NSInteger)i;
}
static NSInteger pathPartInHandle(NSInteger idx, NSUInteger i) {
  return idx * 1000 + 200 + (NSInteger)i;
}
static NSInteger pathPartOutHandle(NSInteger idx, NSUInteger i) {
  return idx * 1000 + 300 + (NSInteger)i;
}
static BOOL isPathPart(NSInteger part) { return part >= 50; }
static NSInteger pathIndexFromPart(NSInteger part) { return part / 1000; }
static NSInteger pathPartOffset(NSInteger part) { return part % 1000; }

@implementation MagicMoveOSC {
  KKCompoundPointOSC *_points[kPointCount];
  KKSnapEngine *_pointSnap;
  KKSnapEngine *_pathSnap;
  KKPointOSC *_pathPointOSC;
  KKPointOSC *_pathHandleOSC;
  NSInteger _pathDragIndex;
  BOOL _pathDragIsInHandle;
  BOOL _pathDragIsOutHandle;
  simd_float2 _pathDragStartObj;
  UInt32 _pathActiveParam;
  NSTimeInterval _pathLastClickTime;
  NSInteger _pathLastClickIndex;
}

static KKCompoundPointOSC *
makePoint(id<PROAPIAccessing> api, NSString *label, KKArcOSC *primaryArc,
          UInt32 pointP, UInt32 rotP, UInt32 sxP, UInt32 syP, UInt32 prevP,
          UInt32 opP, NSInteger arcPt, NSInteger ringPt, NSInteger rotPt,
          NSInteger iconPt, NSInteger opIconPt, NSInteger scIconPt) {
  KKCompoundPointOSC *p =
      [[KKCompoundPointOSC alloc] initWithAPIManager:api
                                           labelText:label
                                          primaryArc:primaryArc];
  p.pointParam = pointP;
  p.rotParam = rotP;
  p.scaleXParam = sxP;
  p.scaleYParam = syP;
  p.previewParam = prevP;
  p.opacityParam = opP;
  p.arcPart = arcPt;
  p.ringPart = ringPt;
  p.rotPart = rotPt;
  p.iconPart = iconPt;
  p.opacityIconPart = opIconPt;
  p.scaleIconPart = scIconPt;
  return p;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;

    _points[0] = makePoint(apiManager, @"Point A", self, kParamPointA,
                           kParamRotationA, kParamScaleA, kParamScaleYA,
                           kParamPreviewA, kParamOpacityA, 1, 2, 3, 13, 17, 21);
    _points[1] = makePoint(apiManager, @"Point B", nil, kParamPointB,
                           kParamRotationB, kParamScaleB, kParamScaleYB,
                           kParamPreviewB, kParamOpacityB, 4, 5, 6, 14, 18, 22);
    _points[2] =
        makePoint(apiManager, @"Drift", nil, kParamDriftPoint,
                  kParamDriftRotation, kParamDriftScale, kParamDriftScaleY,
                  kParamPreviewDrift, kParamDriftOpacity, 7, 8, 9, 15, 19, 23);
    _points[3] =
        makePoint(apiManager, @"Exit", nil, kParamExitPoint, kParamExitRotation,
                  kParamExitScale, kParamExitScaleY, kParamPreviewExit,
                  kParamExitOpacity, 10, 11, 12, 16, 20, 24);

    _pathPointOSC = [[KKPointOSC alloc] initWithAPIManager:apiManager];
    _pathPointOSC.clearsOnDraw = NO;
    _pathPointOSC.oscRadius = 5.0f;
    _pathPointOSC.outlineWidth = 1.5f;
    _pathHandleOSC = [[KKPointOSC alloc] initWithAPIManager:apiManager];
    _pathHandleOSC.clearsOnDraw = NO;
    _pathHandleOSC.oscRadius = 3.0f;
    _pathHandleOSC.outlineWidth = 1.0f;
    _pathDragIndex = -1;
    _pathLastClickIndex = -1;
    _pointSnap = [[KKSnapEngine alloc] init];
    _pathSnap = [[KKSnapEngine alloc] init];
  }
  return self;
}

- (BOOL)animateInEnabledAtTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL enabled = NO;
  [paramGetAPI getBoolValue:&enabled
              fromParameter:kKKParamAnimateIn
                     atTime:time];
  return enabled;
}

- (BOOL)animateOutEnabledAtTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL enabled = NO;
  [paramGetAPI getBoolValue:&enabled
              fromParameter:kKKParamAnimateOut
                     atTime:time];
  return enabled;
}

- (BOOL)driftEnabledAtTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL enabled = NO;
  [paramGetAPI getBoolValue:&enabled fromParameter:kParamDrift atTime:time];
  return enabled;
}

- (BOOL)exitEnabledAtTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL enabled = NO;
  [paramGetAPI getBoolValue:&enabled fromParameter:kParamExit atTime:time];
  return enabled;
}

- (CGPoint)oscPositionAtTime:(CMTime)time {
  return [self canvasPositionForParam:kParamPointA atTime:time];
}

- (KKBezierPath *)readPathParam:(UInt32)paramID {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSString *str = nil;
  [paramGetAPI getStringParameterValue:&str fromParameter:paramID];
  if (str.length > 0) {
    NSData *data = [[NSData alloc] initWithBase64EncodedString:str options:0];
    if (data)
      return [KKBezierPath pathWithData:data];
  }
  return [[KKBezierPath alloc] init];
}

- (void)writePathParam:(UInt32)paramID path:(KKBezierPath *)path {
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSData *data = [path dataRepresentation];
  NSString *str = [data base64EncodedStringWithOptions:0];
  [paramSetAPI setStringParameterValue:str toParameter:paramID];
}

- (void)drawPathSegment:(PathSegConfig)cfg
       destinationImage:(FxImageTile *)dest
                  color:(simd_float4)color
             startInset:(double)startInset
               endInset:(double)endInset
                 atTime:(CMTime)time {
  KKBezierPath *path = [self readPathParam:cfg.pathParam];
  simd_float2 startObj = [self objectPositionForParam:cfg.startParam
                                               atTime:time];
  simd_float2 endObj = [self objectPositionForParam:cfg.endParam atTime:time];
  NSUInteger segCount = path.segmentCount;
  CGPoint startCanvas = [self canvasPointFromObjectPoint:startObj];
  CGPoint endCanvas = [self canvasPointFromObjectPoint:endObj];

  // Draw curve segments, clipping against endpoint inset circles
  for (NSUInteger seg = 0; seg < segCount; seg++) {
    CGPoint prev = CGPointZero;
    double d1p = 0, d2p = 0;
    for (NSUInteger s = 0; s <= kPathDrawResolution; s++) {
      float localT = (float)s / (float)kPathDrawResolution;
      simd_float2 objPt = [path evaluateSegment:seg
                                            atT:localT
                                          start:startObj
                                            end:endObj];
      CGPoint cur = [self canvasPointFromObjectPoint:objPt];
      double d1 = hypot(cur.x - startCanvas.x, cur.y - startCanvas.y);
      double d2 = hypot(cur.x - endCanvas.x, cur.y - endCanvas.y);
      if (s > 0) {
        BOOL curInStart = d1 < startInset, prevInStart = d1p < startInset;
        BOOL curInEnd = d2 < endInset, prevInEnd = d2p < endInset;
        double tMin = 0.0, tMax = 1.0;
        BOOL skip = NO;

        if (curInStart && prevInStart) {
          skip = YES;
        } else if (prevInStart) {
          tMin =
              fmax(tMin, circleClipT(prev, cur, startCanvas, startInset, YES));
        } else if (curInStart) {
          tMax =
              fmin(tMax, circleClipT(prev, cur, startCanvas, startInset, NO));
        }

        if (!skip) {
          if (curInEnd && prevInEnd) {
            skip = YES;
          } else if (prevInEnd) {
            tMin = fmax(tMin, circleClipT(prev, cur, endCanvas, endInset, YES));
          } else if (curInEnd) {
            tMax = fmin(tMax, circleClipT(prev, cur, endCanvas, endInset, NO));
          }
        }

        if (!skip && tMin < tMax) {
          CGPoint drawFrom = CGPointMake(prev.x + tMin * (cur.x - prev.x),
                                         prev.y + tMin * (cur.y - prev.y));
          CGPoint drawTo = CGPointMake(prev.x + tMax * (cur.x - prev.x),
                                       prev.y + tMax * (cur.y - prev.y));
          [self drawLineFrom:drawFrom
                            to:drawTo
                         color:color
                     halfWidth:2.0f
              destinationImage:dest];
        }
      }
      prev = cur;
      d1p = d1;
      d2p = d2;
    }
  }

  // Draw control points and handles
  for (NSUInteger i = 0; i < path.count; i++) {
    KKBezierPoint pt = [path pointAtIndex:i];
    simd_float2 ptObj = {pt.x, pt.y};
    CGPoint ptCanvas = [self canvasPointFromObjectPoint:ptObj];

    if (pt.type == KKBezierPointBezier) {
      simd_float2 inObj = {pt.x + pt.inX, pt.y + pt.inY};
      simd_float2 outObj = {pt.x + pt.outX, pt.y + pt.outY};
      CGPoint inCanvas = [self canvasPointFromObjectPoint:inObj];
      CGPoint outCanvas = [self canvasPointFromObjectPoint:outObj];

      simd_float4 handleColor = {1.0f, 0.0f, 0.0f, 0.33f};
      [self drawLineFrom:ptCanvas
                        to:inCanvas
                     color:handleColor
                 halfWidth:2.0f
          destinationImage:dest];
      [self drawLineFrom:ptCanvas
                        to:outCanvas
                     color:handleColor
                 halfWidth:2.0f
          destinationImage:dest];

      [_pathHandleOSC drawAtCanvasPosition:inCanvas
                                 isHovered:NO
                                  isActive:NO
                          destinationImage:dest
                                    atTime:time];
      [_pathHandleOSC drawAtCanvasPosition:outCanvas
                                 isHovered:NO
                                  isActive:NO
                          destinationImage:dest
                                    atTime:time];
    }

    [_pathPointOSC
        drawAtCanvasPosition:ptCanvas
                   isHovered:NO
                    isActive:(_pathDragIndex == (NSInteger)i &&
                              !_pathDragIsInHandle && !_pathDragIsOutHandle)
            destinationImage:dest
                      atTime:time];
  }
}

- (BOOL)hitTestPathSegment:(PathSegConfig)cfg
                         x:(double)mx
                         y:(double)my
                activePart:(NSInteger *)activePart
                   optDown:(BOOL)optDown
                    oscAPI:(id<FxOnScreenControlAPI_v4>)oscAPI
                    atTime:(CMTime)time {
  KKBezierPath *path = [self readPathParam:cfg.pathParam];
  simd_float2 startObj = [self objectPositionForParam:cfg.startParam
                                               atTime:time];
  simd_float2 endObj = [self objectPositionForParam:cfg.endParam atTime:time];
  NSInteger pi = cfg.pathIndex;

  // Test handles
  for (NSUInteger i = 0; i < path.count; i++) {
    KKBezierPoint pt = [path pointAtIndex:i];
    if (pt.type != KKBezierPointBezier)
      continue;
    CGPoint inC = [self
        canvasPointFromObjectPoint:(simd_float2){pt.x + pt.inX, pt.y + pt.inY}];
    CGPoint outC =
        [self canvasPointFromObjectPoint:(simd_float2){pt.x + pt.outX,
                                                       pt.y + pt.outY}];
    if (hypot(mx - inC.x, my - inC.y) < kPathPointHitRadius) {
      *activePart = pathPartInHandle(pi, i);
      return YES;
    }
    if (hypot(mx - outC.x, my - outC.y) < kPathPointHitRadius) {
      *activePart = pathPartOutHandle(pi, i);
      return YES;
    }
  }

  // Test control points
  for (NSUInteger i = 0; i < path.count; i++) {
    KKBezierPoint pt = [path pointAtIndex:i];
    CGPoint ptC = [self canvasPointFromObjectPoint:(simd_float2){pt.x, pt.y}];
    if (hypot(mx - ptC.x, my - ptC.y) < kPathPointHitRadius) {
      *activePart = pathPartPoint(pi, i);
      [oscAPI setCursor:optDown ? [NSCursor disappearingItemCursor]
                                : [NSCursor arrowCursor]];
      return YES;
    }
  }

  // Test curve
  NSUInteger segCount = path.segmentCount;
  float bestDist = FLT_MAX;
  for (NSUInteger seg = 0; seg < segCount; seg++) {
    CGPoint prev = CGPointZero;
    for (NSUInteger s = 0; s <= kPathDrawResolution; s++) {
      float localT = (float)s / (float)kPathDrawResolution;
      simd_float2 objPt = [path evaluateSegment:seg
                                            atT:localT
                                          start:startObj
                                            end:endObj];
      CGPoint cur = [self canvasPointFromObjectPoint:objPt];
      if (s > 0) {
        double dx = cur.x - prev.x, dy = cur.y - prev.y;
        double lenSq = dx * dx + dy * dy;
        double t2 =
            (lenSq > 0)
                ? CLAMP(((mx - prev.x) * dx + (my - prev.y) * dy) / lenSq, 0, 1)
                : 0;
        double cx = prev.x + t2 * dx, cy = prev.y + t2 * dy;
        float dist = (float)hypot(mx - cx, my - cy);
        if (dist < bestDist)
          bestDist = dist;
      }
      prev = cur;
    }
  }
  if (bestDist < kPathHitThreshold) {
    *activePart = pathPartCurve(pi);
    [oscAPI setCursor:optDown ? [NSCursor crosshairCursor]
                              : [NSCursor arrowCursor]];
    return YES;
  }

  return NO;
}

- (PathSegConfig)configForPathIndex:(NSInteger)pi {
  switch (pi) {
  case 1:
    return (PathSegConfig){kParamPathBDrift, kParamPointB, kParamDriftPoint, 1};
  case 2:
    return (PathSegConfig){kParamPathDriftExit, kParamDriftPoint,
                           kParamExitPoint, 2};
  case 3:
    return (PathSegConfig){kParamPathBExit, kParamPointB, kParamExitPoint, 3};
  case 4:
    return (PathSegConfig){kParamPathDriftA, kParamDriftPoint, kParamPointA, 4};
  default:
    return (PathSegConfig){kParamPathAB, kParamPointA, kParamPointB, 0};
  }
}

- (BOOL)mouseDownForPathWithPart:(NSInteger)activePart
                       positionX:(double)positionX
                       positionY:(double)positionY
                       modifiers:(NSUInteger)modifiers
                     forceUpdate:(BOOL *)forceUpdate
                          atTime:(CMTime)time {
  if (!isPathPart(activePart))
    return NO;

  BOOL optHeld = (modifiers & kFxModifierKey_OPTION) != 0;
  NSInteger pi = pathIndexFromPart(activePart);
  NSInteger offset = pathPartOffset(activePart);
  PathSegConfig cfg = [self configForPathIndex:pi];
  _pathActiveParam = cfg.pathParam;

  simd_float2 startObj = [self objectPositionForParam:cfg.startParam
                                               atTime:time];
  simd_float2 endObj = [self objectPositionForParam:cfg.endParam atTime:time];

  if (offset >= 100 && offset < 200) {
    NSUInteger idx = (NSUInteger)(offset - 100);
    KKBezierPath *path = [self readPathParam:cfg.pathParam];
    if (idx >= path.count)
      return NO;

    if (optHeld) {
      [path removeAtIndex:idx];
      [self writePathParam:cfg.pathParam path:path];
      *forceUpdate = YES;
      return YES;
    }

    NSTimeInterval now = CACurrentMediaTime();
    if (_pathLastClickIndex == (NSInteger)idx &&
        (now - _pathLastClickTime) < 0.35) {
      [path toggleTypeAtIndex:idx start:startObj end:endObj];
      [self writePathParam:cfg.pathParam path:path];
      _pathLastClickIndex = -1;
      *forceUpdate = YES;
      return YES;
    }
    _pathLastClickTime = now;
    _pathLastClickIndex = (NSInteger)idx;

    KKBezierPoint dragPt = [path pointAtIndex:idx];
    _pathDragStartObj = (simd_float2){dragPt.x, dragPt.y};
    _pathDragIndex = (NSInteger)idx;
    _pathDragIsInHandle = NO;
    _pathDragIsOutHandle = NO;
    *forceUpdate = YES;
    return YES;
  }

  if (offset >= 200 && offset < 300) {
    NSUInteger idx = (NSUInteger)(offset - 200);
    KKBezierPath *hPath = [self readPathParam:cfg.pathParam];
    if (idx < hPath.count) {
      KKBezierPoint dragPt = [hPath pointAtIndex:idx];
      _pathDragStartObj =
          (simd_float2){dragPt.x + dragPt.inX, dragPt.y + dragPt.inY};
    }
    _pathDragIndex = (NSInteger)idx;
    _pathDragIsInHandle = YES;
    _pathDragIsOutHandle = NO;
    *forceUpdate = YES;
    return YES;
  }

  if (offset >= 300 && offset < 400) {
    NSUInteger idx = (NSUInteger)(offset - 300);
    KKBezierPath *hPath = [self readPathParam:cfg.pathParam];
    if (idx < hPath.count) {
      KKBezierPoint dragPt = [hPath pointAtIndex:idx];
      _pathDragStartObj =
          (simd_float2){dragPt.x + dragPt.outX, dragPt.y + dragPt.outY};
    }
    _pathDragIndex = (NSInteger)idx;
    _pathDragIsInHandle = NO;
    _pathDragIsOutHandle = YES;
    *forceUpdate = YES;
    return YES;
  }

  if (offset == 50 && optHeld) {
    KKBezierPath *path = [self readPathParam:cfg.pathParam];
    simd_float2 mouseObj =
        [self objectPointFromCanvasPoint:(CGPoint){positionX, positionY}];

    NSUInteger bestSeg = 0;
    float bestDist = FLT_MAX;
    for (NSUInteger seg = 0; seg < path.segmentCount; seg++) {
      for (NSUInteger s = 1; s <= kPathDrawResolution; s++) {
        float localT = (float)s / (float)kPathDrawResolution;
        simd_float2 objPt = [path evaluateSegment:seg
                                              atT:localT
                                            start:startObj
                                              end:endObj];
        float dist = simd_length(objPt - mouseObj);
        if (dist < bestDist) {
          bestDist = dist;
          bestSeg = seg;
        }
      }
    }

    [path insertAtIndex:bestSeg position:mouseObj];
    [self writePathParam:cfg.pathParam path:path];
    _pathDragIndex = (NSInteger)bestSeg;
    _pathDragIsInHandle = NO;
    _pathDragIsOutHandle = NO;
    *forceUpdate = YES;
    return YES;
  }

  return NO;
}

- (void)buildPathSnapTargets:(simd_float2 *)targets
                       count:(NSUInteger *)outCount
                        path:(KKBezierPath *)path
                   dragIndex:(NSUInteger)dragIndex
                      atTime:(CMTime)time {
  NSUInteger n = 0;
  // All main points as snap targets
  UInt32 mainParams[] = {kParamPointA, kParamPointB, kParamDriftPoint,
                         kParamExitPoint};
  for (int i = 0; i < 4; i++)
    targets[n++] = [self objectPositionForParam:mainParams[i] atTime:time];
  // Other control points on this path
  for (NSUInteger i = 0; i < path.count; i++) {
    if (i == dragIndex)
      continue;
    KKBezierPoint pt = [path pointAtIndex:i];
    targets[n++] = (simd_float2){pt.x, pt.y};
  }
  *outCount = n;
}

- (simd_float2)applyPathSnap:(simd_float2)pos
                     targets:(simd_float2 *)targets
                       count:(NSUInteger)count {
  CGPoint c0 = [self canvasPointFromObjectPoint:(simd_float2){0, 0}];
  CGPoint c1 = [self canvasPointFromObjectPoint:(simd_float2){1, 0}];
  float pixPerUnit = (float)fabs(c1.x - c0.x);
  return [_pathSnap snapObjectPoint:pos
                          toTargets:targets
                              count:count
                      pixelsPerUnit:pixPerUnit];
}

- (BOOL)mouseDraggedForPathWithPart:(NSInteger)activePart
                          positionX:(double)positionX
                          positionY:(double)positionY
                             atTime:(CMTime)time {
  if (_pathDragIndex < 0)
    return NO;

  KKBezierPath *path = [self readPathParam:_pathActiveParam];
  if ((NSUInteger)_pathDragIndex >= path.count)
    return NO;

  simd_float2 mouseObj =
      [self objectPointFromCanvasPoint:(CGPoint){positionX, positionY}];

  CGEventFlags flags =
      CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
  BOOL optHeld = (flags & kCGEventFlagMaskAlternate) != 0;
  BOOL shiftHeld = (flags & kCGEventFlagMaskShift) != 0;
  BOOL ctrlHeld = (flags & kCGEventFlagMaskControl) != 0;

  [_pathSnap reset];

  // Shift constrains to horizontal or vertical from drag start
  if (shiftHeld) {
    float dx = fabsf(mouseObj.x - _pathDragStartObj.x);
    float dy = fabsf(mouseObj.y - _pathDragStartObj.y);
    if (dx > dy)
      mouseObj.y = _pathDragStartObj.y;
    else
      mouseObj.x = _pathDragStartObj.x;
  }

  if (_pathDragIsInHandle) {
    KKBezierPoint pt = [path pointAtIndex:(NSUInteger)_pathDragIndex];
    simd_float2 handlePos = mouseObj;

    // Snap handle to horizontal/vertical relative to control point
    if (!shiftHeld && !ctrlHeld) {
      CGPoint ptC = [self canvasPointFromObjectPoint:(simd_float2){pt.x, pt.y}];
      CGPoint hC = [self canvasPointFromObjectPoint:handlePos];
      if (fabs(hC.y - ptC.y) < kSnapThreshold) {
        handlePos.y = pt.y;
        _pathSnap.snappedY = YES;
        _pathSnap.snapValueY = pt.y;
      }
      if (fabs(hC.x - ptC.x) < kSnapThreshold) {
        handlePos.x = pt.x;
        _pathSnap.snappedX = YES;
        _pathSnap.snapValueX = pt.x;
      }
    }

    simd_float2 offset = {handlePos.x - pt.x, handlePos.y - pt.y};
    [path setInHandle:offset atIndex:(NSUInteger)_pathDragIndex];
    if (!optHeld)
      [path setOutHandle:(simd_float2){-offset.x, -offset.y}
                 atIndex:(NSUInteger)_pathDragIndex];
  } else if (_pathDragIsOutHandle) {
    KKBezierPoint pt = [path pointAtIndex:(NSUInteger)_pathDragIndex];
    simd_float2 handlePos = mouseObj;

    if (!shiftHeld && !ctrlHeld) {
      CGPoint ptC = [self canvasPointFromObjectPoint:(simd_float2){pt.x, pt.y}];
      CGPoint hC = [self canvasPointFromObjectPoint:handlePos];
      if (fabs(hC.y - ptC.y) < kSnapThreshold) {
        handlePos.y = pt.y;
        _pathSnap.snappedY = YES;
        _pathSnap.snapValueY = pt.y;
      }
      if (fabs(hC.x - ptC.x) < kSnapThreshold) {
        handlePos.x = pt.x;
        _pathSnap.snappedX = YES;
        _pathSnap.snapValueX = pt.x;
      }
    }

    simd_float2 offset = {handlePos.x - pt.x, handlePos.y - pt.y};
    [path setOutHandle:offset atIndex:(NSUInteger)_pathDragIndex];
    if (!optHeld)
      [path setInHandle:(simd_float2){-offset.x, -offset.y}
                atIndex:(NSUInteger)_pathDragIndex];
  } else {
    // Snap control point to other points and endpoints
    if (!ctrlHeld) {
      simd_float2 snapTargets[path.count + 4];
      NSUInteger snapCount;
      [self buildPathSnapTargets:snapTargets
                           count:&snapCount
                            path:path
                       dragIndex:(NSUInteger)_pathDragIndex
                          atTime:time];
      mouseObj = [self applyPathSnap:mouseObj
                             targets:snapTargets
                               count:snapCount];
    }
    [path moveAtIndex:(NSUInteger)_pathDragIndex to:mouseObj];
  }

  [self writePathParam:_pathActiveParam path:path];
  return YES;
}

- (void)drawOSCWithWidth:(NSInteger)width
                  height:(NSInteger)height
              activePart:(NSInteger)activePart
        destinationImage:(FxImageTile *)destinationImage
                  atTime:(CMTime)time {
  [self encodeRenderCommandsForDestinationImage:destinationImage
                                 canvasPosition:CGPointZero
                               clearDestination:YES
                                       commands:^(id<MTLRenderCommandEncoder> e,
                                                  CGPoint p, simd_uint2 v){
                                       }];

  BOOL animInOn = [self animateInEnabledAtTime:time];
  BOOL animOutOn = [self animateOutEnabledAtTime:time];
  BOOL driftOn = [self driftEnabledAtTime:time];
  BOOL exitOn = [self exitEnabledAtTime:time];
  BOOL showA = animInOn || (animOutOn && !exitOn);
  BOOL showExit = exitOn && animOutOn;

  id<FxParameterRetrievalAPI_v6> hideAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  BOOL hideA = NO, hideB = NO, hideDrift = NO, hideExit = NO;
  [hideAPI getBoolValue:&hideA fromParameter:kParamHideOSCA atTime:time];
  [hideAPI getBoolValue:&hideB fromParameter:kParamHideOSCB atTime:time];
  [hideAPI getBoolValue:&hideDrift
          fromParameter:kParamHideOSCDrift
                 atTime:time];
  [hideAPI getBoolValue:&hideExit fromParameter:kParamHideOSCExit atTime:time];
  _points[0].hidden = hideA;
  _points[1].hidden = hideB;
  _points[2].hidden = hideDrift;
  _points[3].hidden = hideExit;

  simd_float4 red = {1, 0, 0, 1};
  double arcOuter = _points[0].arc.oscRadius + _points[0].arc.outlineWidth;
  double insetA = hideA ? 0.0 : arcOuter;
  double insetB = hideB ? 0.0 : arcOuter;
  double insetDrift = hideDrift ? 0.0 : arcOuter;
  double insetExit = hideExit ? 0.0 : arcOuter;

  PathSegConfig cfgAB = {kParamPathAB, kParamPointA, kParamPointB, 0};
  PathSegConfig cfgBDrift = {kParamPathBDrift, kParamPointB, kParamDriftPoint,
                             1};
  PathSegConfig cfgDriftExit = {kParamPathDriftExit, kParamDriftPoint,
                                kParamExitPoint, 2};
  PathSegConfig cfgBExit = {kParamPathBExit, kParamPointB, kParamExitPoint, 3};
  PathSegConfig cfgDriftA = {kParamPathDriftA, kParamDriftPoint, kParamPointA,
                             4};

  if (showA)
    [self drawPathSegment:cfgAB
         destinationImage:destinationImage
                    color:red
               startInset:insetA
                 endInset:insetB
                   atTime:time];
  if (driftOn) {
    [self drawPathSegment:cfgBDrift
         destinationImage:destinationImage
                    color:red
               startInset:insetB
                 endInset:insetDrift
                   atTime:time];
    if (showExit)
      [self drawPathSegment:cfgDriftExit
           destinationImage:destinationImage
                      color:red
                 startInset:insetDrift
                   endInset:insetExit
                     atTime:time];
    else if (animOutOn)
      [self drawPathSegment:cfgDriftA
           destinationImage:destinationImage
                      color:red
                 startInset:insetDrift
                   endInset:insetA
                     atTime:time];
  } else if (showExit) {
    [self drawPathSegment:cfgBExit
         destinationImage:destinationImage
                    color:red
               startInset:insetB
                 endInset:insetExit
                   atTime:time];
  }

  [_pointSnap drawSnapGuidesWithOSC:self
                      isObjectSpace:NO
                   destinationImage:destinationImage];
  [_pathSnap drawSnapGuidesWithOSC:self
                     isObjectSpace:YES
                  destinationImage:destinationImage];

  if (showA)
    [_points[0] drawWithParentOSC:self
                 destinationImage:destinationImage
                           atTime:time];
  [_points[1] drawWithParentOSC:self
               destinationImage:destinationImage
                         atTime:time];

  if (driftOn)
    [_points[2] drawWithParentOSC:self
                 destinationImage:destinationImage
                           atTime:time];

  if (showExit)
    [_points[3] drawWithParentOSC:self
                 destinationImage:destinationImage
                           atTime:time];
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  BOOL animInOn = [self animateInEnabledAtTime:time];
  BOOL animOutOn = [self animateOutEnabledAtTime:time];
  BOOL exitOn = [self exitEnabledAtTime:time];
  BOOL showA = animInOn || (animOutOn && !exitOn);

  // When Cmd is held, temporarily unhide points so they can be hit-tested
  // for the Cmd+click toggle gesture.
  CGEventFlags cmdFlags =
      CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
  BOOL cmdHeld = (cmdFlags & kCGEventFlagMaskCommand) != 0;
  BOOL savedHidden[kPointCount];
  if (cmdHeld) {
    for (int i = 0; i < kPointCount; i++) {
      savedHidden[i] = _points[i].hidden;
      _points[i].hidden = NO;
    }
  }

  // Main point controls first (highest priority)
  NSInteger prePart = *activePart;

  if (showA)
    [_points[0] hitTestWithParentOSC:self
                           positionX:positionX
                           positionY:positionY
                          activePart:activePart
                              atTime:time];

  [_points[1] hitTestWithParentOSC:self
                         positionX:positionX
                         positionY:positionY
                        activePart:activePart
                            atTime:time];

  if ([self driftEnabledAtTime:time])
    [_points[2] hitTestWithParentOSC:self
                           positionX:positionX
                           positionY:positionY
                          activePart:activePart
                              atTime:time];

  if (exitOn && animOutOn)
    [_points[3] hitTestWithParentOSC:self
                           positionX:positionX
                           positionY:positionY
                          activePart:activePart
                              atTime:time];

  // Restore hidden state after hit testing
  if (cmdHeld) {
    for (int i = 0; i < kPointCount; i++)
      _points[i].hidden = savedHidden[i];
  }

  // Path elements only if no main point was hit
  if (*activePart == prePart) {
    CGEventFlags hflags =
        CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
    BOOL hOpt = (hflags & kCGEventFlagMaskAlternate) != 0;
    id<FxOnScreenControlAPI_v4> hOscAPI =
        [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];

    PathSegConfig cfgAB = {kParamPathAB, kParamPointA, kParamPointB, 0};
    PathSegConfig cfgBD = {kParamPathBDrift, kParamPointB, kParamDriftPoint, 1};
    PathSegConfig cfgDE = {kParamPathDriftExit, kParamDriftPoint,
                           kParamExitPoint, 2};
    PathSegConfig cfgBE = {kParamPathBExit, kParamPointB, kParamExitPoint, 3};
    PathSegConfig cfgDA = {kParamPathDriftA, kParamDriftPoint, kParamPointA, 4};
    BOOL driftOn = [self driftEnabledAtTime:time];
    BOOL exitShow = exitOn && animOutOn;
    BOOL hit = NO;

    if (showA)
      hit = [self hitTestPathSegment:cfgAB
                                   x:positionX
                                   y:positionY
                          activePart:activePart
                             optDown:hOpt
                              oscAPI:hOscAPI
                              atTime:time];
    if (!hit && driftOn)
      hit = [self hitTestPathSegment:cfgBD
                                   x:positionX
                                   y:positionY
                          activePart:activePart
                             optDown:hOpt
                              oscAPI:hOscAPI
                              atTime:time];
    if (!hit && driftOn && exitShow)
      hit = [self hitTestPathSegment:cfgDE
                                   x:positionX
                                   y:positionY
                          activePart:activePart
                             optDown:hOpt
                              oscAPI:hOscAPI
                              atTime:time];
    if (!hit && driftOn && !exitShow && animOutOn)
      hit = [self hitTestPathSegment:cfgDA
                                   x:positionX
                                   y:positionY
                          activePart:activePart
                             optDown:hOpt
                              oscAPI:hOscAPI
                              atTime:time];
    if (!hit && !driftOn && exitShow)
      hit = [self hitTestPathSegment:cfgBE
                                   x:positionX
                                   y:positionY
                          activePart:activePart
                             optDown:hOpt
                              oscAPI:hOscAPI
                              atTime:time];
    if (!hit)
      [hOscAPI setCursor:[NSCursor arrowCursor]];
  }
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  // Cmd+click on arc toggles hide
  if (modifiers & kFxModifierKey_COMMAND) {
    static const UInt32 hideParams[] = {kParamHideOSCA, kParamHideOSCB,
                                        kParamHideOSCDrift, kParamHideOSCExit};
    for (int i = 0; i < kPointCount; i++) {
      if (activePart == _points[i].arcPart) {
        id<FxParameterRetrievalAPI_v6> paramGetAPI = [self.apiManager
            apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
        id<FxParameterSettingAPI_v5> paramSetAPI = [self.apiManager
            apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
        BOOL hidden = NO;
        [paramGetAPI getBoolValue:&hidden
                    fromParameter:hideParams[i]
                           atTime:time];
        [paramSetAPI setBoolValue:!hidden
                      toParameter:hideParams[i]
                           atTime:time];
        *forceUpdate = YES;
        return;
      }
    }
  }

  for (int i = 0; i < kPointCount; i++) {
    if ([_points[i] mouseDownWithParentOSC:self
                                 positionX:positionX
                                 positionY:positionY
                                activePart:activePart
                               forceUpdate:forceUpdate
                                    atTime:time])
      return;
  }
  if ([self mouseDownForPathWithPart:activePart
                           positionX:positionX
                           positionY:positionY
                           modifiers:modifiers
                         forceUpdate:forceUpdate
                              atTime:time])
    return;
  [super mouseDownAtPositionX:positionX
                    positionY:positionY
                   activePart:activePart
                    modifiers:modifiers
                  forceUpdate:forceUpdate
                       atTime:time];
}

- (void)mouseDraggedAtPositionX:(double)positionX
                      positionY:(double)positionY
                     activePart:(NSInteger)activePart
                      modifiers:(NSUInteger)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {
  if ([self mouseDraggedForPathWithPart:activePart
                              positionX:positionX
                              positionY:positionY
                                 atTime:time]) {
    *forceUpdate = YES;
    return;
  }
  for (int i = 0; i < kPointCount; i++) {
    CGPoint snapTargets[kPointCount - 1];
    NSUInteger snapCount = 0;
    for (int j = 0; j < kPointCount; j++) {
      if (j != i)
        snapTargets[snapCount++] =
            [self canvasPositionForParam:_points[j].pointParam atTime:time];
    }
    if ([_points[i] mouseDraggedWithParentOSC:self
                                   snapEngine:_pointSnap
                                  snapTargets:snapTargets
                                    snapCount:snapCount
                                    positionX:positionX
                                    positionY:positionY
                                   activePart:activePart
                                       atTime:time]) {
      *forceUpdate = YES;
      return;
    }
  }
  [super mouseDraggedAtPositionX:positionX
                       positionY:positionY
                      activePart:activePart
                       modifiers:modifiers
                     forceUpdate:forceUpdate
                          atTime:time];
}

- (void)mouseUpAtPositionX:(double)positionX
                 positionY:(double)positionY
                activePart:(NSInteger)activePart
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time {
  [_pointSnap reset];
  [_pathSnap reset];
  _pathDragIndex = -1;
  _pathDragIsInHandle = NO;
  _pathDragIsOutHandle = NO;
  for (int i = 0; i < kPointCount; i++) {
    [_points[i] resetDragState];
  }
  id<FxOnScreenControlAPI_v4> oscAPI =
      [self.apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  [oscAPI setCursor:[NSCursor arrowCursor]];
  [super mouseUpAtPositionX:positionX
                  positionY:positionY
                 activePart:activePart
                  modifiers:modifiers
                forceUpdate:forceUpdate
                     atTime:time];
}

@end
