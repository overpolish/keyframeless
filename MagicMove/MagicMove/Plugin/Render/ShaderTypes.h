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
  // Additional Euler axes, in radians. Appended to preserve the existing
  // transform layout for older unblurred plugin states.
  float rotationX;
  float rotationY;
} MMTransform;
