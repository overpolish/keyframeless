/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// CPU-side colour helpers shared by the FCP render and the mini-viewer. The
// Mesh Gradient takes a flat list of colour swatches (no positions - the shader
// places the spots procedurally) plus a few scalar controls. Not for Metal
// (uses libm); guarded just in case.
#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>
#import <math.h>
#import <string.h>

#import "ShaderTypes.h"

/// The default number of colour swatches (until dynamic add/remove lands).
#define KK_MESH_COLOR_COUNT 4

/// Default swatch colours (purple / pink / blue / teal), gamma sRGB + alpha.
/// Seeds the lane templates and the render fallback so an un-edited instance
/// and the inspector agree. Until KKPalette generates them.
static const float kMeshDefaultColorsSRGB[KK_MESH_COLOR_COUNT][4] = {
    {0.55f, 0.36f, 0.96f, 1.0f}, // purple
    {0.98f, 0.45f, 0.65f, 1.0f}, // pink
    {0.30f, 0.55f, 0.98f, 1.0f}, // blue
    {0.40f, 0.85f, 0.80f, 1.0f}, // teal
};

/// Mesh Gradient (paper-design port) scalar defaults.
#define KK_MESH_GRAD_DEFAULT_DISTORTION 0.80f
#define KK_MESH_GRAD_DEFAULT_SWIRL 0.10f
#define KK_MESH_GRAD_DEFAULT_SPEED 1.0f // time multiplier (1 = source rate)
#define KK_MESH_GRAD_DEFAULT_SEED 0.0f
#define KK_MESH_GRAD_DEFAULT_GRAINMIXER 0.0f
/// Final grain overlay amount (0..1). A subtle default so a fresh instance has
/// the tasteful film grain every reference gradient uses, out of the box.
#define KK_MESH_DEFAULT_GRAIN 0.06f

/// Fallback Mesh Gradient uniforms (the default palette as spots) so an
/// un-edited instance still renders before the colour lanes resolve.
static inline MeshGradientUniforms MeshGradientDefault(void) {
  MeshGradientUniforms g;
  memset(&g, 0, sizeof(g));
  g.colorsCount = KK_MESH_COLOR_COUNT;
  for (int i = 0; i < KK_MESH_COLOR_COUNT; i++) {
    const float *c = kMeshDefaultColorsSRGB[i];
    g.colors[i] = (vector_float4){c[0], c[1], c[2], c[3]};
  }
  g.distortion = KK_MESH_GRAD_DEFAULT_DISTORTION;
  g.swirl = KK_MESH_GRAD_DEFAULT_SWIRL;
  g.speed = KK_MESH_GRAD_DEFAULT_SPEED;
  g.seed = KK_MESH_GRAD_DEFAULT_SEED;
  g.grainMixer = KK_MESH_GRAD_DEFAULT_GRAINMIXER;
  g.grainOverlay = KK_MESH_DEFAULT_GRAIN;
  g.time = 0.0f;
  return g;
}

/// Generic per-swatch lane label ("Color 1", "Color 2", ...). One [r,g,b,a]
/// colour lane per swatch. One-based to read naturally.
static inline NSString *MeshColorLabel(int i) {
  return [NSString stringWithFormat:@"Color %d", i + 1];
}
/// 0-based index if `label` is "<prefix> N", else -1.
static inline int MeshIndexForLabel(NSString *label, NSString *prefix) {
  if (![label hasPrefix:prefix])
    return -1;
  return [label substringFromIndex:prefix.length].intValue - 1;
}

#endif // __METAL_VERSION__
