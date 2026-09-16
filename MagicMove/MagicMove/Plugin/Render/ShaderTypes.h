/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#include <simd/simd.h>
typedef struct {
  vector_float2 offset;
  float scale;
  float rotation;
  float aspect;
  float scaleY;
  float opacity;
  // Additional Euler axes, in radians. This transient render payload is rebuilt
  // by pluginState; saved effects persist their property payloads separately.
  float rotationX;
  float rotationY;
  // Authored full-resolution pixels relative to the image centre in the
  // plugin-state payload; the renderer converts to a fraction of the full
  // frame before upload, so the pivot is resolution independent.
  vector_float2 anchor;
  // The delivered source tile as a fraction of the full source image, y
  // measured from the image top to match the quad's texture coordinates. The
  // host may hand over less than the plugin requested, so frame coordinates
  // must be mapped through this before sampling.
  vector_float2 sourceOrigin;
  vector_float2 sourceSize;
  // The destination image expressed in source-frame fractions, y measured from
  // the frame top. The output grows past the frame so moved content survives
  // for the host's own transform, so destination coordinates are not frame
  // coordinates and must be mapped before the inverse transform.
  vector_float2 frameOrigin;
  vector_float2 frameScale;
  // Gaussian sigma in full-resolution pixels; scaled to texture pixels at render.
  // A zero value is the identity path.
  float blurPixels;
} MMTransform;
