/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKShaderTypes.h>

@class KKBezierPath;

NS_ASSUME_NONNULL_BEGIN

/// Upper bound on the vertex count CanvasTessellateStroke can emit for `path`,
/// so the caller can size the buffer. Safe to over-allocate against.
NSUInteger CanvasStrokeVertexCapacity(KKBezierPath *path);

/// Tessellates a constant-width stroke of `path` into a triangle-strip of
/// KKVertex2D in CENTERED-PIXEL object space - the same space the image quads
/// use ((normalized - 0.5) * outputSize) - so the caller can hand the strip the
/// same CanvasComposedModelMatrix and have the stroke group / scale / tilt with
/// the layer. `textureCoordinate.y` carries the signed edge distance (+1 / -1)
/// that KKLineFragment turns into an antialiased edge; `.x` is unused.
///
/// Width is uniform in PIXELS: the per-vertex offset normal is computed in
/// pixel space (the tangent is scaled by outputWidth/Height before rotating,
/// per the Y-axis convention) and mitred at corners. Open paths get butt ends;
/// closed paths wrap. Returns the vertex count written (0 if the path is too
/// short or the buffer is too small).
NSUInteger CanvasTessellateStroke(KKBezierPath *path, float strokeWidth,
                                  float outputWidth, float outputHeight,
                                  KKVertex2D *outVerts, NSUInteger maxVerts);

NS_ASSUME_NONNULL_END
