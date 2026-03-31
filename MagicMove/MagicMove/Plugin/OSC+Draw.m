/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC_Private.h"
#import <CoreGraphics/CGEventSource.h>

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

static void drawFilledTriangle(MagicMoveOSC *osc, CGPoint a, CGPoint b,
                               CGPoint c, simd_float4 triColor,
                               FxImageTile *dest) {
  KKMetalDeviceCache *cache = [KKMetalDeviceCache sharedCache];
  uint64_t registryID = dest.deviceRegistryID;
  MTLPixelFormat pixelFormat =
      [KKMetalDeviceCache pixelFormatForImageTile:dest];
  id<MTLRenderPipelineState> ps = [cache
      buildAndRegisterPipelineStateForPluginID:
          @"co.overpolish.keyframelesskit.Triangle"
                                    registryID:registryID
                                   pixelFormat:pixelFormat
                                      bundleID:nil
                                  vertexShader:@"vertexShader"
                                fragmentShader:@"triangleFragment"
                                     blendMode:KKBlendModePremultipliedAlpha];
  if (!ps)
    return;

  CGPoint mid = CGPointMake((a.x + b.x + c.x) / 3.0, (a.y + b.y + c.y) / 3.0);

  [osc
      encodeRenderCommandsForDestinationImage:dest
                               canvasPosition:mid
                             clearDestination:NO
                                     commands:^(id<MTLRenderCommandEncoder> enc,
                                                CGPoint metalMid,
                                                simd_uint2 viewportSize) {
                                       float ioW = viewportSize.x;
                                       float ioH = viewportSize.y;
                                       KKVertex2D verts[3] = {
                                           {{(float)(a.x - ioW / 2.0),
                                             (float)(ioH / 2.0 - a.y)},
                                            {1, 0}},
                                           {{(float)(b.x - ioW / 2.0),
                                             (float)(ioH / 2.0 - b.y)},
                                            {0, 1}},
                                           {{(float)(c.x - ioW / 2.0),
                                             (float)(ioH / 2.0 - c.y)},
                                            {0, 0}},
                                       };
                                       simd_float4 color = triColor;
                                       [enc setRenderPipelineState:ps];
                                       [enc
                                           setVertexBytes:verts
                                                   length:sizeof(verts)
                                                  atIndex:
                                                      KKVertexInputIndex_Vertices];
                                       [enc
                                           setVertexBytes:&viewportSize
                                                   length:sizeof(viewportSize)
                                                  atIndex:
                                                      KKVertexInputIndex_ViewportSize];
                                       [enc setFragmentBytes:&color
                                                      length:sizeof(color)
                                                     atIndex:0];
                                       [enc drawPrimitives:
                                                MTLPrimitiveTypeTriangle
                                               vertexStart:0
                                               vertexCount:3];
                                     }];
}

@implementation MagicMoveOSC (Draw)

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

  // Draw direction chevrons along the path
  static const int kChevronCount = 3;
  static const float kChevronSize = 14.0f;
  static const float kChevronAngle = 0.45f; // ~26 degrees half-angle
  static const float kTangentEpsilon = 0.02f;
  simd_float4 chevronColor = color;
  for (int ci = 0; ci < kChevronCount; ci++) {
    float t = (float)(ci + 1) / (float)(kChevronCount + 1);
    simd_float2 posObj = [path positionAtT:t start:startObj end:endObj];
    simd_float2 aheadObj = [path positionAtT:fminf(t + kTangentEpsilon, 1.0f)
                                       start:startObj
                                         end:endObj];
    CGPoint pos = [self canvasPointFromObjectPoint:posObj];
    CGPoint ahead = [self canvasPointFromObjectPoint:aheadObj];
    float dx = ahead.x - pos.x;
    float dy = ahead.y - pos.y;
    float len = sqrtf(dx * dx + dy * dy);
    if (len < 0.1f)
      continue;
    dx /= len;
    dy /= len;

    // Skip if inside either endpoint inset
    double d1 = hypot(pos.x - startCanvas.x, pos.y - startCanvas.y);
    double d2 = hypot(pos.x - endCanvas.x, pos.y - endCanvas.y);
    if (d1 < startInset || d2 < endInset)
      continue;

    // Filled triangle pointing in the direction of travel
    float cosA = cosf(kChevronAngle), sinA = sinf(kChevronAngle);
    CGPoint tip = pos;
    CGPoint armA = CGPointMake(pos.x - kChevronSize * (dx * cosA - dy * sinA),
                               pos.y - kChevronSize * (dy * cosA + dx * sinA));
    CGPoint armB = CGPointMake(pos.x - kChevronSize * (dx * cosA + dy * sinA),
                               pos.y - kChevronSize * (dy * cosA - dx * sinA));
    drawFilledTriangle(self, tip, armA, armB, chevronColor, dest);
  }

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

      [self.pathHandleOSC drawAtCanvasPosition:inCanvas
                                     isHovered:NO
                                      isActive:NO
                              destinationImage:dest
                                        atTime:time];
      [self.pathHandleOSC drawAtCanvasPosition:outCanvas
                                     isHovered:NO
                                      isActive:NO
                              destinationImage:dest
                                        atTime:time];
    }

    [self.pathPointOSC
        drawAtCanvasPosition:ptCanvas
                   isHovered:NO
                    isActive:(self.pathDragIndex == (NSInteger)i &&
                              !self.pathDragIsInHandle &&
                              !self.pathDragIsOutHandle)
            destinationImage:dest
                      atTime:time];
  }
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

  BOOL animInOn = [self boolParam:kKKParamAnimateIn atTime:time];
  BOOL animOutOn = [self boolParam:kKKParamAnimateOut atTime:time];
  BOOL driftOn = [self boolParam:kParamDrift atTime:time];
  BOOL exitOn = [self boolParam:kParamExit atTime:time];
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
  self.points[0].hidden = hideA;
  self.points[1].hidden = hideB;
  self.points[2].hidden = hideDrift;
  self.points[3].hidden = hideExit;

  simd_float4 red = {1, 0, 0, 1};
  double arcOuter =
      self.points[0].arc.oscRadius + self.points[0].arc.outlineWidth;
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

  if (animInOn)
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

  [self.pointSnap drawSnapGuidesWithOSC:self
                          isObjectSpace:NO
                       destinationImage:destinationImage];
  [self.pathSnap drawSnapGuidesWithOSC:self
                         isObjectSpace:YES
                      destinationImage:destinationImage];

  if (showA)
    [self.points[0] drawWithParentOSC:self
                     destinationImage:destinationImage
                               atTime:time];
  [self.points[1] drawWithParentOSC:self
                   destinationImage:destinationImage
                             atTime:time];

  if (driftOn)
    [self.points[2] drawWithParentOSC:self
                     destinationImage:destinationImage
                               atTime:time];

  if (showExit)
    [self.points[3] drawWithParentOSC:self
                     destinationImage:destinationImage
                               atTime:time];
}

@end
