/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// Per-Type uniform builders shared by the FCP render (Plugin+Render.m) and the
// mini-viewer (MeshMiniViewerRenderer.m). Both paths used to fill the same
// struct twice from the same lanes; now each Type has ONE builder here. A
// `MeshLaneReader` block abstracts where the lane values come from: the render
// wraps MeshLaneValuesAtFraction(timeline, label, frac); the mini wraps
// [self valuesForLabel:label]. The shared transforms + grain live in
// MeshCommonUniforms (built separately), so these builders only fill each
// Type's own fields.

#import <Foundation/Foundation.h>

#import "MeshColorSpace.h"
#import "ShaderTypes.h"

/// Returns the interpolated component values for a lane label (nil / empty if
/// the lane is absent).
typedef NSArray<NSNumber *> *_Nullable (^MeshLaneReader)(
    NSString *_Nonnull label);

NS_ASSUME_NONNULL_BEGIN

// ── Small read helpers ──

/// The stored swatch count ("Color Count" lane, component-0), or the default
/// count if the lane is absent.
static inline int MeshReadStoredColorCount(MeshLaneReader read) {
  NSArray<NSNumber *> *v = read(KK_MESH_COLOR_COUNT_LABEL);
  return v.count ? (int)lround(v[0].doubleValue) : KK_MESH_COLOR_COUNT;
}

/// Fill the dynamic "Color N" palette for `type`: the stored swatch count
/// clamped to the Type's cap (MeshMaxColorsForType), each swatch read from its
/// lane (falling back to the default palette). Returns the active count (>= 1).
static inline int MeshReadPalette(MeshLaneReader read, vector_float4 *colors,
                                  int type) {
  int n = MeshEffectiveColorCount(MeshReadStoredColorCount(read), type);
  int count = 0;
  for (int i = 0; i < n && i < KK_MESH_COLOR_MAX; i++) {
    NSArray<NSNumber *> *v = read(MeshColorLabel(i));
    if (v.count >= 4)
      colors[count++] = (vector_float4){v[0].floatValue, v[1].floatValue,
                                        v[2].floatValue, v[3].floatValue};
    else {
      const float *c = kMeshDefaultColorsSRGB[i];
      colors[count++] = (vector_float4){c[0], c[1], c[2], c[3]};
    }
  }
  return count > 0 ? count : 1;
}

/// Write `*out` from a colour lane if present; leave it untouched otherwise.
static inline void MeshReadColor(MeshLaneReader read, NSString *label,
                                 vector_float4 *out) {
  NSArray<NSNumber *> *v = read(label);
  if (v.count >= 4)
    *out = (vector_float4){v[0].floatValue, v[1].floatValue, v[2].floatValue,
                           v[3].floatValue};
}

/// Raw scalar lane value, or `fallback` if absent.
static inline float MeshReadScalar(MeshLaneReader read, NSString *label,
                                   float fallback) {
  NSArray<NSNumber *> *v = read(label);
  return v.count ? v[0].floatValue : fallback;
}

/// Percent lane value scaled to 0..1 (100% -> 1.0), or `fallback01` if absent.
static inline float MeshReadPercent(MeshLaneReader read, NSString *label,
                                    float fallback01) {
  NSArray<NSNumber *> *v = read(label);
  return v.count ? v[0].floatValue / 100.0f : fallback01;
}

/// A 0-based choice-pill index + `offset` (shaders often want 1-based), or
/// `fallback` if the lane is absent.
static inline int MeshReadPill(MeshLaneReader read, NSString *label,
                               int fallback, int offset) {
  NSArray<NSNumber *> *v = read(label);
  return v.count ? (int)lround(v[0].doubleValue) + offset : fallback;
}

// ── Per-Type builders ──

