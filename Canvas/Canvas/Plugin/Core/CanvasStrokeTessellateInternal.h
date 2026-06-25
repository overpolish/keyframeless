/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// Shared contour helpers + tessellation constants used across the stroke
// tessellators (CanvasStrokeTessellate.m solid/dashed, CanvasStrokeDots.m
// dotted, CanvasStrokeDrawOn.m the write-on reveal). Internal - not a public API.

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKShaderTypes.h>
#import <simd/simd.h>

@class KKBezierPath;

#define kCanvasCapSegs 24 // semicircle segments for a round cap / half a dot
#define kCanvasAAPaddingPx 0.75f // solid core reaches the asked width

/// YES if the contour at index should be treated as closed (a compound path's
/// subcontours are all closed; a lone contour follows the path's own flag).
BOOL CanvasContourClosed(KKBezierPath *path, NSUInteger contourCount);

/// The largest per-contour polyline vertex count across `path`, used to size
/// the reused polyline buffer.
NSUInteger CanvasMaxContourPolyCap(KKBezierPath *path, BOOL closed);

/// Sample ONE contour into a centered-pixel polyline ((normalized - 0.5) *
/// outputSize), dropping near-duplicate samples. Returns the vertex count.
NSUInteger CanvasBuildContourPolyline(KKBezierPath *path, NSRange r,
                                      BOOL closed, float outW, float outH,
                                      simd_float2 *pts, NSUInteger maxPts);

/// Total arc length (pixels) of a built contour polyline, including the closing
/// edge back to pts[0] when `closed`.
float CanvasContourArcLength(const simd_float2 *pts, NSUInteger n, BOOL closed);

/// Trim `trimStart`/`trimEnd` px (arc length) off the ends of an OPEN polyline
/// pts[0..n) IN PLACE - dropping fully-trimmed points and moving the boundary
/// point to the trim distance. Returns the new vertex count (0 if trimmed away
/// entirely). Shared by the stroke strip and the marker tessellator (so an
/// Arrow marker can ride a draw-on tip).
NSUInteger CanvasTrimOpenPolyline(simd_float2 *pts, NSUInteger n,
                                  float trimStart, float trimEnd);

/// Emit ONE contour (or extracted sub-arc) as a KKVertex2D triangle strip,
/// reusing the miter/bevel/round join + butt/round/square cap machinery. `hw`
/// holds the per-vertex half-width (length n, + hw[n] for the closing width when
/// `closed`); `arcv` (same shape) the per-vertex arc length for the dash mask
/// (pass NULL for a solid stroke). `bridgeFromPrev` stitches onto the prior strip
/// with degenerate verts (across a contour gap / between draw-on pieces). Shared
/// with CanvasStrokeDrawOn.m. Returns the running vertex count.
NSUInteger CanvasEmitContourStrip(KKVertex2D *outVerts, NSUInteger vc,
                                  NSUInteger maxVerts, simd_float2 *pts,
                                  NSUInteger n, BOOL closed, const float *hw,
                                  const float *arcv, uint8_t lineCap,
                                  uint8_t lineJoin, BOOL bridgeFromPrev,
                                  float *outArc);
