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

/// The default number of colour swatches a fresh instance starts with. Users
/// add/remove swatches (2..KK_MESH_COLOR_MAX) via the Colors section; the live
/// count is stored in the "Color Count" lane.
#define KK_MESH_COLOR_COUNT 4

/// Absolute maximum number of swatch lanes ("Color 1".."Color 10"). Matches the
/// widest shader palette array (KK_MESH_GRAD_COLORS). Per-Type caps below may
/// be lower (see MeshMaxColorsForType).
#define KK_MESH_COLOR_MAX KK_MESH_GRAD_COLORS

/// Default swatch colours, gamma sRGB + alpha. The first four (purple / pink /
/// blue / teal) seed a fresh 4-colour instance; 5..10 extend the palette so
/// newly-added swatches get a sensible starting hue. Seeds the lane templates
/// and the render fallback so an un-edited instance and the inspector agree.
static const float kMeshDefaultColorsSRGB[KK_MESH_COLOR_MAX][4] = {
    {0.55f, 0.36f, 0.96f, 1.0f}, // purple
    {0.98f, 0.45f, 0.65f, 1.0f}, // pink
    {0.30f, 0.55f, 0.98f, 1.0f}, // blue
    {0.40f, 0.85f, 0.80f, 1.0f}, // teal
    {0.98f, 0.70f, 0.35f, 1.0f}, // amber
    {0.55f, 0.85f, 0.45f, 1.0f}, // green
    {0.98f, 0.85f, 0.40f, 1.0f}, // yellow
    {0.95f, 0.40f, 0.45f, 1.0f}, // coral
    {0.65f, 0.45f, 0.90f, 1.0f}, // violet
    {0.35f, 0.80f, 0.95f, 1.0f}, // cyan
};

/// The maximum number of palette swatches a given Type actually consumes. Most
/// Types use the full 10; Grainy's array caps at 7 and God Rays uses up to 5.
static inline int MeshMaxColorsForType(int type) {
  switch (type) {
  case MeshType_GrainGradient:
    return KK_GRAIN_GRAD_COLORS; // 7
  case MeshType_GodRays:
    return 5;
  default:
    return KK_MESH_GRAD_COLORS; // 10
  }
}

/// Mesh Gradient (paper-design port) scalar defaults.
#define KK_MESH_GRAD_DEFAULT_DISTORTION 0.80f
#define KK_MESH_GRAD_DEFAULT_SWIRL 0.10f
#define KK_MESH_GRAD_DEFAULT_SPEED 1.0f // time multiplier (1 = source rate)
#define KK_MESH_GRAD_DEFAULT_SEED 0.0f

/// Core film-grain overlay, shared by every Type (MeshCommonUniforms). A subtle
/// nonzero default so a fresh instance has tasteful grain that also breaks up
/// 8-bit banding out of the box.
#define KK_CORE_GRAIN_DEFAULT 0.06f    // amount (0..1)
#define KK_CORE_GRAINSIZE_DEFAULT 2.0f // grain cell size in whole pixels

/// Per-Type grain multiplier: Grainy reads stylistically grainy by default;
/// everyone else stays subtle (anti-band). Applied to the shared `grain` value.
static inline float MeshGrainScaleForType(int type) {
  switch (type) {
  case MeshType_GrainGradient:
    return 3.0f; // stylistic film grain to match the grainy look
  default:
    return 1.0f;
  }
}

/// Fallback shared-params block (transforms + timing + grain).
static inline MeshCommonUniforms MeshCommonDefault(void) {
  MeshCommonUniforms c;
  memset(&c, 0, sizeof(c));
  c.origin = (vector_float2){0.5f, 0.5f};
  c.scale = (vector_float2){1.0f, 1.0f};
  c.rotation = 0.0f;
  c.time = 0.0f;
  c.speed = KK_MESH_GRAD_DEFAULT_SPEED;
  c.seed = 0.0f;
  c.grain = KK_CORE_GRAIN_DEFAULT;
  c.grainSize = KK_CORE_GRAINSIZE_DEFAULT;
  c.grainScale = 1.0f;
  c.resolution = (vector_float2){1920.0f, 1080.0f};
  return c;
}

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
  return g;
}

