/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <simd/simd.h>

@class KKBezierPath;

NS_ASSUME_NONNULL_BEGIN

/// Pure path / point geometry shared by the path-edit controller and the pen
/// controller: no surface, no state, just maths on a KKBezierPath in its own
/// (Y-up) local space. Kept separate so it stays reusable + testable.

/// Squared distance from surface point `s` to (x,y).
static inline double CanvasDist2(CGPoint s, double x, double y) {
  return (s.x - x) * (s.x - x) + (s.y - y) * (s.y - y);
}

/// Component-wise linear interpolation a->b at t.
static inline simd_float2 CanvasLerp2(simd_float2 a, simd_float2 b, float t) {
  return a + (b - a) * t;
}

/// Squared distance from (px,py) to segment a-b, with the clamped param along
/// it written to `outT`.
double CanvasDistPtToSeg(double px, double py, CGPoint a, CGPoint b,
                         double *outT);

/// Split the cubic (or line) segment `seg`->`seg+1` of `path` at parameter `t`,
/// inserting a new anchor at seg+1 that preserves the curve. A segment is
/// straight only when BOTH endpoints are Linear (matching
/// -evaluatePointAtIndex:); there we insert a plain Linear point. Otherwise de
/// Casteljau gives the split: the new anchor is Bezier (so both sub-segments
/// evaluate as cubics) and the neighbours' adjacent handles shorten to keep the
/// shape identical.
KKBezierPath *CanvasPathByInsertingAnchor(KKBezierPath *path, NSUInteger seg,
                                          double tIn);

/// Give anchor `i` auto-smooth tangents from its neighbours (Catmull-Rom-ish:
/// the tangent runs along prev->next, each side scaled to ~1/3 of its segment).
/// The direction is computed in PIXEL space (object X scaled by `aspect`) so
/// the curve looks smooth on a non-square canvas, then converted back to object
/// offsets. Mutates `path` in place.
void CanvasPathAutoSmoothAnchor(KKBezierPath *path, NSUInteger i, float aspect);

NS_ASSUME_NONNULL_END