static inline MeshGradientUniforms MeshBuildMesh(MeshLaneReader read) {
  MeshGradientUniforms u;
  memset(&u, 0, sizeof(u));
  u.colorsCount = MeshReadPalette(read, u.colors, MeshType_Mesh);
  u.distortion =
      MeshReadPercent(read, @"Distortion", KK_MESH_GRAD_DEFAULT_DISTORTION);
  u.swirl = MeshReadPercent(read, @"Swirl", KK_MESH_GRAD_DEFAULT_SWIRL);
  return u;
}

static inline DitheringUniforms MeshBuildDithering(MeshLaneReader read) {
  DitheringUniforms d = DitheringDefault();
  d.colorsCount = MeshReadPalette(read, d.colors, MeshType_Dithering);
  d.shape = MeshReadPill(read, @"Shape", KK_DITHER_DEFAULT_SHAPE, 1);
  d.type = MeshReadPill(read, @"Dither", KK_DITHER_DEFAULT_TYPE, 1);
  d.pxSize = MeshReadScalar(read, @"Pixel Size", KK_DITHER_DEFAULT_PXSIZE);
  return d;
}

static inline GrainGradientUniforms MeshBuildGrainy(MeshLaneReader read) {
  GrainGradientUniforms g = GrainGradientDefault();
  g.colorsCount = MeshReadPalette(read, g.colors, MeshType_GrainGradient);
  g.colorBack = g.colors[0]; // Color 1 is the base/background

  g.softness = MeshReadPercent(read, @"Softness", KK_GRAIN_DEFAULT_SOFTNESS);
  g.intensity = MeshReadPercent(read, @"Intensity", KK_GRAIN_DEFAULT_INTENSITY);
  g.noise = MeshReadPercent(read, @"Noise", KK_GRAIN_DEFAULT_NOISE);
  g.shape = MeshReadPill(read, @"Pattern", KK_GRAIN_DEFAULT_SHAPE, 1);
  return g;
}

static inline WarpUniforms MeshBuildWarp(MeshLaneReader read) {
  WarpUniforms w = WarpDefault();
  w.colorsCount = MeshReadPalette(read, w.colors, MeshType_Warp);
  w.proportion =
      MeshReadPercent(read, @"Proportion", KK_WARP_DEFAULT_PROPORTION);
  w.softness = MeshReadPercent(read, @"Softness", KK_GRAIN_DEFAULT_SOFTNESS);
  w.shapeScale =
      MeshReadPercent(read, @"Shape Scale", KK_WARP_DEFAULT_SHAPESCALE);
  w.distortion =
      MeshReadPercent(read, @"Distortion", KK_MESH_GRAD_DEFAULT_DISTORTION);
  w.swirl = MeshReadPercent(read, @"Swirl", KK_MESH_GRAD_DEFAULT_SWIRL);
  w.swirlIterations =
      MeshReadScalar(read, @"Swirl Iterations", KK_WARP_DEFAULT_SWIRLITER);
  w.shape = MeshReadPill(read, @"Base", KK_WARP_DEFAULT_SHAPE, 0);
  return w;
}

static inline NeuroNoiseUniforms MeshBuildNeuro(MeshLaneReader read) {
  NeuroNoiseUniforms nn = NeuroNoiseDefault();
  nn.colorsCount = MeshReadPalette(read, nn.colors, MeshType_Neuro);
  nn.brightness =
      MeshReadPercent(read, @"Brightness", KK_NEURO_DEFAULT_BRIGHTNESS);
  nn.contrast = MeshReadPercent(read, @"Contrast", KK_NEURO_DEFAULT_CONTRAST);
  return nn;
}

static inline SimplexNoiseUniforms MeshBuildSimplex(MeshLaneReader read) {
  SimplexNoiseUniforms sn = SimplexNoiseDefault();
  sn.colorsCount = MeshReadPalette(read, sn.colors, MeshType_Simplex);
  sn.stepsPerColor = MeshReadScalar(read, @"Steps", KK_SIMPLEX_DEFAULT_STEPS);
  sn.softness = MeshReadPercent(read, @"Softness", KK_SIMPLEX_DEFAULT_SOFTNESS);
  return sn;
}

