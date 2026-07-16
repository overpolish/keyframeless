/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// Per-Type uniform builders shared by the FCP render (Plugin+Render.m) and the
// mini-viewer (ShaderMiniViewerRenderer.m). Both paths used to fill the same
// struct twice from the same lanes; now each Type has ONE builder here. A
// `ShaderLaneReader` block abstracts where the lane values come from: the
// render wraps ShaderLaneValuesAtFraction(timeline, label, frac); the mini
// wraps [self valuesForLabel:label]. The shared transforms + grain live in
// ShaderCommonUniforms (built separately), so these builders only fill each
// Type's own fields.

#import <Foundation/Foundation.h>

#import "ShaderDirectives.h"
#import "ShaderTypes.h"

/// Returns the interpolated component values for a lane label (nil / empty if
/// the lane is absent).
typedef NSArray<NSNumber *> *_Nullable (^ShaderLaneReader)(
    NSString *_Nonnull label);

NS_ASSUME_NONNULL_BEGIN

// ── Small read helpers ──

/// The stored swatch count ("Color Count" lane, component-0), or the default
/// count if the lane is absent.
static inline int ShaderReadStoredColorCount(ShaderLaneReader read) {
  NSArray<NSNumber *> *v = read(KK_SHADER_COLOR_COUNT_LABEL);
  return v.count ? (int)lround(v[0].doubleValue) : KK_SHADER_COLOR_COUNT;
}

/// Fill the dynamic "Color N" palette for `type`: the stored swatch count
/// clamped to the Type's cap (ShaderMaxColorsForType), each swatch read from
/// its lane (falling back to the default palette). Returns the active count (>=
/// 1).
static inline int ShaderReadPalette(ShaderLaneReader read,
                                    vector_float4 *colors, int type) {
  int n = ShaderEffectiveColorCount(ShaderReadStoredColorCount(read), type);
  int count = 0;
  for (int i = 0; i < n && i < KK_SHADER_COLOR_MAX; i++) {
    NSArray<NSNumber *> *v = read(ShaderColorLabel(i));
    if (v.count >= 4)
      colors[count++] = (vector_float4){v[0].floatValue, v[1].floatValue,
                                        v[2].floatValue, v[3].floatValue};
    else {
      const float *c = kShaderDefaultColorsSRGB[i];
      colors[count++] = (vector_float4){c[0], c[1], c[2], c[3]};
    }
  }
  return count > 0 ? count : 1;
}

/// Write `*out` from a colour lane if present; leave it untouched otherwise.
static inline void ShaderReadColor(ShaderLaneReader read, NSString *label,
                                   vector_float4 *out) {
  NSArray<NSNumber *> *v = read(label);
  if (v.count >= 4)
    *out = (vector_float4){v[0].floatValue, v[1].floatValue, v[2].floatValue,
                           v[3].floatValue};
}

/// Raw scalar lane value, or `fallback` if absent.
static inline float ShaderReadScalar(ShaderLaneReader read, NSString *label,
                                     float fallback) {
  NSArray<NSNumber *> *v = read(label);
  return v.count ? v[0].floatValue : fallback;
}

/// Percent lane value scaled to 0..1 (100% -> 1.0), or `fallback01` if absent.
static inline float ShaderReadPercent(ShaderLaneReader read, NSString *label,
                                      float fallback01) {
  NSArray<NSNumber *> *v = read(label);
  return v.count ? v[0].floatValue / 100.0f : fallback01;
}

/// A 0-based choice-pill index + `offset` (shaders often want 1-based), or
/// `fallback` if the lane is absent.
static inline int ShaderReadPill(ShaderLaneReader read, NSString *label,
                                 int fallback, int offset) {
  NSArray<NSNumber *> *v = read(label);
  return v.count ? (int)lround(v[0].doubleValue) + offset : fallback;
}

// ── Per-Type builders ──

