/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKShaderTypes.h>
#import <simd/simd.h>

@class KKBezierPath;

NS_ASSUME_NONNULL_BEGIN

/// Upper bound on the vertex count CanvasTessellateStroke can emit for `path`,
/// so the caller can size the buffer. Safe to over-allocate against.
NSUInteger CanvasStrokeVertexCapacity(KKBezierPath *path);

/// Reusable internal scratch (the per-contour polyline + arc-length buffers the
/// tessellator would otherwise malloc on every call). A repeated caller on ONE
/// thread - e.g. the mouse-move hit-test - keeps a single zero-initialized
/// instance and passes its address each call so the hot path doesn't churn the
/// allocator; it grows on demand and is freed with CanvasStrokeScratchFree (or
/// just leaked for the process lifetime, as a scratch normally is). NOT
/// thread-safe: one scratch per thread. The render path passes NULL (it may run
/// concurrently) and keeps the internal malloc/free.
typedef struct {
  simd_float2 *pts;
  float *frac;
  NSUInteger cap;
} CanvasStrokeScratch;

void CanvasStrokeScratchFree(CanvasStrokeScratch *scratch);

/// Tessellates a (optionally tapered) stroke of `path` into a triangle-strip of
/// KKVertex2D in CENTERED-PIXEL object space - the same space the image quads
/// use ((normalized - 0.5) * outputSize) - so the caller can hand the strip the
/// same CanvasComposedModelMatrix and have the stroke group / scale / tilt with
/// the layer. `textureCoordinate.y` carries the signed edge distance (+1 / -1)
/// that KKLineFragment turns into an antialiased edge; `.x` is unused.
///
/// Width is in PIXELS and interpolates linearly from `startWidth` at each
/// contour's first vertex to `endWidth` at its last, by normalized arc length
/// (per contour - a compound/boolean path tapers each subpath independently).
/// Pass startWidth == endWidth for a uniform stroke. The per-vertex offset
/// normal is computed in pixel space (the tangent is scaled by
/// outputWidth/Height before rotating, per the Y-axis convention) and mitred at
/// corners. `lineCap` ends an OPEN contour: 0 = butt (flat), 1 = round
/// (semicircle), 2 = square (extended by half-width). `lineJoin` (0 = miter,
/// 1 = round, 2 = bevel) styles the corners. A closed contour wraps (no caps),
/// so a taper there steps from end back to start at the closure. Returns the
/// vertex count written (0 if the path is too short or the buffer is too small).
NSUInteger CanvasTessellateStroke(KKBezierPath *path, float startWidth,
                                  float endWidth, float outputWidth,
                                  float outputHeight, uint8_t lineCap,
                                  uint8_t lineJoin, KKVertex2D *outVerts,
                                  NSUInteger maxVerts);

/// As CanvasTessellateStroke, but uses `scratch` for the internal buffers when
/// non-NULL (see CanvasStrokeScratch). Pass NULL to malloc internally.
NSUInteger CanvasTessellateStrokeScratch(KKBezierPath *path, float startWidth,
                                         float endWidth, float outputWidth,
                                         float outputHeight, uint8_t lineCap,
                                         uint8_t lineJoin, KKVertex2D *outVerts,
                                         NSUInteger maxVerts,
                                         CanvasStrokeScratch *_Nullable scratch);

NS_ASSUME_NONNULL_END
