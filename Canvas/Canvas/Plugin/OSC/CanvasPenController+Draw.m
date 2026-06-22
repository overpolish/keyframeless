/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasPathMorph.h" // morphed-at-frac geometry
#import "CanvasPenController_Internal.h"
#import <KeyframelessKit/KKBezierPath.h>

#define kPenCurveSamples 24 // literal so the on-stack curve[] isn't a VLA

// An anchor for drawing: position + the two handle offsets (Y-up object space).
typedef struct {
  CGPoint pos;
  CGPoint out;
  CGPoint in;
} PenAnchor;

static simd_float2 PenEvalCubic(simd_float2 p0, simd_float2 c0, simd_float2 c1,
                                simd_float2 p1, float t) {
  float u = 1.0f - t;
  return u * u * u * p0 + 3.0f * u * u * t * c0 + 3.0f * u * t * t * c1 +
         t * t * t * p1;
}

// The public -draw (declared in CanvasPenController.h) is implemented here as
// part of the intentional category split - silence the warning that it's not in
// the primary @implementation (which suppresses the matching -Wincomplete).
#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation CanvasPenController (Draw)

- (void)draw {
  if (![_surface penToolActive])
    return; // nothing to draw when the pen tool isn't active (no stale ghost)
  // Grid-snap ghost: where the next click will land (shown while hovering with
  // snap on, even before the first point).
  if ([_surface penGridSnapping] && _cursorValid && !_pendingActive &&
      !_closing)
    [_surface penDrawDotAtObj:_cursorObj ghost:YES hovered:NO active:NO];

  // Idle: highlight whichever of the SELECTED open path's end anchors the
  // cursor is over, so it's clear a click continues from that tip (drawn on top
  // of the path-edit OSC's normal anchors). Either end works (last appends,
  // first reverses then appends).
  if (!_layerID && !_hasFirst && !_pendingActive && _cursorValid) {
    KKBezierPath *rb = [self _resumableBase];
    KKBezierPath *rw =
        rb ? CanvasPathMorphedAtFraction(rb, [_surface penEditFraction]) : nil;
    if (rw.count >= 1) {
      CGPoint c = [_surface penSurfacePointFromObj:_cursorObj];
      double rr2 = kPenCloseRadiusPx * kPenCloseRadiusPx;
      NSUInteger ends[2] = {rw.count - 1, 0};
      NSUInteger nEnds = rw.count >= 2 ? 2 : 1;
      for (NSUInteger e = 0; e < nEnds; e++) {
        KKBezierPoint ep = [rw pointAtIndex:ends[e]];
        CGPoint es = [_surface penSurfacePointFromObj:CGPointMake(ep.x, ep.y)];
        if ((es.x - c.x) * (es.x - c.x) + (es.y - c.y) * (es.y - c.y) <= rr2) {
          [_surface penDrawWarnDotAtObj:CGPointMake(ep.x, ep.y)];
          break;
        }
      }
    }
  }

  KKBezierPath *layer = [self _layer];
  if (_layerID && !layer) { // the layer was undone away - end cleanly
    [self _endSession];
    return;
  }
  // Base anchors: the committed layer's geometry AS SHOWN at this fraction (the
  // keypose snapshot for an animated resumed path), or the transient held first
  // point (before a 2nd point creates the layer).
  KKBezierPath *geo = layer ? [self _workingLayer] : nil;
  NSUInteger n = geo ? geo.count : (_hasFirst ? 1 : 0);
  if (n == 0 && !_pendingActive)
    return;
  PenAnchor *base = n ? malloc(n * sizeof(PenAnchor)) : NULL;
  if (geo) {
    for (NSUInteger i = 0; i < n; i++) {
      KKBezierPoint pt = [geo pointAtIndex:i];
      base[i] =
          (PenAnchor){CGPointMake(pt.x, pt.y), CGPointMake(pt.outX, pt.outY),
                      CGPointMake(pt.inX, pt.inY)};
    }
  } else if (_hasFirst) {
    base[0] = (PenAnchor){_firstPos, _firstOut, _firstIn};
  }

  // Closing-drag preview: the closing segment (last anchor -> first anchor)
  // with the first anchor's dragged IN handle, plus the first anchor's smoothed
  // handles (override the base so the handle-drawing loop shows them being
  // pulled).
  if (_closing && _closeDragging && n >= 2) {
    PenAnchor last = base[n - 1], first = base[0];
    simd_float2 p0 = {(float)last.pos.x, (float)last.pos.y};
    simd_float2 c0 = {(float)(last.pos.x + last.out.x),
                      (float)(last.pos.y + last.out.y)};
    simd_float2 p1 = {(float)first.pos.x, (float)first.pos.y};
    simd_float2 c1 = {(float)(first.pos.x + _closeIn.x),
                      (float)(first.pos.y + _closeIn.y)};
    CGPoint curve[kPenCurveSamples + 1];
    for (NSUInteger s = 0; s <= kPenCurveSamples; s++) {
      simd_float2 pt =
          PenEvalCubic(p0, c0, c1, p1, (float)s / kPenCurveSamples);
      curve[s] = CGPointMake(pt.x, pt.y);
    }
    [_surface penDrawCurveObjPoints:curve count:kPenCurveSamples + 1];
    base[0].out = _closeOut;
    base[0].in = _closeIn;
  }

  // The segment being formed: from the last base anchor to the pending / cursor
  // point. Always a cubic so it honours the last anchor's OUT handle and the
  // pending point's live IN handle while dragging.
  if (n >= 1 && !_closing && (_pendingActive || _cursorValid)) {
    PenAnchor a = base[n - 1];
    CGPoint endObj = _pendingActive ? _pendingPos : _cursorObj;
    CGPoint inH = _handleDragging ? _dragIn : CGPointZero;
    simd_float2 p0 = {(float)a.pos.x, (float)a.pos.y};
    simd_float2 c0 = {(float)(a.pos.x + a.out.x), (float)(a.pos.y + a.out.y)};
    simd_float2 p1 = {(float)endObj.x, (float)endObj.y};
    simd_float2 c1 = {p1.x + (float)inH.x, p1.y + (float)inH.y};
    CGPoint curve[kPenCurveSamples + 1];
    for (NSUInteger s = 0; s <= kPenCurveSamples; s++) {
      simd_float2 pt =
          PenEvalCubic(p0, c0, c1, p1, (float)s / kPenCurveSamples);
      curve[s] = CGPointMake(pt.x, pt.y);
    }
    [_surface penDrawCurveObjPoints:curve count:kPenCurveSamples + 1];
  }

  // Tangent handles for every base anchor + the pending point's live ones.
  for (NSUInteger i = 0; i < n; i++) {
    [self _drawHandleAtAnchor:base[i].pos offset:base[i].out];
    [self _drawHandleAtAnchor:base[i].pos offset:base[i].in];
  }
  if (_pendingActive) {
    [self _drawHandleAtAnchor:_pendingPos offset:_dragOut];
    [self _drawHandleAtAnchor:_pendingPos offset:_dragIn];
  }

  // Anchor dots; the first / last highlight when hovered (close / finish
  // zones).
  BOOL nearFirst = NO, nearLast = NO;
  if (_cursorValid && !_pendingActive) {
    CGPoint c = [_surface penSurfacePointFromObj:_cursorObj];
    double r2 = kPenCloseRadiusPx * kPenCloseRadiusPx;
    if (n >= 2) {
      CGPoint f = [_surface penSurfacePointFromObj:base[0].pos];
      nearFirst = ((f.x - c.x) * (f.x - c.x) + (f.y - c.y) * (f.y - c.y) <= r2);
    }
    if (n >= 2 && !nearFirst) {
      CGPoint l = [_surface penSurfacePointFromObj:base[n - 1].pos];
      nearLast = ((l.x - c.x) * (l.x - c.x) + (l.y - c.y) * (l.y - c.y) <= r2);
    }
  }
  for (NSUInteger i = 0; i < n; i++) {
    BOOL hovered = (i == 0 && nearFirst) || (i == n - 1 && nearLast);
    [_surface penDrawDotAtObj:base[i].pos ghost:NO hovered:hovered active:NO];
  }
  if (_pendingActive)
    [_surface penDrawDotAtObj:_pendingPos ghost:NO hovered:NO active:YES];
  free(base);
}

- (void)_drawHandleAtAnchor:(CGPoint)anchorObj offset:(CGPoint)offset {
  if (fabs(offset.x) + fabs(offset.y) < 1e-6)
    return;
  [_surface penDrawHandleFromObj:anchorObj
                           toObj:CGPointMake(anchorObj.x + offset.x,
                                             anchorObj.y + offset.y)];
}

@end

#pragma clang diagnostic pop