static inline ShaderGradientUniforms ShaderBuildMesh(ShaderLaneReader read) {
  ShaderGradientUniforms u;
  memset(&u, 0, sizeof(u));
  u.colorsCount = ShaderReadPalette(read, u.colors, ShaderType_Mesh);
  u.distortion =
      ShaderReadPercent(read, @"Distortion", KK_SHADER_GRAD_DEFAULT_DISTORTION);
  u.swirl = ShaderReadPercent(read, @"Swirl", KK_SHADER_GRAD_DEFAULT_SWIRL);
  return u;
}

static inline DitheringUniforms ShaderBuildDithering(ShaderLaneReader read) {
  DitheringUniforms d = DitheringDefault();
  d.colorsCount = ShaderReadPalette(read, d.colors, ShaderType_Dithering);
  d.shape = ShaderReadPill(read, @"Shape", KK_DITHER_DEFAULT_SHAPE, 1);
  d.type = ShaderReadPill(read, @"Dither", KK_DITHER_DEFAULT_TYPE, 1);
  d.pxSize = ShaderReadScalar(read, @"Pixel Size", KK_DITHER_DEFAULT_PXSIZE);
  return d;
}

static inline GrainGradientUniforms ShaderBuildGrainy(ShaderLaneReader read) {
  GrainGradientUniforms g = GrainGradientDefault();
  g.colorsCount = ShaderReadPalette(read, g.colors, ShaderType_GrainGradient);
  g.colorBack = g.colors[0]; // Color 1 is the base/background

  g.softness = ShaderReadPercent(read, @"Softness", KK_GRAIN_DEFAULT_SOFTNESS);
  g.intensity =
      ShaderReadPercent(read, @"Intensity", KK_GRAIN_DEFAULT_INTENSITY);
  g.noise = ShaderReadPercent(read, @"Noise", KK_GRAIN_DEFAULT_NOISE);
  g.shape = ShaderReadPill(read, @"Pattern", KK_GRAIN_DEFAULT_SHAPE, 1);
  return g;
}

static inline WarpUniforms ShaderBuildWarp(ShaderLaneReader read) {
  WarpUniforms w = WarpDefault();
  w.colorsCount = ShaderReadPalette(read, w.colors, ShaderType_Warp);
  w.proportion =
      ShaderReadPercent(read, @"Proportion", KK_WARP_DEFAULT_PROPORTION);
  w.softness = ShaderReadPercent(read, @"Softness", KK_GRAIN_DEFAULT_SOFTNESS);
  w.shapeScale =
      ShaderReadPercent(read, @"Shape Scale", KK_WARP_DEFAULT_SHAPESCALE);
  w.distortion =
      ShaderReadPercent(read, @"Distortion", KK_SHADER_GRAD_DEFAULT_DISTORTION);
  w.swirl = ShaderReadPercent(read, @"Swirl", KK_SHADER_GRAD_DEFAULT_SWIRL);
  w.swirlIterations =
      ShaderReadScalar(read, @"Swirl Iterations", KK_WARP_DEFAULT_SWIRLITER);
  w.shape = ShaderReadPill(read, @"Base", KK_WARP_DEFAULT_SHAPE, 0);
  return w;
}

static inline NeuroNoiseUniforms ShaderBuildNeuro(ShaderLaneReader read) {
  NeuroNoiseUniforms nn = NeuroNoiseDefault();
  nn.colorsCount = ShaderReadPalette(read, nn.colors, ShaderType_Neuro);
  nn.brightness =
      ShaderReadPercent(read, @"Brightness", KK_NEURO_DEFAULT_BRIGHTNESS);
  nn.contrast = ShaderReadPercent(read, @"Contrast", KK_NEURO_DEFAULT_CONTRAST);
  return nn;
}

static inline SimplexNoiseUniforms ShaderBuildSimplex(ShaderLaneReader read) {
  SimplexNoiseUniforms sn = SimplexNoiseDefault();
  sn.colorsCount = ShaderReadPalette(read, sn.colors, ShaderType_Simplex);
  sn.stepsPerColor = ShaderReadScalar(read, @"Steps", KK_SIMPLEX_DEFAULT_STEPS);
  sn.softness =
      ShaderReadPercent(read, @"Softness", KK_SIMPLEX_DEFAULT_SOFTNESS);
  return sn;
}

