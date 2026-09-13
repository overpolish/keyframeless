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
  // Authored full-resolution pixels relative to the image centre. The renderer
  // converts to texture pixels before the shader normalizes them.
  vector_float2 anchorPixels;
  // Gaussian sigma in full-resolution pixels; scaled to texture pixels at render.
  // A zero value is the identity path.
  float blurPixels;
} MMTransform;
