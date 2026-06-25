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

/// Total arc length (pixels) of `path`'s single contour - open OR closed (a
/// closed loop's length includes the closing edge back to its start) - sampled
/// the same way the stroke is tessellated. Returns 0 for a compound /
/// multi-contour or degenerate path (draw-on is a no-op there). The render uses
/// this to convert draw-on fractions to absolute arc distances.
float CanvasContourTotalArc(KKBezierPath *path, float outputWidth,
                            float outputHeight);

/// Tessellates the VISIBLE portion of a draw-on stroke for a single contour
/// (open or closed) into a triangle strip - the same KKVertex2D centered-pixel
/// space + edge-distance texcoord as CanvasTessellateStroke. The visible span
/// is arc fractions `[drawStart01, drawEnd01]` rotated by `offset01` around the
/// path: a closed loop reveals a single arc from a chosen point; an open path's
/// window wraps past its ends into up to two pieces. `startPullbackPx` /
/// `endPullbackPx` trim a little extra behind an endpoint marker (open, no
/// offset) so a filled marker covers the tip. Caps (`lineCap`) close each cut
/// end; width tapers by GLOBAL arc fraction so a partial reveal keeps the full
/// path's Start->End taper. `outArc` (when non-NULL) receives per-vertex arc
/// length for the dash fragment. Falls back to the whole stroke when the span
/// is full, and to a plain (untrimmed) tessellation on compound paths. Returns
/// the vertex count (0 if nothing is revealed).
NSUInteger CanvasTessellateStrokeDrawOn(
    KKBezierPath *path, float startWidth, float endWidth, float outputWidth,
    float outputHeight, uint8_t lineCap, uint8_t lineJoin, float drawStart01,
    float drawEnd01, float offset01, float startPullbackPx, float endPullbackPx,
    KKVertex2D *outVerts, NSUInteger maxVerts, float *_Nullable outArc);

/// Upper bound on the vertex count CanvasTessellateDottedStroke can emit for
/// `path` (one filled disc per dot). `dotWidth` / `dotGap` are in the same
/// scaled pixel units passed to the tessellator. Safe to over-allocate against.
NSUInteger CanvasDottedStrokeVertexCapacity(KKBezierPath *path, float dotWidth,
                                            float dotGap, float outputWidth,
                                            float outputHeight);

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
  float *hw; // per-vertex half-widths (length cap+1; [n] is the closing width)
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
/// vertex count written (0 if the path is too short or the buffer is too
/// small).
NSUInteger CanvasTessellateStroke(KKBezierPath *path, float startWidth,
                                  float endWidth, float outputWidth,
                                  float outputHeight, uint8_t lineCap,
                                  uint8_t lineJoin, KKVertex2D *outVerts,
                                  NSUInteger maxVerts);

/// As CanvasTessellateStroke, but uses `scratch` for the internal buffers when
/// non-NULL (see CanvasStrokeScratch). Pass NULL to malloc internally.
NSUInteger CanvasTessellateStrokeScratch(
    KKBezierPath *path, float startWidth, float endWidth, float outputWidth,
    float outputHeight, uint8_t lineCap, uint8_t lineJoin, KKVertex2D *outVerts,
    NSUInteger maxVerts, CanvasStrokeScratch *_Nullable scratch);

/// As CanvasTessellateStroke, but also fills `outArc` (when non-NULL, one float
/// per emitted vertex) with the arc length in pixels along the contour - the
/// dashed stroke draws this solid geometry and masks the dash pattern by arc
/// length in KKStrokeDashFragment, so corners are exactly the solid stroke's
/// corners. Each contour restarts the arc at 0. Pass `scratch` for the buffer
/// reuse (see CanvasStrokeScratch) or NULL. `outArc` must be at least as large
/// as the returned vertex count (size it the same as `outVerts`).
/// `trimStartPx` / `trimEndPx` shorten the (single open) contour by that arc
/// length at each end so an endpoint marker can cover the stroke end (0 = no
/// trim). Ignored for closed / compound paths.
NSUInteger CanvasTessellateStrokeArc(
    KKBezierPath *path, float startWidth, float endWidth, float outputWidth,
    float outputHeight, uint8_t lineCap, uint8_t lineJoin, KKVertex2D *outVerts,
    NSUInteger maxVerts, float trimStartPx, float trimEndPx,
    CanvasStrokeScratch *_Nullable scratch, float *_Nullable outArc);

/// Tessellates a DOTTED stroke of `path` (one filled disc per dot, placed by
/// PIXEL arc length so it survives the layer transform + the gradient bake).
/// The disc radius follows the Start -> End taper; `dotGap` is the gap between
/// dots (scaled by the render's strokeScale, like the widths); `phase` (px)
/// slides the pattern for the marching-ants animation. Returns the vertex count
/// written (draw as a TRIANGLE LIST).
///
/// `drawStart01`/`drawEnd01`/`offset01` are the draw-on reveal (arc fractions
/// 0..1 + offset, like CanvasTessellateStrokeDrawOn): only dots whose arc
/// position falls in the visible window are emitted, so the dotted pattern
/// draws on with the same window (and wraps on an offset, like the solid
/// stroke). Pass 0/1/0 for the whole pattern. Draw-on applies to a single
/// contour (open or closed); a compound path emits every dot.
NSUInteger CanvasTessellateDottedStroke(
    KKBezierPath *path, float startWidth, float endWidth, float outputWidth,
    float outputHeight, float dotGap, float phase, float drawStart01,
    float drawEnd01, float offset01, KKVertex2D *outVerts, NSUInteger maxVerts);

NS_ASSUME_NONNULL_END
