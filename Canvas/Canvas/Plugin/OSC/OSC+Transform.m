/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "OSC_Private.h"
#import "ObjectParams.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation CanvasOSC (Transform)

- (void)dragCornerRadiusAtX:(double)positionX
                          y:(double)positionY
                  modifiers:(NSUInteger)modifiers
                forceUpdate:(BOOL *)forceUpdate {
  KKBezierPath *active = [self activePath];
  if (!active)
    return;

  simd_float2 bmin, bmax;
  [self boundsOfPath:active min:&bmin max:&bmax];
  float ddx = (float)(self.dragAnchor.x - positionX);
  float ddy = (float)(self.dragAnchor.y - positionY);
  NSInteger ci = self.dragCornerIndex;
  if (ci == 0 || ci == 3)
    ddx = -ddx;
  if (ci == 2 || ci == 3)
    ddy = -ddy;
  float delta = (ddx + ddy) * 0.5f;

  CGPoint cMin = [self canvasPointFromObjectPoint:bmin];
  CGPoint cMax = [self canvasPointFromObjectPoint:bmax];
  float canvasW = (float)fabs(cMax.x - cMin.x);
  float canvasH = (float)fabs(cMax.y - cMin.y);
  float halfShort = fminf(canvasW, canvasH) * 0.5f;
  float inset = (float)[self strokeWidth] * 0.5f + 20.0f;
  float travel = fminf(100.0f, fmaxf(1.0f, halfShort - inset));
  float rawFraction = self.dragStartPixelRadius + delta / travel;

  float sw = (float)[self strokeWidth];
  float maxPx = fmaxf(canvasW, canvasH) * 0.5f;
  float minFraction = (maxPx > 0.0001f) ? (sw * 1.15f) / maxPx : 0;
  float snapThreshold = minFraction * 0.5f;
  float fraction;
  if (rawFraction < snapThreshold)
    fraction = 0.0f;
  else
    fraction = fmaxf(minFraction, fminf(1.0f, rawFraction));

  BOOL optHeld = (modifiers & kFxModifierKey_OPTION) != 0;
  float ftl = optHeld ? active.cornerRadiusTL : fraction;
  float ftr = optHeld ? active.cornerRadiusTR : fraction;
  float fbr = optHeld ? active.cornerRadiusBR : fraction;
  float fbl = optHeld ? active.cornerRadiusBL : fraction;
  if (optHeld) {
    switch (ci) {
    case 0:
      ftl = fraction;
      break;
    case 1:
      ftr = fraction;
      break;
    case 2:
      fbr = fraction;
      break;
    case 3:
      fbl = fraction;
      break;
    }
  }

  [active setRoundedRectWithMin:bmin
                            max:bmax
                     fractionTL:ftl
                     fractionTR:ftr
                     fractionBR:fbr
                     fractionBL:fbl
                    canvasWidth:canvasW
                   canvasHeight:canvasH];
  [self writePaths:self.paths];
  *forceUpdate = YES;
}

