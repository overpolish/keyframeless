/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// CPU-side colour helpers shared by the FCP render and the mini-viewer. Control
// colours are converted from gamma sRGB to OKLab once here, then interpolated
// perceptually in the shader. Not for Metal (uses libm); guarded just in case.
#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>
#import <math.h>
#import <string.h>

#import "ShaderTypes.h"

/// The default number of colour points (until dynamic add/remove lands).
#define KK_MESH_POINT_COUNT 4

/// Gamma-encoded sRGB (0..1) + alpha -> OKLab (L, a, b, alpha).
static inline vector_float4 MeshSRGBToOklab(float r, float g, float b,
                                            float a) {
#define KK_SRGB_LIN(c)                                                         \
  ((c) <= 0.04045f ? (c) / 12.92f : powf(((c) + 0.055f) / 1.055f, 2.4f))
  float rl = KK_SRGB_LIN(r), gl = KK_SRGB_LIN(g), bl = KK_SRGB_LIN(b);
#undef KK_SRGB_LIN

  float l = 0.4122214708f * rl + 0.5363325363f * gl + 0.0514459929f * bl;
  float m = 0.2119034982f * rl + 0.6806995451f * gl + 0.1073969566f * bl;
  float s = 0.0883024619f * rl + 0.2817188376f * gl + 0.6299787005f * bl;

  float l_ = cbrtf(l), m_ = cbrtf(m), s_ = cbrtf(s);

  vector_float4 out;
  out.x = 0.2104542553f * l_ + 0.7936177850f * m_ - 0.0040720468f * s_;
  out.y = 1.9779984951f * l_ - 2.4285922050f * m_ + 0.4505937099f * s_;
  out.z = 0.0259040371f * l_ + 0.7827717662f * m_ - 0.8086757660f * s_;
  out.w = a;
  return out;
}

/// Default aurora colours (purple / pink / blue / teal), gamma sRGB + alpha,
/// index-aligned with kMeshDefaultPositions. Seeds the lane templates and the
/// render fallback so an un-edited instance and the inspector agree. Until
/// KKPalette generates them.
static const float kMeshDefaultColorsSRGB[KK_MESH_POINT_COUNT][4] = {
    {0.55f, 0.36f, 0.96f, 1.0f}, // purple
    {0.98f, 0.45f, 0.65f, 1.0f}, // pink
    {0.30f, 0.55f, 0.98f, 1.0f}, // blue
    {0.40f, 0.85f, 0.80f, 1.0f}, // teal
};

/// Default point positions (normalized 0..1): the four frame corners.
static const float kMeshDefaultPositions[KK_MESH_POINT_COUNT][2] = {
    {0.0f, 0.0f},
    {1.0f, 0.0f},
    {0.0f, 1.0f},
    {1.0f, 1.0f},
};

/// Default Gaussian falloff size (normalized 0..1) for a fresh point.
#define KK_MESH_DEFAULT_SPREAD 0.42f

/// Build a freeform point set from `count` positions (0..1), per-point spreads
/// (NULL = default), and gamma-sRGB+alpha colours. Colours -> OKLab; the shader
/// blends by per-point Gaussian falloff.
static inline MeshGridUniforms MeshBuildPoints(int count, const float pos[][2],
                                               const float *spreads,
                                               const float col[][4]) {
  MeshGridUniforms g;
  memset(&g, 0, sizeof(g));
  if (count > KK_MESH_MAX_VERTS)
    count = KK_MESH_MAX_VERTS;
  g.count = count;
  for (int i = 0; i < count; i++) {
    g.points[i] = (vector_float2){pos[i][0], pos[i][1]};
    g.spreads[i] = spreads ? spreads[i] : KK_MESH_DEFAULT_SPREAD;
    g.colorsOklab[i] =
        MeshSRGBToOklab(col[i][0], col[i][1], col[i][2], col[i][3]);
  }
  return g;
}

static inline MeshGridUniforms MeshDefaultGrid(void) {
  return MeshBuildPoints(KK_MESH_POINT_COUNT, kMeshDefaultPositions, NULL,
                         kMeshDefaultColorsSRGB);
}

/// Generic per-point lane label ("Point 1", "Point 2", ...). One composite lane
/// per point: [x, y, spread, r, g, b, a]. One-based to read naturally.
static inline NSString *MeshPointLabel(int i) {
  return [NSString stringWithFormat:@"Point %d", i + 1];
}
/// 0-based index if `label` is "<prefix> N", else -1.
static inline int MeshIndexForLabel(NSString *label, NSString *prefix) {
  if (![label hasPrefix:prefix])
    return -1;
  return [label substringFromIndex:prefix.length].intValue - 1;
}

#endif // __METAL_VERSION__