static inline MetaballsUniforms ShaderBuildMetaballs(ShaderLaneReader read) {
  MetaballsUniforms mb = MetaballsDefault();
  mb.colorsCount = ShaderReadPalette(read, mb.colors, ShaderType_Metaballs);
  mb.colorBack = mb.colors[0]; // Color 1 is the base/background

  mb.ballCount = ShaderReadScalar(read, @"Count", KK_METABALLS_DEFAULT_COUNT);
  mb.ballSize = ShaderReadPercent(read, @"Size", KK_METABALLS_DEFAULT_SIZE);
  return mb;
}

static inline GodRaysUniforms ShaderBuildGodRays(ShaderLaneReader read) {
  GodRaysUniforms gr = GodRaysDefault();
  gr.colorsCount = ShaderReadPalette(read, gr.colors, ShaderType_GodRays);
  gr.colorBack = gr.colors[0]; // Color 1 is the base/background
  ShaderReadColor(read, @"Bloom Color", &gr.colorBloom);
  gr.density = ShaderReadPercent(read, @"Density", KK_GODRAYS_DEFAULT_DENSITY);
  gr.spotty = ShaderReadPercent(read, @"Spots", KK_GODRAYS_DEFAULT_SPOTTY);
  gr.midSize =
      ShaderReadPercent(read, @"Glow Size", KK_GODRAYS_DEFAULT_MIDSIZE);
  gr.midIntensity =
      ShaderReadPercent(read, @"Glow", KK_GODRAYS_DEFAULT_MIDINTENSITY);
  gr.intensity = ShaderReadPercent(read, @"Rays", KK_GODRAYS_DEFAULT_INTENSITY);
  gr.bloom = ShaderReadPercent(read, @"Bloom", KK_GODRAYS_DEFAULT_BLOOM);
  return gr;
}

static inline FluidUniforms ShaderBuildFluid(ShaderLaneReader read) {
  FluidUniforms fl = FluidDefault();
  fl.colorsCount = ShaderReadPalette(read, fl.colors, ShaderType_Fluid);
  fl.detail = ShaderReadPercent(read, @"Detail", KK_FLUID_DEFAULT_DETAIL);
  fl.marble = ShaderReadPercent(read, @"Marble", KK_FLUID_DEFAULT_MARBLE);
  fl.vibrance = ShaderReadPercent(read, @"Vibrance", KK_FLUID_DEFAULT_VIBRANCE);
  return fl;
}

static inline NeonUniforms ShaderBuildNeon(ShaderLaneReader read) {
  NeonUniforms ne = NeonDefault();
  ne.colorsCount = ShaderReadPalette(read, ne.colors, ShaderType_Neon);
  ne.colorBack = ne.colors[0]; // Color 1 is the base/background

  ne.radiance = ShaderReadPercent(read, @"Radiance", KK_NEON_DEFAULT_RADIANCE);
  ne.wisps = ShaderReadPercent(read, @"Wisps", KK_NEON_DEFAULT_WISPS);
  ne.strands = ShaderReadPercent(read, @"Strands", KK_NEON_DEFAULT_STRANDS);
  return ne;
}

static inline SilkUniforms ShaderBuildSilk(ShaderLaneReader read) {
  SilkUniforms sk = SilkDefault();
  sk.colorsCount = ShaderReadPalette(read, sk.colors, ShaderType_Silk);
  sk.colorBack = sk.colors[0]; // Color 1 is the base/background

  sk.sheen = ShaderReadPercent(read, @"Sheen", KK_SILK_DEFAULT_SHEEN);
  sk.folds = ShaderReadPercent(read, @"Folds", KK_SILK_DEFAULT_FOLDS);
  sk.drape = ShaderReadPercent(read, @"Drape", KK_SILK_DEFAULT_DRAPE);
  return sk;
}

static inline StrataUniforms ShaderBuildStrata(ShaderLaneReader read) {
  StrataUniforms st = StrataDefault();
  st.colorsCount = ShaderReadPalette(read, st.colors, ShaderType_Strata);
  st.layers = ShaderReadScalar(read, @"Layers", KK_STRATA_DEFAULT_LAYERS);
  st.tectonics =
      ShaderReadPercent(read, @"Tectonics", KK_STRATA_DEFAULT_TECTONICS);
  st.texture = ShaderReadPercent(read, @"Texture", KK_STRATA_DEFAULT_TEXTURE);
  return st;
}