- (void)dragResizeAtX:(double)positionX
                    y:(double)positionY
            modifiers:(NSUInteger)modifiers
          forceUpdate:(BOOL *)forceUpdate {
  if (!self.resizeOrigSnapshots || self.resizeOrigSnapshots.count == 0)
    return;

  simd_float2 oMin = self.resizeOrigMin;
  simd_float2 oMax = self.resizeOrigMax;
  float oW = oMax.x - oMin.x, oH = oMax.y - oMin.y;
  if (fabs(oW) < 1e-6f || fabs(oH) < 1e-6f)
    return;

  simd_float2 mouseObj =
      [self objectPointFromCanvasPoint:CGPointMake(positionX, positionY)];
  mouseObj = [self snapToGridPosition:mouseObj];
  self.cmdSnapOverride = (modifiers & kFxModifierKey_COMMAND) != 0;
  mouseObj = [self alignSnapPoint:mouseObj
                   excludingPaths:self.selectedPathIndices
                  excludingPoints:nil];

  float nMinX = oMin.x, nMinY = oMin.y, nMaxX = oMax.x, nMaxY = oMax.y;
  NSInteger h = self.dragResizeHandle;
  BOOL movesLeft = (h == 0 || h == 6 || h == 7);
  BOOL movesRight = (h == 2 || h == 3 || h == 4);
  BOOL movesTop = (h == 0 || h == 1 || h == 2);
  BOOL movesBottom = (h == 4 || h == 5 || h == 6);
  BOOL isEdge = (h % 2 == 1);
  BOOL isCorner = !isEdge;
  BOOL shiftHeld = (modifiers & kFxModifierKey_SHIFT) != 0;

  if (movesLeft)
    nMinX = mouseObj.x;
  if (movesRight)
    nMaxX = mouseObj.x;
  if (movesTop)
    nMaxY = mouseObj.y;
  if (movesBottom)
    nMinY = mouseObj.y;

  if (!shiftHeld) {
    float aspect = self.resizeOrigAspect;
    if (isCorner) {
      float nW = nMaxX - nMinX, nH = nMaxY - nMinY;
      if (fabs(nW) / aspect > fabs(nH)) {
        float targetH = fabs(nW) / aspect;
        if (movesTop)
          nMaxY = nMinY + copysignf(targetH, nMaxY - nMinY);
        else
          nMinY = nMaxY - copysignf(targetH, nMaxY - nMinY);
      } else {
        float targetW = fabs(nH) * aspect;
        if (movesRight)
          nMaxX = nMinX + copysignf(targetW, nMaxX - nMinX);
        else
          nMinX = nMaxX - copysignf(targetW, nMaxX - nMinX);
      }
    } else {
      float targetH = fabs(nMaxX - nMinX) / aspect;
      float targetW = fabs(nMaxY - nMinY) * aspect;
      if (movesLeft || movesRight) {
        float cy = (oMin.y + oMax.y) * 0.5f;
        nMinY = cy - targetH * 0.5f;
        nMaxY = cy + targetH * 0.5f;
      } else {
        float cx = (oMin.x + oMax.x) * 0.5f;
        nMinX = cx - targetW * 0.5f;
        nMaxX = cx + targetW * 0.5f;
      }
    }
  }

  float nW = nMaxX - nMinX, nH = nMaxY - nMinY;
  if (fabs(nW) < 1e-6f || fabs(nH) < 1e-6f)
    return;

  float scaleX = nW / oW, scaleY = nH / oH;

  for (NSUInteger s = 0; s < self.resizeOrigSnapshots.count; s++) {
    NSUInteger pathIdx = self.resizeOrigIndices[s].unsignedIntegerValue;
    if (pathIdx >= self.paths.count)
      continue;
    KKBezierPath *path = self.paths[pathIdx];
    NSData *snap = self.resizeOrigSnapshots[s];
    const KKBezierPoint *orig = snap.bytes;
    NSUInteger count = snap.length / sizeof(KKBezierPoint);

    for (NSUInteger i = 0; i < count && i < path.count; i++) {
      float nx = nMinX + (orig[i].x - oMin.x) / oW * nW;
      float ny = nMinY + (orig[i].y - oMin.y) / oH * nH;
      [path moveAtIndex:i to:(simd_float2){nx, ny}];
      [path
          setInHandle:(simd_float2){orig[i].inX * scaleX, orig[i].inY * scaleY}
              atIndex:i];
      [path setOutHandle:(simd_float2){orig[i].outX * scaleX,
                                       orig[i].outY * scaleY}
                 atIndex:i];
    }
  }

  [self writePaths:self.paths];

  self.resizeOrigAspect = fabs(nW / nH);
  self.resizeOrigMin = (simd_float2){nMinX, nMinY};
  self.resizeOrigMax = (simd_float2){nMaxX, nMaxY};
  NSMutableArray<NSData *> *snapshots = [NSMutableArray array];
  for (NSUInteger s = 0; s < self.resizeOrigIndices.count; s++) {
    NSUInteger pathIdx = self.resizeOrigIndices[s].unsignedIntegerValue;
    if (pathIdx >= self.paths.count)
      continue;
    KKBezierPath *path = self.paths[pathIdx];
    NSMutableData *snap =
        [NSMutableData dataWithLength:path.count * sizeof(KKBezierPoint)];
    KKBezierPoint *buf = snap.mutableBytes;
    for (NSUInteger i = 0; i < path.count; i++)
      buf[i] = [path pointAtIndex:i];
    [snapshots addObject:snap];
  }
  self.resizeOrigSnapshots = snapshots;

  *forceUpdate = YES;
}