/// Dithering (paper-design port) defaults.
#define KK_DITHER_DEFAULT_PXSIZE 2.0f
#define KK_DITHER_DEFAULT_SHAPE 1 // simplex
#define KK_DITHER_DEFAULT_TYPE 4  // 8x8 Bayer
#define KK_DITHER_DEFAULT_SPEED 1.0f

/// Fallback Dithering uniforms so an un-edited instance still renders before
/// the lanes resolve. `resolution` is overwritten at render time.
static inline DitheringUniforms DitheringDefault(void) {
  DitheringUniforms d;
  memset(&d, 0, sizeof(d));
  d.colorsCount = KK_MESH_COLOR_COUNT;
  for (int i = 0; i < KK_MESH_COLOR_COUNT; i++) {
    const float *c = kMeshDefaultColorsSRGB[i];
    d.colors[i] = (vector_float4){c[0], c[1], c[2], c[3]};
  }
  d.pxSize = KK_DITHER_DEFAULT_PXSIZE;
  d.shape = KK_DITHER_DEFAULT_SHAPE;
  d.type = KK_DITHER_DEFAULT_TYPE;
  return d;
}

/// Grain Gradient ("Grainy", paper-design port) defaults.
#define KK_GRAIN_DEFAULT_SOFTNESS                                              \
  0.90f // band-edge smoothness (0 hard, 1 smooth)
#define KK_GRAIN_DEFAULT_INTENSITY 0.40f // distortion between bands
#define KK_GRAIN_DEFAULT_NOISE 0.25f     // grainy overlay amount
#define KK_GRAIN_DEFAULT_SHAPE 1         // wave
#define KK_GRAIN_DEFAULT_SPEED 1.0f

/// Fallback Grain Gradient uniforms so an un-edited instance still renders
/// before the lanes resolve. Colours share the Mesh default palette (the same
/// "Color N" lanes drive both types). `resolution` is overwritten at render
/// time.
static inline GrainGradientUniforms GrainGradientDefault(void) {
  GrainGradientUniforms g;
  memset(&g, 0, sizeof(g));
  int n = KK_MESH_COLOR_COUNT < KK_GRAIN_GRAD_COLORS ? KK_MESH_COLOR_COUNT
                                                     : KK_GRAIN_GRAD_COLORS;
  g.colorsCount = n;
  for (int i = 0; i < n; i++) {
    const float *c = kMeshDefaultColorsSRGB[i];
    g.colors[i] = (vector_float4){c[0], c[1], c[2], c[3]};
  }
  g.colorBack = (vector_float4){0.04f, 0.04f, 0.07f, 1.0f};
  g.softness = KK_GRAIN_DEFAULT_SOFTNESS;
  g.intensity = KK_GRAIN_DEFAULT_INTENSITY;
  g.noise = KK_GRAIN_DEFAULT_NOISE;
  g.shape = KK_GRAIN_DEFAULT_SHAPE;
  return g;
}

/// Warp (paper-design port) defaults. Distortion/Swirl/Softness are the lanes
/// shared with Mesh/Grainy, so their fallbacks match those shared defaults.
#define KK_WARP_DEFAULT_PROPORTION 0.50f
#define KK_WARP_DEFAULT_SHAPESCALE 0.50f
#define KK_WARP_DEFAULT_SWIRLITER 8.0f
#define KK_WARP_DEFAULT_SHAPE 0 // checks

/// Fallback Warp uniforms so an un-edited instance still renders before the
/// lanes resolve. Colours share the Mesh default palette. `resolution` is
/// overwritten at render time.
static inline WarpUniforms WarpDefault(void) {
  WarpUniforms w;
  memset(&w, 0, sizeof(w));
  w.colorsCount = KK_MESH_COLOR_COUNT;
  for (int i = 0; i < KK_MESH_COLOR_COUNT; i++) {
    const float *c = kMeshDefaultColorsSRGB[i];
    w.colors[i] = (vector_float4){c[0], c[1], c[2], c[3]};
  }
  w.proportion = KK_WARP_DEFAULT_PROPORTION;
  w.softness = KK_GRAIN_DEFAULT_SOFTNESS; // shared "Softness" lane
  w.shapeScale = KK_WARP_DEFAULT_SHAPESCALE;
  w.distortion = KK_MESH_GRAD_DEFAULT_DISTORTION; // shared "Distortion" lane
  w.swirl = KK_MESH_GRAD_DEFAULT_SWIRL;           // shared "Swirl" lane
  w.swirlIterations = KK_WARP_DEFAULT_SWIRLITER;
  w.shape = KK_WARP_DEFAULT_SHAPE;
  return w;
}

