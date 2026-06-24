/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// Shared contour helpers + tessellation constants used by both the solid/dashed
// stroke tessellation (CanvasStrokeTessellate.m) and the dotted stroke
// (CanvasStrokeDots.m). Internal to the stroke tessellator - not a public API.

#import <Foundation/Foundation.h>
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