- (void)dragRotateAtX:(double)positionX
                    y:(double)positionY
            modifiers:(NSUInteger)modifiers
          forceUpdate:(BOOL *)forceUpdate {
  if (!self.rotateOrigSnapshots || self.rotateOrigSnapshots.count == 0)
    return;

  CGPoint centerCanvas = [self canvasPointFromObjectPoint:self.rotateCenter];
  float currentAngle = atan2f((float)(positionY - centerCanvas.y),
                              (float)(positionX - centerCanvas.x));
  float deltaAngle = currentAngle - self.rotateStartAngle;

  if (modifiers & kFxModifierKey_SHIFT) {
    float snap = (float)(M_PI / 12.0);
    deltaAngle = roundf(deltaAngle / snap) * snap;
  }

  self.rotateDeltaAngle = deltaAngle;

  float cosA = cosf(deltaAngle);
  float sinA = sinf(deltaAngle);
  simd_float2 center = self.rotateCenter;

  CGPoint c0 = [self canvasPointFromObjectPoint:(simd_float2){0, 0}];
  CGPoint c1 = [self canvasPointFromObjectPoint:(simd_float2){1, 0}];
  CGPoint c2 = [self canvasPointFromObjectPoint:(simd_float2){0, 1}];
  float sx = (float)(c1.x - c0.x);
  float sy = (float)(c2.y - c0.y);
  if (fabsf(sx) < 1e-6f || fabsf(sy) < 1e-6f)
    return;

  for (NSUInteger s = 0; s < self.rotateOrigSnapshots.count; s++) {
    NSUInteger pathIdx = self.rotateOrigIndices[s].unsignedIntegerValue;
    if (pathIdx >= self.paths.count)
      continue;
    KKBezierPath *path = self.paths[pathIdx];
    NSData *snap = self.rotateOrigSnapshots[s];
    const KKBezierPoint *orig = snap.bytes;
    NSUInteger count = snap.length / sizeof(KKBezierPoint);

    for (NSUInteger i = 0; i < count && i < path.count; i++) {
      float dx = orig[i].x - center.x;
      float dy = orig[i].y - center.y;
      float cdx = dx * sx, cdy = dy * sy;
      float rdx = cdx * cosA - cdy * sinA;
      float rdy = cdx * sinA + cdy * cosA;
      [path
          moveAtIndex:i
                   to:(simd_float2){center.x + rdx / sx, center.y + rdy / sy}];

      float hcdx = orig[i].inX * sx, hcdy = orig[i].inY * sy;
      float hirx = hcdx * cosA - hcdy * sinA;
      float hiry = hcdx * sinA + hcdy * cosA;
      [path setInHandle:(simd_float2){hirx / sx, hiry / sy} atIndex:i];

      float ocdx = orig[i].outX * sx, ocdy = orig[i].outY * sy;
      float horx = ocdx * cosA - ocdy * sinA;
      float hory = ocdx * sinA + ocdy * cosA;
      [path setOutHandle:(simd_float2){horx / sx, hory / sy} atIndex:i];
    }
  }

  [self writePaths:self.paths];
  *forceUpdate = YES;
}

@end
#pragma clang diagnostic pop