/// Neuro Noise ("Neuro", paper-design port) defaults.
#define KK_NEURO_DEFAULT_BRIGHTNESS 0.20f
#define KK_NEURO_DEFAULT_CONTRAST 0.30f

/// Fallback Neuro Noise uniforms so an un-edited instance still renders before
/// the lanes resolve. `resolution` is overwritten at render time.
static inline NeuroNoiseUniforms NeuroNoiseDefault(void) {
  NeuroNoiseUniforms n;
  memset(&n, 0, sizeof(n));
  n.colorsCount = KK_MESH_COLOR_COUNT;
  for (int i = 0; i < KK_MESH_COLOR_COUNT; i++) {
    const float *c = kMeshDefaultColorsSRGB[i];
    n.colors[i] = (vector_float4){c[0], c[1], c[2], c[3]};
  }
  n.brightness = KK_NEURO_DEFAULT_BRIGHTNESS;
  n.contrast = KK_NEURO_DEFAULT_CONTRAST;
  return n;
}

/// Simplex Noise ("Simplex", paper-design port) defaults.
#define KK_SIMPLEX_DEFAULT_STEPS 1.0f
#define KK_SIMPLEX_DEFAULT_SOFTNESS 0.0f

/// Fallback Simplex Noise uniforms (the default palette) so an un-edited
/// instance still renders before the colour lanes resolve. `resolution` is
/// overwritten at render time.
static inline SimplexNoiseUniforms SimplexNoiseDefault(void) {
  SimplexNoiseUniforms s;
  memset(&s, 0, sizeof(s));
  s.colorsCount = KK_MESH_COLOR_COUNT;
  for (int i = 0; i < KK_MESH_COLOR_COUNT; i++) {
    const float *c = kMeshDefaultColorsSRGB[i];
    s.colors[i] = (vector_float4){c[0], c[1], c[2], c[3]};
  }
  s.stepsPerColor = KK_SIMPLEX_DEFAULT_STEPS;
  s.softness = KK_SIMPLEX_DEFAULT_SOFTNESS;
  return s;
}

/// Metaballs ("Metaballs", paper-design port) defaults.
#define KK_METABALLS_DEFAULT_COUNT 6.0f
#define KK_METABALLS_DEFAULT_SIZE 1.0f

/// Fallback Metaballs uniforms (the default palette + a dark background) so an
/// un-edited instance still renders before the colour lanes resolve.
/// `resolution` is overwritten at render time.
static inline MetaballsUniforms MetaballsDefault(void) {
  MetaballsUniforms m;
  memset(&m, 0, sizeof(m));
  m.colorsCount = KK_MESH_COLOR_COUNT;
  for (int i = 0; i < KK_MESH_COLOR_COUNT; i++) {
    const float *c = kMeshDefaultColorsSRGB[i];
    m.colors[i] = (vector_float4){c[0], c[1], c[2], c[3]};
  }
  m.colorBack = (vector_float4){0.04f, 0.04f, 0.07f, 1.0f};
  m.ballCount = KK_METABALLS_DEFAULT_COUNT;
  m.ballSize = KK_METABALLS_DEFAULT_SIZE;
  return m;
}

/// God Rays ("God Rays", paper-design port) defaults.
#define KK_GODRAYS_DEFAULT_DENSITY 0.06f
#define KK_GODRAYS_DEFAULT_SPOTTY 0.01f
#define KK_GODRAYS_DEFAULT_MIDSIZE 0.22f
#define KK_GODRAYS_DEFAULT_MIDINTENSITY 0.28f
#define KK_GODRAYS_DEFAULT_INTENSITY 0.20f
#define KK_GODRAYS_DEFAULT_BLOOM 0.015f

