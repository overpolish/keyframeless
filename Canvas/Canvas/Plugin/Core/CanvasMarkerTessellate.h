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

/// Marker type ids, shared with `KKBezierPath.startMarker` / `endMarker` and
/// the `CanvasMarkerGlyphs` pill order.
typedef NS_ENUM(uint8_t, CanvasMarkerType) {
  CanvasMarkerNone = 0,
  CanvasMarkerArrow = 1,     // filled triangle, tip at the endpoint
  CanvasMarkerCircle = 2,    // filled disc, centred on the endpoint
  CanvasMarkerSquare = 3,    // filled square, centred on the endpoint
  CanvasMarkerArrowhead = 4, // open chevron (two stroked arms)
  CanvasMarkerLine = 5,      // perpendicular tick bar
};

/// Upper bound on the vertex count CanvasTessellateMarkers can emit (both
/// ends). Safe to over-allocate against.
NSUInteger CanvasMarkerVertexCapacity(void);

/// How far (px, arc length) the stroke should be trimmed back from an endpoint
/// so a filled marker fully covers the stroke end instead of the stroke poking
/// out past it. Only the filled Arrow narrows toward its tip and needs this;
/// the centred Circle/Square, the open Arrowhead and the Line tick return 0.
/// `markerSizePx` is the marker's scaled-pixel extent at that end.
float CanvasMarkerPullback(uint8_t markerType, float markerSizePx);

/// Tessellates the start and/or end markers of `path` into a TRIANGLE LIST of
/// KKVertex2D in the same centered-pixel object space the stroke uses
/// ((normalized - 0.5) * outputSize), so the caller hands them the same
/// CanvasComposedModelMatrix as the stroke. `textureCoordinate.y` carries the
/// signed edge distance (rim ±1, interior 0) that KKLineFragment turns into an
/// antialiased edge - filled markers fan from a ty=0 centroid to a ty=1 rim,
/// open markers are ty ±1 rails, exactly like the stroke + dotted disc.
///
/// Markers only apply to an OPEN single contour (the renderer treats closed /
/// compound paths as having no free ends); the function returns 0 otherwise.
/// `startSizePx` / `endSizePx` are the marker extents and `startStrokePx` /
/// `endStrokePx` the open-marker bar thicknesses, all in SCALED pixels (already
/// multiplied by the render's strokeScale). Returns the vertex count written.
NSUInteger CanvasTessellateMarkers(KKBezierPath *path, float outputWidth,
                                   float outputHeight, uint8_t startMarker,
                                   uint8_t endMarker, float startSizePx,
                                   float endSizePx, float startStrokePx,
                                   float endStrokePx, KKVertex2D *outVerts,
                                   NSUInteger maxVerts);

NS_ASSUME_NONNULL_END
