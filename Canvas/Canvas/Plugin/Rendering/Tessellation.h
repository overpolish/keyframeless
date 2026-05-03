/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "ShaderTypes.h"
#import <KeyframelessKit/KeyframelessKit.h>
#import <simd/simd.h>

static const float kMiterLimit = 4.0f;

/// A sampled point along a path with cumulative arc length.
/// `atJoin` is YES when this sample sits at a curve→curve boundary on the
/// original path (last sample of curve c with curve c+1 to follow).
/// `nextCurveStartNormal` carries the raw normal at the start of curve c+1 so
/// trimmed tessellation can emit join geometry without re-walking the path.
typedef struct {
  simd_float2 position;
  simd_float2 normal;
  simd_float2 nextCurveStartNormal;
  float arcLength;
  bool atJoin;
} PathSample;

/// Compute the miter normal between two segment normals.
simd_float2 KKMiterNormal(simd_float2 n1, simd_float2 n2);

/// Compute the raw normal at a tessellation point.
simd_float2 KKNormalAtPoint(KKBezierPath *path, NSUInteger c,
                            NSUInteger segsPerCurve, NSUInteger i,
                            float outputWidth, float outputHeight);

/// Compute the raw normal at the start of a curve segment.
simd_float2 KKRawNormalAtSegStart(KKBezierPath *path, NSUInteger c,
                                  float outputWidth, float outputHeight);

/// Add a round cap connected to previous geometry via degenerate bridge.
NSUInteger KKAddRoundCap(CanvasVertex *vertices, NSUInteger vertexCount,
                         simd_float2 center, simd_float2 tangent,
                         simd_float2 normal, float halfWidth, BOOL isStart);

/// Emit a standalone round cap (no bridge from previous geometry).
NSUInteger KKEmitRoundCapStandalone(CanvasVertex *vertices,
                                    NSUInteger vertexCount, simd_float2 center,
                                    simd_float2 tangent, simd_float2 normal,
                                    float halfWidth, BOOL isStart);

/// Emit a degenerate bridge between two triangle strip pieces.
NSUInteger KKEmitBridge(CanvasVertex *vertices, NSUInteger vertexCount,
                        simd_float2 prevLast, simd_float2 nextFirst);

/// Emit bevel or round join geometry at a curve boundary.
/// lineJoin: 1 = round, 2 = bevel. Returns updated vertex count.
NSUInteger KKEmitJoinGeometry(CanvasVertex *vertices, NSUInteger vc,
                              simd_float2 jCenter, simd_float2 n1,
                              simd_float2 n2, float halfWidth,
                              uint8_t lineJoin);

/// Sample the entire path into a dense polyline with arc-length
/// parameterization. Caller must free the returned array.
NSUInteger KKSamplePathPolyline(KKBezierPath *path, float outputWidth,
                                float outputHeight, PathSample **outSamples);

/// Interpolate a PathSample between two samples at a given arc length.
PathSample KKLerpSample(const PathSample *a, const PathSample *b,
                        float targetArc);

/// Get the interpolated sample at an arc-length position.
PathSample KKSampleAtArc(const PathSample *samples, NSUInteger count, float arc,
                         NSUInteger *hint);

/// Tessellate a solid stroke path with tapering from startWidth to endWidth.
NSUInteger KKTessellatePath(KKBezierPath *path, float startWidth,
                            float endWidth, float outputWidth,
                            float outputHeight, uint8_t lineCap,
                            uint8_t lineJoin, CanvasVertex *vertices);

/// Tessellate a dashed stroke path. `startTrim`/`endTrim` are arc-length
/// offsets from each end (0 = no trim) used to render only a sub-range of the
/// path — drives the draw-on animation. `phaseOffset` is an arc-length shift
/// applied to the dash cycle for marching-ants animation.
NSUInteger KKTessellateDashedPath(KKBezierPath *path, float startWidth,
                                  float endWidth, float outputWidth,
                                  float outputHeight, float dashLength,
                                  float dashGap, uint8_t lineJoin,
                                  float startTrim, float endTrim,
                                  float phaseOffset, CanvasVertex *vertices);

/// Tessellate a dotted stroke path (isolated filled circles).
/// See `KKTessellateDashedPath` for trim/phase semantics.
NSUInteger KKTessellateDottedPath(KKBezierPath *path, float startWidth,
                                  float endWidth, float outputWidth,
                                  float outputHeight, float dotGap,
                                  float startTrim, float endTrim,
                                  float phaseOffset, CanvasVertex *vertices);

/// Tessellate a solid stroke with arc-length trimming at start/end.
/// Used when markers are present to pull the stroke back from the endpoints.
NSUInteger KKTessellateTrimmedPath(KKBezierPath *path, float startWidth,
                                   float endWidth, float outputWidth,
                                   float outputHeight, uint8_t lineCap,
                                   uint8_t lineJoin, float startTrim,
                                   float endTrim, CanvasVertex *vertices);