// ── Type dispatch registry ──
// One row per Type: the metal fragment function, the pipeline-cache-key suffix
// (kept distinct so per-Type pipelines don't collide), and where that Type's
// uniform lives inside ShaderPluginState. Both the FCP render and the mini pick
// the fragment + uniform bytes from here instead of a hand-written if/else
// chain, so adding a Type is one row.
typedef struct ShaderTypeInfo {
  int type;
  const char *fragment;     // metal fragment function name
  const char *pluginSuffix; // pipeline cache-key suffix ("" = base plugin ID)
  size_t
      uniformOffset;  // offset of this Type's uniform within ShaderPluginState
  size_t uniformSize; // sizeof that uniform
} ShaderTypeInfo;

#define SHADER_TYPE_INFO(T, FRAG, SUFFIX, FIELD)                               \
  {T, FRAG, SUFFIX, offsetof(ShaderPluginState, FIELD),                        \
   sizeof(((ShaderPluginState *)0)->FIELD)}

static const ShaderTypeInfo kShaderTypeInfo[] = {
    SHADER_TYPE_INFO(ShaderType_Mesh, "fragmentShader", "", mesh),
    SHADER_TYPE_INFO(ShaderType_Dithering, "ditheringFragment", ".dithering",
                     dithering),
    SHADER_TYPE_INFO(ShaderType_GrainGradient, "grainGradientFragment",
                     ".grain", grain),
    SHADER_TYPE_INFO(ShaderType_Warp, "warpFragment", ".warp", warp),
    SHADER_TYPE_INFO(ShaderType_Neuro, "neuroNoiseFragment", ".neuro", neuro),
    SHADER_TYPE_INFO(ShaderType_Simplex, "simplexNoiseFragment", ".simplex",
                     simplex),
    SHADER_TYPE_INFO(ShaderType_Metaballs, "metaballsFragment", ".metaballs",
                     metaballs),
    SHADER_TYPE_INFO(ShaderType_GodRays, "godRaysFragment", ".godrays",
                     godrays),
    SHADER_TYPE_INFO(ShaderType_Fluid, "fluidFragment", ".fluid", fluid),
    SHADER_TYPE_INFO(ShaderType_Neon, "neonFragment", ".neon", neon),
    SHADER_TYPE_INFO(ShaderType_Silk, "silkFragment", ".silk", silk),
    SHADER_TYPE_INFO(ShaderType_Strata, "strataFragment", ".strata", strata),
};

/// The registry row for `type` (defaults to Shader if unknown).
static inline const ShaderTypeInfo *ShaderTypeInfoForType(int type) {
  int n = (int)(sizeof(kShaderTypeInfo) / sizeof(kShaderTypeInfo[0]));
  for (int i = 0; i < n; i++)
    if (kShaderTypeInfo[i].type == type)
      return &kShaderTypeInfo[i];
  return &kShaderTypeInfo[0];
}

/// Fill every Type's uniform block in `state` from `read`. The active Type's
/// block is the one actually rendered, but all are cheap and keep the fallback
/// path simple.
static inline void ShaderBuildAllTypes(ShaderLaneReader read,
                                       ShaderPluginState *state) {
  state->mesh = ShaderBuildMesh(read);
  state->dithering = ShaderBuildDithering(read);
  state->grain = ShaderBuildGrainy(read);
  state->warp = ShaderBuildWarp(read);
  state->neuro = ShaderBuildNeuro(read);
  state->simplex = ShaderBuildSimplex(read);
  state->metaballs = ShaderBuildMetaballs(read);
  state->godrays = ShaderBuildGodRays(read);
  state->fluid = ShaderBuildFluid(read);
  state->neon = ShaderBuildNeon(read);
  state->silk = ShaderBuildSilk(read);
  state->strata = ShaderBuildStrata(read);
}

NS_ASSUME_NONNULL_END
