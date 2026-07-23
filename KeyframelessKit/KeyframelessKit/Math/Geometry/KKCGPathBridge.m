/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// CoreGraphics <-> KKBezierPath conversion + property copying, shared across
// the outline / boolean / preview path operations (see KKCGPathBridge.h).

#import "KKCGPathBridge.h"

#import <CoreGraphics/CoreGraphics.h>

CGMutablePathRef CGPathCreateFromKKBezierPath(KKBezierPath *path) {
  CGMutablePathRef cgPath = CGPathCreateMutable();
  NSUInteger contours = path.contourCount;

  for (NSUInteger c = 0; c < contours; c++) {
    NSRange range = [path contourRangeAtIndex:c];
    if (range.length == 0)
      continue;

    KKBezierPoint first = [path pointAtIndex:range.location];
    CGPathMoveToPoint(cgPath, NULL, first.x, first.y);

    for (NSUInteger i = 1; i < range.length; i++) {
      NSUInteger idx = range.location + i;
      KKBezierPoint pt = [path pointAtIndex:idx];
      KKBezierPoint prev = [path pointAtIndex:idx - 1];

      BOOL hasCurve =
          (prev.type == KKBezierPointBezier || pt.type == KKBezierPointBezier);
      if (hasCurve) {
        CGFloat cp1x = prev.x + prev.outX;
        CGFloat cp1y = prev.y + prev.outY;
        CGFloat cp2x = pt.x + pt.inX;
        CGFloat cp2y = pt.y + pt.inY;
        CGPathAddCurveToPoint(cgPath, NULL, cp1x, cp1y, cp2x, cp2y, pt.x, pt.y);
      } else {
        CGPathAddLineToPoint(cgPath, NULL, pt.x, pt.y);
      }
    }

    if (path.closed && range.length > 1) {
      KKBezierPoint last =
          [path pointAtIndex:range.location + range.length - 1];
      BOOL hasCurve = (last.type == KKBezierPointBezier ||
                       first.type == KKBezierPointBezier);
      if (hasCurve) {
        CGFloat cp1x = last.x + last.outX;
        CGFloat cp1y = last.y + last.outY;
        CGFloat cp2x = first.x + first.inX;
        CGFloat cp2y = first.y + first.inY;
        CGPathAddCurveToPoint(cgPath, NULL, cp1x, cp1y, cp2x, cp2y, first.x,
                              first.y);
      }
      CGPathCloseSubpath(cgPath);
    }
  }
  return cgPath;
}

typedef struct {
  KKBezierPath *path;
  NSUInteger pointCount;
  NSUInteger contourStartIdx;
  BOOL needsContour;
} KKPathBuildContext;

static const float kMergeEpsilon = 1e-5f;

static void cgPathApplyCallback(void *info, const CGPathElement *element) {
  KKPathBuildContext *ctx = (KKPathBuildContext *)info;
  KKBezierPath *path = ctx->path;

  switch (element->type) {
  case kCGPathElementMoveToPoint: {
    if (ctx->pointCount > 0) {
      ctx->needsContour = YES;
    }
    if (ctx->needsContour) {
      [path beginContour];
      ctx->needsContour = NO;
    }
    ctx->contourStartIdx = path.count;
    simd_float2 pos = {(float)element->points[0].x,
                       (float)element->points[0].y};
    [path insertAtIndex:path.count position:pos];
    ctx->pointCount++;
    break;
  }
  case kCGPathElementAddLineToPoint: {
    simd_float2 pos = {(float)element->points[0].x,
                       (float)element->points[0].y};
    [path insertAtIndex:path.count position:pos];
    ctx->pointCount++;
    break;
  }
  case kCGPathElementAddCurveToPoint: {
    CGPoint cp1 = element->points[0];
    CGPoint cp2 = element->points[1];
    CGPoint end = element->points[2];

    if (path.count > 0) {
      NSUInteger prevIdx = path.count - 1;
      KKBezierPoint prev = [path pointAtIndex:prevIdx];
      simd_float2 outH = {(float)(cp1.x - prev.x), (float)(cp1.y - prev.y)};
      [path setOutHandle:outH atIndex:prevIdx];
      [path setType:KKBezierPointBezier atIndex:prevIdx];
    }

    simd_float2 pos = {(float)end.x, (float)end.y};
    [path insertAtIndex:path.count position:pos];
    NSUInteger newIdx = path.count - 1;
    simd_float2 inH = {(float)(cp2.x - end.x), (float)(cp2.y - end.y)};
    [path setInHandle:inH atIndex:newIdx];
    [path setType:KKBezierPointBezier atIndex:newIdx];
    ctx->pointCount++;
    break;
  }
  case kCGPathElementAddQuadCurveToPoint: {
    CGPoint cpQ = element->points[0];
    CGPoint end = element->points[1];

    if (path.count > 0) {
      NSUInteger prevIdx = path.count - 1;
      KKBezierPoint prev = [path pointAtIndex:prevIdx];
      float cx1 = prev.x + (2.0f / 3.0f) * ((float)cpQ.x - prev.x);
      float cy1 = prev.y + (2.0f / 3.0f) * ((float)cpQ.y - prev.y);
      simd_float2 outH = {cx1 - prev.x, cy1 - prev.y};
      [path setOutHandle:outH atIndex:prevIdx];
      [path setType:KKBezierPointBezier atIndex:prevIdx];

      float cx2 = (float)end.x + (2.0f / 3.0f) * ((float)cpQ.x - (float)end.x);
      float cy2 = (float)end.y + (2.0f / 3.0f) * ((float)cpQ.y - (float)end.y);
      simd_float2 pos = {(float)end.x, (float)end.y};
      [path insertAtIndex:path.count position:pos];
      NSUInteger newIdx = path.count - 1;
      simd_float2 inH = {cx2 - (float)end.x, cy2 - (float)end.y};
      [path setInHandle:inH atIndex:newIdx];
      [path setType:KKBezierPointBezier atIndex:newIdx];
      ctx->pointCount++;
    }
    break;
  }
  case kCGPathElementCloseSubpath: {
    // CGPath boolean results often end a subpath with a curve/line back to
    // the move-to point, producing a duplicate at the contour start.
    // Merge: transfer the last point's inHandle to the first point and
    // remove the duplicate.
    if (path.count > ctx->contourStartIdx + 1) {
      KKBezierPoint last = [path pointAtIndex:path.count - 1];
      KKBezierPoint first = [path pointAtIndex:ctx->contourStartIdx];
      float dx = last.x - first.x;
      float dy = last.y - first.y;
      BOOL merged = (fabsf(dx) < kMergeEpsilon && fabsf(dy) < kMergeEpsilon);
      if (merged) {
        // Transfer inHandle from duplicate to contour start.
        if (last.type == KKBezierPointBezier) {
          [path setInHandle:(simd_float2){last.inX, last.inY}
                    atIndex:ctx->contourStartIdx];
          [path setType:KKBezierPointBezier atIndex:ctx->contourStartIdx];
        }
        [path removeAtIndex:path.count - 1];
        ctx->pointCount--;
      }
    }
    break;
  }
  }
}

