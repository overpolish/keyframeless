/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import "CanvasLayerRender.h" // CanvasProjCtx
#import <CoreGraphics/CoreGraphics.h>
#import <Foundation/Foundation.h>
#import <simd/simd.h>

@class KKBezierPath;

NS_ASSUME_NONNULL_BEGIN

/// The live-corner widget for one anchor, computed in PROJECTED (object/canvas)
/// space so its resting offset is a fixed fraction of the canvas - invariant to
/// the layer transform / shape size, matching Rounded's radius handle (a fixed
/// canvas-px inset) rather than scaling with the path's local space. `valid` is
/// NO for open-path endpoints and degenerate (near-straight) corners. The
/// handle sits along the interior bisector at `baseOffsetObjPx +
/// currentRadius`, so it rests clear of the anchor dot and slides out as the
/// radius grows. The `*ObjPx` fields are in aspect-corrected object space
/// (object Y units, X scaled by aspect). A drag maps the cursor (object space)
/// to an object-space radius, then `localPerObjScale` converts it back to the
/// stored LOCAL radius.
typedef struct {
  BOOL valid;
  simd_float2 widgetObj;   // accent-handle position (object Y-up; draw / hit)
  simd_float2 anchorObjPx; // corner anchor in object pixel space (drag origin)
  simd_float2 bisObj; // unit interior bisector, object pixel space (drag axis)
  float baseOffsetObjPx;  // resting offset (a fixed fraction of the canvas)
  float maxRadiusObjPx;   // radius clamp (half the shorter edge's fillet)
  float localPerObjScale; // object-px radius × this = stored local radius
  BOOL atMax;             // the stored radius is at (or past) the clamp
} CanvasCornerWidget;

/// Compute the corner widget for anchor `i` of `path`, projecting through the
/// layer transform + ancestor groups at `frac` (so the offset is
/// canvas-relative, not shape-relative). `aspect` = canvasW / canvasH. Reads
/// the current stored radius for the slide position.
CanvasCornerWidget CanvasCornerWidgetObj(NSArray<KKBezierPath *> *layers,
                                         KKBezierPath *path, double frac,
                                         float aspect, NSUInteger i);

/// Context-reusing variant of CanvasCornerWidgetObj: the caller builds the
/// projection context ONCE for the path (CanvasProjCtxMake) and reuses it for
/// every corner, so a whole-path corner-widget pass is O(N) not O(N^2). Aspect
/// is carried in `ctx`.
CanvasCornerWidget CanvasCornerWidgetObjCtx(KKBezierPath *path, NSUInteger i,
                                            const CanvasProjCtx *ctx);

/// Expand a stored path (single corner anchors + per-anchor `cornerRadius`)
/// into the rounded geometry used for RENDER / DISPLAY: each anchor with radius
/// > 0 is replaced by a two-anchor circular fillet (a tangent arc), insetting
/// along both adjacent edges. Anchors with radius 0, endpoints of an open path,
/// and degenerate (near-straight) corners pass through unchanged. `aspect` =
/// canvasW / canvasH so the arc reads circular on a non-square canvas. The
/// result is a copy (all path properties preserved); the input is never
/// mutated, and the expanded geometry is never stored - the stored model keeps
/// single anchors so the radius interpolates cleanly in a morph.
///
/// No-op fast path: a path with no nonzero radii returns a plain copy.
KKBezierPath *CanvasPathByExpandingCorners(KKBezierPath *path, float aspect);

/// The inset distance `d` along each edge for a corner of interior angle
/// `theta` (radians) and radius `r`: d = r / tan(theta/2). Shared by the
/// expander and the OSC's drag<->radius mapping so the widget and the rendered
/// fillet agree.
double CanvasCornerInsetForRadius(double r, double theta);

/// Inverse: the radius produced by an inset `d` at interior angle `theta`.
double CanvasCornerRadiusForInset(double d, double theta);

NS_ASSUME_NONNULL_END