static inline MetaballsUniforms MeshBuildMetaballs(MeshLaneReader read) {
  MetaballsUniforms mb = MetaballsDefault();
  mb.colorsCount = MeshReadPalette(read, mb.colors, MeshType_Metaballs);
  mb.colorBack = mb.colors[0]; // Color 1 is the base/background

  mb.ballCount = MeshReadScalar(read, @"Count", KK_METABALLS_DEFAULT_COUNT);
  mb.ballSize = MeshReadPercent(read, @"Size", KK_METABALLS_DEFAULT_SIZE);
  return mb;
}

static inline GodRaysUniforms MeshBuildGodRays(MeshLaneReader read) {
  GodRaysUniforms gr = GodRaysDefault();
  gr.colorsCount = MeshReadPalette(read, gr.colors, MeshType_GodRays);
  gr.colorBack = gr.colors[0]; // Color 1 is the base/background
  MeshReadColor(read, @"Bloom Color", &gr.colorBloom);
  gr.density = MeshReadPercent(read, @"Density", KK_GODRAYS_DEFAULT_DENSITY);
  gr.spotty = MeshReadPercent(read, @"Spots", KK_GODRAYS_DEFAULT_SPOTTY);
  gr.midSize = MeshReadPercent(read, @"Glow Size", KK_GODRAYS_DEFAULT_MIDSIZE);
  gr.midIntensity =
      MeshReadPercent(read, @"Glow", KK_GODRAYS_DEFAULT_MIDINTENSITY);
  gr.intensity = MeshReadPercent(read, @"Rays", KK_GODRAYS_DEFAULT_INTENSITY);
  gr.bloom = MeshReadPercent(read, @"Bloom", KK_GODRAYS_DEFAULT_BLOOM);
  return gr;
}

static inline FluidUniforms MeshBuildFluid(MeshLaneReader read) {
  FluidUniforms fl = FluidDefault();
  fl.colorsCount = MeshReadPalette(read, fl.colors, MeshType_Fluid);
  fl.detail = MeshReadPercent(read, @"Detail", KK_FLUID_DEFAULT_DETAIL);
  fl.marble = MeshReadPercent(read, @"Marble", KK_FLUID_DEFAULT_MARBLE);
  fl.vibrance = MeshReadPercent(read, @"Vibrance", KK_FLUID_DEFAULT_VIBRANCE);
  return fl;
}

static inline NeonUniforms MeshBuildNeon(MeshLaneReader read) {
  NeonUniforms ne = NeonDefault();
  ne.colorsCount = MeshReadPalette(read, ne.colors, MeshType_Neon);
  ne.colorBack = ne.colors[0]; // Color 1 is the base/background

  ne.radiance = MeshReadPercent(read, @"Radiance", KK_NEON_DEFAULT_RADIANCE);
  ne.wisps = MeshReadPercent(read, @"Wisps", KK_NEON_DEFAULT_WISPS);
  ne.strands = MeshReadPercent(read, @"Strands", KK_NEON_DEFAULT_STRANDS);
  return ne;
}

static inline SilkUniforms MeshBuildSilk(MeshLaneReader read) {
  SilkUniforms sk = SilkDefault();
  sk.colorsCount = MeshReadPalette(read, sk.colors, MeshType_Silk);
  sk.colorBack = sk.colors[0]; // Color 1 is the base/background

  sk.sheen = MeshReadPercent(read, @"Sheen", KK_SILK_DEFAULT_SHEEN);
  sk.folds = MeshReadPercent(read, @"Folds", KK_SILK_DEFAULT_FOLDS);
  sk.drape = MeshReadPercent(read, @"Drape", KK_SILK_DEFAULT_DRAPE);
  return sk;
}

static inline StrataUniforms MeshBuildStrata(MeshLaneReader read) {
  StrataUniforms st = StrataDefault();
  st.colorsCount = MeshReadPalette(read, st.colors, MeshType_Strata);
  st.layers = MeshReadScalar(read, @"Layers", KK_STRATA_DEFAULT_LAYERS);
  st.tectonics =
      MeshReadPercent(read, @"Tectonics", KK_STRATA_DEFAULT_TECTONICS);
  st.texture = MeshReadPercent(read, @"Texture", KK_STRATA_DEFAULT_TEXTURE);
  return st;
}