KKBezierPath *KKBezierPathFromCGPath(CGPathRef cgPath) {
  KKBezierPath *path = [[KKBezierPath alloc] init];
  path.closed = YES;
  KKPathBuildContext ctx = {
      .path = path, .pointCount = 0, .contourStartIdx = 0, .needsContour = NO};
  CGPathApply(cgPath, &ctx, cgPathApplyCallback);
  return path;
}

// A path-op RESULT must sit where its source did: inherit the source's group
// membership AND its layer transform. Without this the result renders at the
// raw stored geometry - offset by whatever translate/scale/rotation the source
// carried, and outside the source's group. (Centerline already does this via
// CenterlineCopyStyle; outline + boolean didn't, which is the "offset by the
// stroke width + drops the group" bug.)
void KKPathCopyPlacementProperties(KKBezierPath *dst, KKBezierPath *src) {
  dst.parentGroupID = src.parentGroupID;
  dst.transformEnabled = src.transformEnabled;
  dst.translateX = src.translateX;
  dst.translateY = src.translateY;
  dst.scaleX = src.scaleX;
  dst.scaleY = src.scaleY;
  dst.rotationZ = src.rotationZ;
  dst.anchorX = src.anchorX;
  dst.anchorY = src.anchorY;
}

void KKPathCopyStyleProperties(KKBezierPath *dst, KKBezierPath *src) {
  dst.strokeEnabled = src.strokeEnabled;
  dst.strokeWidth = src.strokeWidth;
  dst.endWidth = src.endWidth;
  dst.strokeR = src.strokeR;
  dst.strokeG = src.strokeG;
  dst.strokeB = src.strokeB;
  dst.opacity = src.opacity;
  dst.lineCap = src.lineCap;
  dst.lineJoin = src.lineJoin;
  dst.strokeStyle = src.strokeStyle;
  dst.dashLength = src.dashLength;
  dst.dashGap = src.dashGap;
  dst.dotGap = src.dotGap;
  dst.fillEnabled = src.fillEnabled;
  dst.fillR = src.fillR;
  dst.fillG = src.fillG;
  dst.fillB = src.fillB;
  dst.fillTint = src.fillTint;
  dst.sketchEnabled = src.sketchEnabled;
  dst.sketchRoughness = src.sketchRoughness;
  dst.sketchBowing = src.sketchBowing;
  dst.sketchStrokes = src.sketchStrokes;
  dst.sketchFillStyle = src.sketchFillStyle;
  dst.sketchFillGap = src.sketchFillGap;
  dst.sketchFillAngle = src.sketchFillAngle;
  dst.sketchFillWeight = src.sketchFillWeight;
  dst.sketchSeed = src.sketchSeed;
  dst.startMarker = src.startMarker;
  dst.endMarker = src.endMarker;
  dst.startMarkerSize = src.startMarkerSize;
  dst.endMarkerSize = src.endMarkerSize;
}
