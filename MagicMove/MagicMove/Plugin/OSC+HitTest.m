/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC_Private.h"
#import <CoreGraphics/CGEventSource.h>

@implementation MagicMoveOSC (HitTest)

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

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  BOOL animInOn = [self boolParam:kKKParamAnimateIn atTime:time];
  BOOL animOutOn = [self boolParam:kKKParamAnimateOut atTime:time];
  BOOL exitOn = [self boolParam:kParamExit atTime:time];
  BOOL showA = animInOn || (animOutOn && !exitOn);

  CGEventFlags cmdFlags =
      CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
  BOOL cmdHeld = (cmdFlags & kCGEventFlagMaskCommand) != 0;
  BOOL savedHidden[kPointCount];
  if (cmdHeld) {
    for (int i = 0; i < kPointCount; i++) {
      savedHidden[i] = self.points[i].hidden;
      self.points[i].hidden = NO;
    }
  }

  NSInteger prePart = *activePart;

  if (showA)
    [self.points[0] hitTestWithParentOSC:self
                               positionX:positionX
                               positionY:positionY
                              activePart:activePart
                                  atTime:time];

  [self.points[1] hitTestWithParentOSC:self
                             positionX:positionX
                             positionY:positionY
                            activePart:activePart
                                atTime:time];

  if ([self boolParam:kParamDrift atTime:time])
    [self.points[2] hitTestWithParentOSC:self
                               positionX:positionX
                               positionY:positionY
                              activePart:activePart
                                  atTime:time];

  if (exitOn && animOutOn)
    [self.points[3] hitTestWithParentOSC:self
                               positionX:positionX
                               positionY:positionY
                              activePart:activePart
                                  atTime:time];

  if (cmdHeld) {
    for (int i = 0; i < kPointCount; i++)
      self.points[i].hidden = savedHidden[i];
  }

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
    BOOL driftOn = [self boolParam:kParamDrift atTime:time];
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

@end