// ── Type dispatch registry ──
// One row per Type: the metal fragment function, the pipeline-cache-key suffix
// (kept distinct so per-Type pipelines don't collide), and where that Type's
// uniform lives inside MeshPluginState. Both the FCP render and the mini pick
// the fragment + uniform bytes from here instead of a hand-written if/else
// chain, so adding a Type is one row.
typedef struct MeshTypeInfo {
  int type;
  const char *fragment;     // metal fragment function name
  const char *pluginSuffix; // pipeline cache-key suffix ("" = base plugin ID)
  size_t uniformOffset; // offset of this Type's uniform within MeshPluginState
  size_t uniformSize;   // sizeof that uniform
} MeshTypeInfo;

#define MESH_TYPE_INFO(T, FRAG, SUFFIX, FIELD)                                 \
  {T, FRAG, SUFFIX, offsetof(MeshPluginState, FIELD),                          \
   sizeof(((MeshPluginState *)0)->FIELD)}

static const MeshTypeInfo kMeshTypeInfo[] = {
    MESH_TYPE_INFO(MeshType_Mesh, "fragmentShader", "", mesh),
    MESH_TYPE_INFO(MeshType_Dithering, "ditheringFragment", ".dithering",
                   dithering),
    MESH_TYPE_INFO(MeshType_GrainGradient, "grainGradientFragment", ".grain",
                   grain),
    MESH_TYPE_INFO(MeshType_Warp, "warpFragment", ".warp", warp),
    MESH_TYPE_INFO(MeshType_Neuro, "neuroNoiseFragment", ".neuro", neuro),
    MESH_TYPE_INFO(MeshType_Simplex, "simplexNoiseFragment", ".simplex",
                   simplex),
    MESH_TYPE_INFO(MeshType_Metaballs, "metaballsFragment", ".metaballs",
                   metaballs),
    MESH_TYPE_INFO(MeshType_GodRays, "godRaysFragment", ".godrays", godrays),
    MESH_TYPE_INFO(MeshType_Fluid, "fluidFragment", ".fluid", fluid),
    MESH_TYPE_INFO(MeshType_Neon, "neonFragment", ".neon", neon),
    MESH_TYPE_INFO(MeshType_Silk, "silkFragment", ".silk", silk),
    MESH_TYPE_INFO(MeshType_Strata, "strataFragment", ".strata", strata),
};

/// The registry row for `type` (defaults to Mesh if unknown).
static inline const MeshTypeInfo *MeshTypeInfoForType(int type) {
  int n = (int)(sizeof(kMeshTypeInfo) / sizeof(kMeshTypeInfo[0]));
  for (int i = 0; i < n; i++)
    if (kMeshTypeInfo[i].type == type)
      return &kMeshTypeInfo[i];
  return &kMeshTypeInfo[0];
}

/// Fill every Type's uniform block in `state` from `read`. The active Type's
/// block is the one actually rendered, but all are cheap and keep the fallback
/// path simple.
static inline void MeshBuildAllTypes(MeshLaneReader read,
                                     MeshPluginState *state) {
  state->mesh = MeshBuildMesh(read);
  state->dithering = MeshBuildDithering(read);
  state->grain = MeshBuildGrainy(read);
  state->warp = MeshBuildWarp(read);
  state->neuro = MeshBuildNeuro(read);
  state->simplex = MeshBuildSimplex(read);
  state->metaballs = MeshBuildMetaballs(read);
  state->godrays = MeshBuildGodRays(read);
  state->fluid = MeshBuildFluid(read);
  state->neon = MeshBuildNeon(read);
  state->silk = MeshBuildSilk(read);
  state->strata = MeshBuildStrata(read);
}

NS_ASSUME_NONNULL_END
