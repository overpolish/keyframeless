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
  g.origin = (vector_float2){0.5f, 0.5f};
  g.scale = (vector_float2){1.0f, 1.0f};
  g.rotation = 0.0f;
  g.time = 0.0f;
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
  d.colorBack = (vector_float4){0.04f, 0.04f, 0.07f, 1.0f};
  d.colorFront = (vector_float4){0.85f, 0.90f, 0.98f, 1.0f};
  d.resolution = (vector_float2){1920.0f, 1080.0f};
  d.origin = (vector_float2){0.5f, 0.5f};
  d.pxSize = KK_DITHER_DEFAULT_PXSIZE;
  d.shape = KK_DITHER_DEFAULT_SHAPE;
  d.type = KK_DITHER_DEFAULT_TYPE;
  d.speed = KK_DITHER_DEFAULT_SPEED;
  d.seed = 0.0f;
  d.scale = (vector_float2){1.0f, 1.0f};
  d.rotation = 0.0f;
  d.time = 0.0f;
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
  g.resolution = (vector_float2){1920.0f, 1080.0f};
  g.origin = (vector_float2){0.5f, 0.5f};
  g.softness = KK_GRAIN_DEFAULT_SOFTNESS;
  g.intensity = KK_GRAIN_DEFAULT_INTENSITY;
  g.noise = KK_GRAIN_DEFAULT_NOISE;
  g.shape = KK_GRAIN_DEFAULT_SHAPE;
  g.speed = KK_GRAIN_DEFAULT_SPEED;
  g.seed = 0.0f;
  g.scale = (vector_float2){1.0f, 1.0f};
  g.rotation = 0.0f;
  g.time = 0.0f;
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
  w.resolution = (vector_float2){1920.0f, 1080.0f};
  w.origin = (vector_float2){0.5f, 0.5f};
  w.proportion = KK_WARP_DEFAULT_PROPORTION;
  w.softness = KK_GRAIN_DEFAULT_SOFTNESS; // shared "Softness" lane
  w.shapeScale = KK_WARP_DEFAULT_SHAPESCALE;
  w.distortion = KK_MESH_GRAD_DEFAULT_DISTORTION; // shared "Distortion" lane
  w.swirl = KK_MESH_GRAD_DEFAULT_SWIRL;           // shared "Swirl" lane
  w.swirlIterations = KK_WARP_DEFAULT_SWIRLITER;
  w.shape = KK_WARP_DEFAULT_SHAPE;
  w.speed = KK_MESH_GRAD_DEFAULT_SPEED;
  w.seed = 0.0f;
  w.scale = (vector_float2){1.0f, 1.0f};
  w.rotation = 0.0f;
  w.time = 0.0f;
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
  n.colorFront = (vector_float4){0.85f, 0.92f, 1.0f, 1.0f}; // highlight
  n.colorMid = (vector_float4){0.25f, 0.45f, 0.95f, 1.0f};  // lines
  n.colorBack = (vector_float4){0.02f, 0.03f, 0.08f, 1.0f}; // background
  n.resolution = (vector_float2){1920.0f, 1080.0f};
  n.origin = (vector_float2){0.5f, 0.5f};
  n.scale = (vector_float2){1.0f, 1.0f};
  n.brightness = KK_NEURO_DEFAULT_BRIGHTNESS;
  n.contrast = KK_NEURO_DEFAULT_CONTRAST;
  n.speed = 1.0f;
  n.seed = 0.0f;
  n.rotation = 0.0f;
  n.time = 0.0f;
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
  s.resolution = (vector_float2){1920.0f, 1080.0f};
  s.origin = (vector_float2){0.5f, 0.5f};
  s.scale = (vector_float2){1.0f, 1.0f};
  s.stepsPerColor = KK_SIMPLEX_DEFAULT_STEPS;
  s.softness = KK_SIMPLEX_DEFAULT_SOFTNESS;
  s.speed = KK_MESH_GRAD_DEFAULT_SPEED;
  s.seed = 0.0f;
  s.rotation = 0.0f;
  s.time = 0.0f;
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
  m.resolution = (vector_float2){1920.0f, 1080.0f};
  m.origin = (vector_float2){0.5f, 0.5f};
  m.scale = (vector_float2){1.0f, 1.0f};
  m.ballCount = KK_METABALLS_DEFAULT_COUNT;
  m.ballSize = KK_METABALLS_DEFAULT_SIZE;
  m.speed = KK_MESH_GRAD_DEFAULT_SPEED;
  m.seed = 0.0f;
  m.rotation = 0.0f;
  m.time = 0.0f;
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
  g.resolution = (vector_float2){1920.0f, 1080.0f};
  g.origin = (vector_float2){0.5f, 0.5f};
  g.scale = (vector_float2){1.0f, 1.0f};
  g.density = KK_GODRAYS_DEFAULT_DENSITY;
  g.spotty = KK_GODRAYS_DEFAULT_SPOTTY;
  g.midSize = KK_GODRAYS_DEFAULT_MIDSIZE;
  g.midIntensity = KK_GODRAYS_DEFAULT_MIDINTENSITY;
  g.intensity = KK_GODRAYS_DEFAULT_INTENSITY;
  g.bloom = KK_GODRAYS_DEFAULT_BLOOM;
  g.speed = KK_MESH_GRAD_DEFAULT_SPEED;
  g.seed = 0.0f;
  g.rotation = 0.0f;
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
