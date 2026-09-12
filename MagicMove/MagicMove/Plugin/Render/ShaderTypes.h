/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#pragma once
#include <simd/simd.h>
typedef struct {
  vector_float2 offset;
  float scale;
  float rotation;
  float aspect;
  float scaleY;
} MMTransform;