/// Fallback God Rays uniforms (the default palette + a dark background + a warm
/// bloom overlay) so an un-edited instance still renders before the colour
/// lanes resolve. `resolution` is overwritten at render time.
static inline GodRaysUniforms GodRaysDefault(void) {
  GodRaysUniforms g;
  memset(&g, 0, sizeof(g));
  int rays = KK_MESH_COLOR_COUNT < 5 ? KK_MESH_COLOR_COUNT : 5;
  g.colorsCount = rays;
  for (int i = 0; i < KK_MESH_COLOR_COUNT; i++) {
    const float *c = kMeshDefaultColorsSRGB[i];
    g.colors[i] = (vector_float4){c[0], c[1], c[2], c[3]};
  }
  g.colorBack = (vector_float4){0.04f, 0.04f, 0.07f, 1.0f};
  g.colorBloom = (vector_float4){1.0f, 0.9f, 0.7f, 1.0f};
  g.density = KK_GODRAYS_DEFAULT_DENSITY;
  g.spotty = KK_GODRAYS_DEFAULT_SPOTTY;
  g.midSize = KK_GODRAYS_DEFAULT_MIDSIZE;
  g.midIntensity = KK_GODRAYS_DEFAULT_MIDINTENSITY;
  g.intensity = KK_GODRAYS_DEFAULT_INTENSITY;
  g.bloom = KK_GODRAYS_DEFAULT_BLOOM;
  return g;
}

/// Fluid ("Fluid", radiant-shaders fluid-amber port) defaults.
#define KK_FLUID_DEFAULT_DETAIL 0.48f  // fbm amplitude persistence
#define KK_FLUID_DEFAULT_MARBLE 1.0f   // domain-warp strength (1 = source)
#define KK_FLUID_DEFAULT_VIBRANCE 1.0f // colour-layer separation (1 = source)

/// Fallback Fluid uniforms (the default palette) so an un-edited instance still
/// renders before the colour lanes resolve. `resolution` is overwritten at
/// render time.
static inline FluidUniforms FluidDefault(void) {
  FluidUniforms f;
  memset(&f, 0, sizeof(f));
  f.colorsCount = KK_MESH_COLOR_COUNT;
  for (int i = 0; i < KK_MESH_COLOR_COUNT; i++) {
    const float *c = kMeshDefaultColorsSRGB[i];
    f.colors[i] = (vector_float4){c[0], c[1], c[2], c[3]};
  }
  f.detail = KK_FLUID_DEFAULT_DETAIL;
  f.marble = KK_FLUID_DEFAULT_MARBLE;
  f.vibrance = KK_FLUID_DEFAULT_VIBRANCE;
  return f;
}

/// Neon ("Neon", radiant-shaders neon-drip port, wisps only) defaults.
#define KK_NEON_DEFAULT_RADIANCE 1.0f // HDR neon gain
#define KK_NEON_DEFAULT_WISPS 1.0f    // tendril-wisp strength / coverage
#define KK_NEON_DEFAULT_STRANDS 1.0f  // tendril fineness (frequency)

/// Fallback Neon uniforms (the default palette + dark backdrop) so an un-edited
/// instance still renders before the colour lanes resolve. `resolution` is
/// overwritten at render time.
static inline NeonUniforms NeonDefault(void) {
  NeonUniforms n;
  memset(&n, 0, sizeof(n));
  n.colorsCount = KK_MESH_COLOR_COUNT;
  for (int i = 0; i < KK_MESH_COLOR_COUNT; i++) {
    const float *c = kMeshDefaultColorsSRGB[i];
    n.colors[i] = (vector_float4){c[0], c[1], c[2], c[3]};
  }
  n.colorBack = (vector_float4){0.02f, 0.015f, 0.02f, 1.0f};
  n.radiance = KK_NEON_DEFAULT_RADIANCE;
  n.wisps = KK_NEON_DEFAULT_WISPS;
  n.strands = KK_NEON_DEFAULT_STRANDS;
  return n;
}

/// Silk ("Silk", radiant-shaders silk-cascade port) defaults.
#define KK_SILK_DEFAULT_SHEEN 1.0f // silk specular intensity
#define KK_SILK_DEFAULT_FOLDS 0.5f // fold frequency scale
#define KK_SILK_DEFAULT_DRAPE 1.0f // domain-warp strength

