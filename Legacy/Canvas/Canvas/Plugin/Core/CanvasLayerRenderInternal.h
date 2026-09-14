/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// Render helpers split out of CanvasLayerRender.m's per-layer stroke encoder so
// the two heaviest concerns - the stroke/marker GRADIENT fill
// (CanvasVectorGradient.m) and the DRAW-ON reveal + endpoint-marker animation
// (CanvasDrawOnMarkers.m) - live beside, not inside, the encode loop. Internal,
// not a public API.

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKColorLanes.h>
#import <KeyframelessKit/KKShaderTypes.h>
#import <simd/simd.h>

@class KKBezierPath;
@class KKTimeline;

// The bbox+angle gradient fill, computed once from the stroke geometry (and,
// when present, the marker geometry so the gradient spans the WHOLE drawn
// shape) and then applied to both the stroke and the marker verts so they share
// one continuous gradient. Both modes pivot on the layer (bbox) centre: LINEAR
// runs along `dir` normalised by `halfExtent` (the bbox extent in that
// direction); RADIAL is a circle from the centre sized to `maxDim`.
typedef struct {
  simd_float2 center, dir;
  float halfExtent, maxDim;
  int type; // cv.gradientType
} CanvasGradientFill;

/// Compute the gradient fill from `geom`'s point bbox (padded by half the
/// stroke width), optionally extended by `extra` verts (e.g. the marker
/// geometry) so it reaches t=0/1 at the outermost drawn point. Angle matches
/// the circular knob (0 deg up, 90 right) -> object-space dir (sin, cos).
CanvasGradientFill
CanvasComputeGradientFill(KKBezierPath *geom, float imageWidth,
                          float imageHeight, float strokeStart, float strokeEnd,
                          float strokeScale, KKColorLanesValue cv,
                          const KKVertex2D *extra, NSUInteger extraCount);

/// Bake the per-vertex gradient position (0..1) into each strip vertex's
/// textureCoordinate.x (unused by the solid path), so KKGradientLineFragment
/// just samples the LUT.
void CanvasApplyGradientFill(KKVertex2D *verts, NSUInteger vc,
                             CanvasGradientFill g);

// Resolved draw-on + endpoint-marker render state for one stroked layer, lifted
// out of CanvasEncodeOneVectorLayer (the most-iterated logic, behind one
// boundary). The line is fed [lineStart, lineEnd] rotated by `offset`; the
// markers their animated size / pullback / trim. `active` gates the
// dashed/dotted draw-on + the cap-headroom bump; `collapsed` (raw span empty)
// means skip the stroke entirely.
typedef struct {
  float lineStart, lineEnd, offset;
  uint8_t startMarker, endMarker;
  float sMarkerPx, eMarkerPx;
  float startPullback, endPullback;
  float markerStartTrim, markerEndTrim;
  BOOL active;
  BOOL collapsed;
} CanvasDrawOnRender;

/// Read the layer's markers + draw-on lanes at `evalFrac` and resolve the line
/// window + per-end marker animation (the offset-spin branch keeps the markers
/// riding the shifted window ends; the non-offset branch grows each end's
/// marker in per its type). `geom` is the morphed display geometry (its arc
/// length sets the marker anchoring); `strokeStart`/`strokeEnd` are the
/// unscaled widths and `strokeScale` the render downscale.
CanvasDrawOnRender CanvasResolveStrokeDrawOn(
    KKBezierPath *path, KKBezierPath *geom, double evalFrac,
    NSString *overrideLayerID, KKTimeline *overrideTimeline, float strokeStart,
    float strokeEnd, float strokeScale, float imageWidth, float imageHeight);
