/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC_Private.h"
#import <CoreGraphics/CGEventSource.h>

@implementation MagicMoveOSC (PathInteraction)

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
  self.pathActiveParam = cfg.pathParam;

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
    if (self.pathLastClickIndex == (NSInteger)idx &&
        (now - self.pathLastClickTime) < 0.35) {
      [path toggleTypeAtIndex:idx start:startObj end:endObj];
      [self writePathParam:cfg.pathParam path:path];
      self.pathLastClickIndex = -1;
      *forceUpdate = YES;
      return YES;
    }
    self.pathLastClickTime = now;
    self.pathLastClickIndex = (NSInteger)idx;

    KKBezierPoint dragPt = [path pointAtIndex:idx];
    self.pathDragStartObj = (simd_float2){dragPt.x, dragPt.y};
    self.pathDragIndex = (NSInteger)idx;
    self.pathDragIsInHandle = NO;
    self.pathDragIsOutHandle = NO;
    *forceUpdate = YES;
    return YES;
  }

  if (offset >= 200 && offset < 300) {
    NSUInteger idx = (NSUInteger)(offset - 200);
    KKBezierPath *hPath = [self readPathParam:cfg.pathParam];
    if (idx < hPath.count) {
      KKBezierPoint dragPt = [hPath pointAtIndex:idx];
      self.pathDragStartObj =
          (simd_float2){dragPt.x + dragPt.inX, dragPt.y + dragPt.inY};
    }
    self.pathDragIndex = (NSInteger)idx;
    self.pathDragIsInHandle = YES;
    self.pathDragIsOutHandle = NO;
    *forceUpdate = YES;
    return YES;
  }

  if (offset >= 300 && offset < 400) {
    NSUInteger idx = (NSUInteger)(offset - 300);
    KKBezierPath *hPath = [self readPathParam:cfg.pathParam];
    if (idx < hPath.count) {
      KKBezierPoint dragPt = [hPath pointAtIndex:idx];
      self.pathDragStartObj =
          (simd_float2){dragPt.x + dragPt.outX, dragPt.y + dragPt.outY};
    }
    self.pathDragIndex = (NSInteger)idx;
    self.pathDragIsInHandle = NO;
    self.pathDragIsOutHandle = YES;
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
    self.pathDragIndex = (NSInteger)bestSeg;
    self.pathDragIsInHandle = NO;
    self.pathDragIsOutHandle = NO;
    *forceUpdate = YES;
    return YES;
  }

  return NO;
}

- (void)dragHandle:(BOOL)isInHandle
              path:(KKBezierPath *)path
          mouseObj:(simd_float2)mouseObj
           optHeld:(BOOL)optHeld
         shiftHeld:(BOOL)shiftHeld
          ctrlHeld:(BOOL)ctrlHeld {
  KKBezierPoint pt = [path pointAtIndex:(NSUInteger)self.pathDragIndex];
  simd_float2 handlePos = mouseObj;

  if (!shiftHeld && !ctrlHeld) {
    CGPoint ptC = [self canvasPointFromObjectPoint:(simd_float2){pt.x, pt.y}];
    CGPoint hC = [self canvasPointFromObjectPoint:handlePos];
    if (fabs(hC.y - ptC.y) < kSnapThreshold) {
      handlePos.y = pt.y;
      self.pathSnap.snappedY = YES;
      self.pathSnap.snapValueY = pt.y;
    }
    if (fabs(hC.x - ptC.x) < kSnapThreshold) {
      handlePos.x = pt.x;
      self.pathSnap.snappedX = YES;
      self.pathSnap.snapValueX = pt.x;
    }
  }

  simd_float2 offset = {handlePos.x - pt.x, handlePos.y - pt.y};
  simd_float2 mirror = {-offset.x, -offset.y};

  if (isInHandle) {
    [path setInHandle:offset atIndex:(NSUInteger)self.pathDragIndex];
    if (!optHeld)
      [path setOutHandle:mirror atIndex:(NSUInteger)self.pathDragIndex];
  } else {
    [path setOutHandle:offset atIndex:(NSUInteger)self.pathDragIndex];
    if (!optHeld)
      [path setInHandle:mirror atIndex:(NSUInteger)self.pathDragIndex];
  }
}

- (void)buildPathSnapTargets:(simd_float2 *)targets
                       count:(NSUInteger *)outCount
                        path:(KKBezierPath *)path
                   dragIndex:(NSUInteger)dragIndex
                      atTime:(CMTime)time {
  NSUInteger n = 0;
  UInt32 mainParams[] = {kParamPointA, kParamPointB, kParamDriftPoint,
                         kParamExitPoint};
  for (int i = 0; i < 4; i++)
    targets[n++] = [self objectPositionForParam:mainParams[i] atTime:time];
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
  return [self.pathSnap snapObjectPoint:pos
                              toTargets:targets
                                  count:count
                          pixelsPerUnit:pixPerUnit];
}

- (BOOL)mouseDraggedForPathWithPart:(NSInteger)activePart
                          positionX:(double)positionX
                          positionY:(double)positionY
                             atTime:(CMTime)time {
  if (self.pathDragIndex < 0)
    return NO;

  KKBezierPath *path = [self readPathParam:self.pathActiveParam];
  if ((NSUInteger)self.pathDragIndex >= path.count)
    return NO;

  simd_float2 mouseObj =
      [self objectPointFromCanvasPoint:(CGPoint){positionX, positionY}];

  CGEventFlags flags =
      CGEventSourceFlagsState(kCGEventSourceStateCombinedSessionState);
  BOOL optHeld = (flags & kCGEventFlagMaskAlternate) != 0;
  BOOL shiftHeld = (flags & kCGEventFlagMaskShift) != 0;
  BOOL ctrlHeld = (flags & kCGEventFlagMaskControl) != 0;

  [self.pathSnap reset];

  if (shiftHeld) {
    float dx = fabsf(mouseObj.x - self.pathDragStartObj.x);
    float dy = fabsf(mouseObj.y - self.pathDragStartObj.y);
    if (dx > dy)
      mouseObj.y = self.pathDragStartObj.y;
    else
      mouseObj.x = self.pathDragStartObj.x;
  }

  if (self.pathDragIsInHandle || self.pathDragIsOutHandle) {
    [self dragHandle:self.pathDragIsInHandle
                path:path
            mouseObj:mouseObj
             optHeld:optHeld
           shiftHeld:shiftHeld
            ctrlHeld:ctrlHeld];
  } else {
    if (!ctrlHeld) {
      simd_float2 snapTargets[path.count + 4];
      NSUInteger snapCount;
      [self buildPathSnapTargets:snapTargets
                           count:&snapCount
                            path:path
                       dragIndex:(NSUInteger)self.pathDragIndex
                          atTime:time];
      mouseObj = [self applyPathSnap:mouseObj
                             targets:snapTargets
                               count:snapCount];
    }
    [path moveAtIndex:(NSUInteger)self.pathDragIndex to:mouseObj];
  }

  [self writePathParam:self.pathActiveParam path:path];
  return YES;
}

@end