/// Fallback Silk uniforms (the default palette as the 3 layer hues + a dark
/// backdrop) so an un-edited instance still renders before the colour lanes
/// resolve. `resolution` is overwritten at render time.
static inline SilkUniforms SilkDefault(void) {
  SilkUniforms s;
  memset(&s, 0, sizeof(s));
  s.colorsCount = KK_MESH_COLOR_COUNT;
  for (int i = 0; i < KK_MESH_COLOR_COUNT; i++) {
    const float *c = kMeshDefaultColorsSRGB[i];
    s.colors[i] = (vector_float4){c[0], c[1], c[2], c[3]};
  }
  s.colorBack = (vector_float4){0.03f, 0.015f, 0.04f, 1.0f};
  s.sheen = KK_SILK_DEFAULT_SHEEN;
  s.folds = KK_SILK_DEFAULT_FOLDS;
  s.drape = KK_SILK_DEFAULT_DRAPE;
  return s;
}

/// Strata ("Strata", radiant-shaders painted-strata port) defaults.
#define KK_STRATA_DEFAULT_LAYERS 16.0f   // strata layer count
#define KK_STRATA_DEFAULT_TECTONICS 1.0f // deformation strength
#define KK_STRATA_DEFAULT_TEXTURE 1.0f   // paper grain intensity

/// Fallback Strata uniforms (the default palette as strata hues) so an
/// un-edited instance still renders before the colour lanes resolve.
/// `resolution` is overwritten at render time.
static inline StrataUniforms StrataDefault(void) {
  StrataUniforms s;
  memset(&s, 0, sizeof(s));
  s.colorsCount = KK_MESH_COLOR_COUNT;
  for (int i = 0; i < KK_MESH_COLOR_COUNT; i++) {
    const float *c = kMeshDefaultColorsSRGB[i];
    s.colors[i] = (vector_float4){c[0], c[1], c[2], c[3]};
  }
  s.layers = KK_STRATA_DEFAULT_LAYERS;
  s.tectonics = KK_STRATA_DEFAULT_TECTONICS;
  s.texture = KK_STRATA_DEFAULT_TEXTURE;
  return s;
}

/// Generic per-swatch lane label ("Color 1", "Color 2", ...). One [r,g,b,a]
/// colour lane per swatch. One-based to read naturally.
static inline NSString *MeshColorLabel(int i) {
  return [NSString stringWithFormat:@"Color %d", i + 1];
}

/// Label of the swatch-count lane: component-0 holds the active swatch count
/// (2..KK_MESH_COLOR_MAX). Drives both how many "Color N" rows show and how
/// many swatches the render reads (clamped per-Type by MeshMaxColorsForType).
#define KK_MESH_COLOR_COUNT_LABEL @"Color Count"

/// The effective swatch count for `type`: the stored count clamped to the
/// Type's palette cap. `storedCount` <= 0 falls back to the default count.
static inline int MeshEffectiveColorCount(int storedCount, int type) {
  int n = storedCount > 0 ? storedCount : KK_MESH_COLOR_COUNT;
  int cap = MeshMaxColorsForType(type);
  if (n > cap)
    n = cap;
  if (n > KK_MESH_COLOR_MAX)
    n = KK_MESH_COLOR_MAX;
  return n < 0 ? 0 : n;
}

/// Number of Types (choice-pill entries). Keep in sync with the MeshType enum.
#define MESH_TYPE_COUNT 12

/// Type indices (as NSNumbers) whose palette cap is >= `minCap` - i.e. the
/// Types for which swatch #minCap is meaningful. Used to gate a swatch row's
/// primary (Type) visibility so e.g. Color 8 never shows for God Rays (cap 5).
static inline NSArray<NSNumber *> *MeshTypesWithColorCap(int minCap) {
  NSMutableArray<NSNumber *> *out = [NSMutableArray array];
  for (int t = 0; t < MESH_TYPE_COUNT; t++)
    if (MeshMaxColorsForType(t) >= minCap)
      [out addObject:@(t)];
  return out;
}

/// Count values (as NSNumbers) satisfying "count >= n": n, n+1, .. max. Used as
/// a swatch row's second AND condition against the "Color Count" lane.
static inline NSArray<NSNumber *> *MeshColorCountAtLeast(int n) {
  NSMutableArray<NSNumber *> *out = [NSMutableArray array];
  for (int c = n; c <= KK_MESH_COLOR_MAX; c++)
    [out addObject:@(c)];
  return out;
}
/// 0-based index if `label` is "<prefix> N", else -1.
static inline int MeshIndexForLabel(NSString *label, NSString *prefix) {
  if (![label hasPrefix:prefix])
    return -1;
  return [label substringFromIndex:prefix.length].intValue - 1;
}

#endif // __METAL_VERSION__
