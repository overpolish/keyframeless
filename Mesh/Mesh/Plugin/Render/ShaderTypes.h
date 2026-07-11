/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <simd/simd.h>

// Shared by the FCP render (Plugin+Render.m), the mini-viewer renderer
// (MeshMiniViewerRenderer.m), and the Metal shader (Mesh.metal).
//
// The gradient is the paper-design/shaders mesh-gradient (Apache-2.0), ported
// GLSL -> MSL: up to `colorsCount` colour spots animate along procedural
// trajectories and are blended by inverse-distance, warped by noise distortion
// + swirl, with an in-shader grain mixer and overlay. Colours are straight
// sRGB+alpha; the shader blends them directly (no OKLab pass) and linearises
// only for FCP's float working buffer.

// Max colour spots (the source shader blends up to 10 by inverse-distance).
#define KK_MESH_GRAD_COLORS 10

// Shared params common to every Type, passed in their own fragment buffer
// (MeshFragmentIndex_Common) so the per-Type uniform structs don't each
// re-declare them. Filled once per render. `grain` is the core film-grain
// overlay (also anti-banding); `grainScale` is the per-Type multiplier so e.g.
// Grainy reads stylistically grainy by default while others stay subtle.
typedef struct MeshCommonUniforms {
    // Shared transforms + timing (identical for every Type, read once per render).
    vector_float2 origin; // field centre (normalized; 0.5,0.5 = centre)
    vector_float2 scale;  // common zoom factor per axis (1 = 100%)
    float rotation;       // common rotation, radians
    float time;           // clip seconds
    float speed;          // time multiplier (motion rate)
    float seed;           // start-time offset (shared)
    // Core film grain.
    float grain;              // 0..1 core film-grain amount (nonzero default = anti-band)
    float grainSize;          // grain cell size in reference pixels (higher = coarser)
    float grainScale;         // per-Type multiplier applied to `grain` (set at build)
    vector_float2 resolution; // destination pixel dims (for reference-res grain + supersample)
} MeshCommonUniforms;

typedef struct MeshGradientUniforms {
    vector_float4 colors[KK_MESH_GRAD_COLORS]; // rgba (straight alpha)
    int colorsCount;                           // active colours (<= 10)
    float distortion;                          // 0..1 organic noise warp
    float swirl;                               // 0..1 vortex warp
} MeshGradientUniforms;

// Dithering type: also ported from paper-design/shaders (Apache-2.0). A
// procedural shape (u_shape) drives a POSITION along the colour palette; the
// ordered/random dither (u_type) stipples the transitions between adjacent
// palette colours (a retro dithered multi-colour gradient). Color 1 is the low
// end (the base/background), Color N the high end. resolution is filled at
// render time (it needs the destination pixel dims for the pixel grid).
typedef struct DitheringUniforms {
    vector_float4 colors[KK_MESH_GRAD_COLORS]; // rgba palette ramp (straight alpha)
    int colorsCount;                           // active colours (<= 10)
    float pxSize;                              // dither grid size in reference pixels
    int shape;                                 // 1..6 (simplex, warp, dots, wave, ripple, swirl)
    int type;                                  // 1..4 dither (random, 2x2, 4x4, 8x8 Bayer)
} DitheringUniforms;

// Grain Gradient type ("Grainy"): also ported from paper-design/shaders
// (Apache-2.0). A procedural shape field (u_shape) indexes a multi-colour ramp,
// distorted by noise (intensity) with a grainy overlay (noise), composited over
// a background. resolution is filled at render time (the grain is computed from
// fragCoord / resolution, like Dithering).
#define KK_GRAIN_GRAD_COLORS 7

typedef struct GrainGradientUniforms {
    vector_float4 colors[KK_GRAIN_GRAD_COLORS]; // rgba (straight alpha)
    int colorsCount;                            // active colours (<= 7)
    vector_float4 colorBack;                    // rgba background
    float softness;                             // 0..1 band-edge sharpness
    float intensity;                            // 0..1 distortion between bands
    float noise;                                // 0..1 grainy overlay
    int shape;                                  // 1..7 (wave, dots, truchet, corners, ripple, blob, sphere)
} GrainGradientUniforms;

// Warp type: also ported from paper-design/shaders (Apache-2.0). Animated colour
// fields warped by noise + iterative swirl over a base pattern (checks / stripes
// / edge). resolution is filled at render time (aspect for the pattern frame +
// the colour-banding dither).
typedef struct WarpUniforms {
    vector_float4 colors[KK_MESH_GRAD_COLORS]; // rgba (straight alpha), up to 10
    int colorsCount;                           // active colours (<= 10)
    float proportion;                          // 0..1 blend point between colours
    float softness;                            // 0..1 colour-transition sharpness
    float shapeScale;                          // 0..1 base-pattern zoom
    float distortion;                          // 0..1 noise distortion strength
    float swirl;                               // 0..1 swirl strength
    float swirlIterations;                     // 0..20 layered swirl passes
    int shape;                                 // 0..2 (checks, stripes, edge)
} WarpUniforms;

// Neuro Noise type ("Neuro"): also ported from paper-design/shaders
// (Apache-2.0). A glowing, web-like structure of fluid lines (accumulated
// rotated sine layers). The line intensity drives a POSITION along the palette:
// Color 1 is the base (background), brighter crossings climb the ramp (smooth
// glow blend). resolution is filled at render time (aspect for the pattern
// frame + the colour-banding dither).
typedef struct NeuroNoiseUniforms {
    vector_float4 colors[KK_MESH_GRAD_COLORS]; // rgba palette ramp (straight alpha)
    int colorsCount;                           // active colours (<= 10)
    float brightness;                          // 0..1 luminosity of the crossings
    float contrast;                            // 0..1 bright-dark sharpness
} NeuroNoiseUniforms;

// Simplex Noise type ("Simplex"): also ported from paper-design/shaders
// (Apache-2.0). A multi-colour gradient mapped into smooth animated curves from
// a combination of two Simplex noises, stepped into bands. resolution is filled
// at render time (aspect for the pattern frame + the colour-banding dither).
typedef struct SimplexNoiseUniforms {
    vector_float4 colors[KK_MESH_GRAD_COLORS]; // rgba (straight alpha), up to 10
    int colorsCount;                           // active colours (<= 10)
    float stepsPerColor;                       // 1..10 extra colours between base colours
    float softness;                            // 0..1 colour-transition sharpness
} SimplexNoiseUniforms;

// Metaballs type ("Metaballs"): also ported from paper-design/shaders
// (Apache-2.0). Up to 20 coloured gooey balls roam the centre and merge into
// smooth organic shapes over a background. resolution is filled at render time
// (aspect for the pattern frame + the colour-banding dither).
typedef struct MetaballsUniforms {
    vector_float4 colors[KK_MESH_GRAD_COLORS]; // rgba (straight alpha), indexed modulo colorsCount
    int colorsCount;                           // active colours (<= 10; shader wraps by count)
    vector_float4 colorBack;                   // rgba background
    float ballCount;                           // 1..20 active balls
    float ballSize;                            // 0..1 ball size
} MetaballsUniforms;

// God Rays type ("God Rays"): also ported from paper-design/shaders
// (Apache-2.0). Animated rays of light radiating from the centre, blended
// through up to 5 ray colours over a background, with a central glow and a
// bloom overlay. resolution is filled at render time (aspect for the pattern
// frame + the colour-banding dither).
typedef struct GodRaysUniforms {
    vector_float4 colors[KK_MESH_GRAD_COLORS]; // rgba (straight alpha); up to 5 used
    int colorsCount;                           // active ray colours (<= 5)
    vector_float4 colorBack;                   // rgba background
    vector_float4 colorBloom;                  // rgba overlay blended with the rays
    float density;                             // 0..1 number of rays
    float spotty;                              // 0..1 ray length (higher = shorter/spottier)
    float midSize;                             // 0..1 central glow size
    float midIntensity;                        // 0..1 central glow brightness
    float intensity;                           // 0..1 ray visibility/strength
    float bloom;                               // 0..1 alpha->additive blend of the rays + overlay
} GodRaysUniforms;

// Fluid type ("Fluid"): ported from radiant-shaders "Fluid Amber" (pbakaus/
// radiant, MIT) GLSL -> MSL. Iterative IQ domain warp (fbm feeding fbm) whose
// field values composite the palette swatches in layers, giving a molten,
// marbled flow. resolution is filled at render time (aspect for the pattern
// frame + the banding dither).
typedef struct FluidUniforms {
    vector_float4 colors[KK_MESH_GRAD_COLORS]; // rgba (straight alpha), up to 10 (~4 used)
    int colorsCount;                           // active colours (<= 10)
    float detail;                              // fbm amplitude persistence (0..1; higher = richer)
    float marble;                              // domain-warp strength (0 = smooth, 1 = source, higher = intense)
    float vibrance;                            // colour-layer separation (1 = source; higher = punchier)
} FluidUniforms;

// Neon type ("Neon"): ported from radiant-shaders "Neon Drip" (pbakaus/radiant,
// MIT) GLSL -> MSL, then reduced to just the glowing tendril WISPS (the source's
// metaball blobs were dropped by request). The tendril field is layered through
// a 4-stop HDR neon ramp (glow/surface/inner/core) and ACES tone-mapped over a
// dark backdrop. resolution is filled at render time.
typedef struct NeonUniforms {
    vector_float4 colors[KK_MESH_GRAD_COLORS]; // rgba (glow, surface, inner, core = 1..4)
    int colorsCount;                           // active colours (<= 10; ~4 used)
    vector_float4 colorBack;                   // rgba dark backdrop
    float radiance;                            // HDR neon gain (bloom punch)
    float wisps;                               // tendril-wisp strength / coverage
    float strands;                             // tendril fineness (frequency; higher = finer strands)
} NeonUniforms;

// Silk type ("Silk"): ported from radiant-shaders "Silk Cascade" (pbakaus/
// radiant, MIT) GLSL -> MSL. Three domain-warped fabric-fold layers with
// Kajiya-Kay anisotropic specular (silk sheen), lit + 3-tone shaded and
// composited back-to-front over a dark backdrop. Each layer takes ONE palette
// hue (Color 1..3); its dark/mid/bright/sheen tones are derived from that hue.
// resolution is filled at render time.
typedef struct SilkUniforms {
    vector_float4 colors[KK_MESH_GRAD_COLORS]; // rgba; Color 1..3 = the 3 layer hues
    int colorsCount;                           // active colours (<= 10; ~3 used)
    vector_float4 colorBack;                   // rgba dark backdrop
    float sheen;                               // silk specular / sheen intensity
    float folds;                               // fold frequency scale (density of the folds)
    float drape;                               // domain-warp strength (how much folds curve/flow)
} SilkUniforms;

// Strata type ("Strata"): ported from radiant-shaders "Painted Strata" (pbakaus/
// radiant, MIT) GLSL -> MSL. Stacked geological strata layers with wavy folded
// boundaries, a tectonic domain warp, per-layer palette colours and washi-paper
// grain. Each layer hashes to a palette swatch. resolution is filled at render
// time.
typedef struct StrataUniforms {
    vector_float4 colors[KK_MESH_GRAD_COLORS]; // rgba; layers pick from these by hash
    int colorsCount;                           // active colours (<= 10)
    float layers;                              // 2..24 strata layer count
    float tectonics;                           // deformation strength (warp + boundary fold)
    float texture;                             // washi-paper grain intensity
} StrataUniforms;

// The Type choice-pill order. Kept in sync with the "Type" pill labels.
typedef enum MeshType {
    MeshType_Mesh = 0,          // paper-design animated mesh gradient
    MeshType_Dithering = 1,     // paper-design dithered procedural shapes
    MeshType_GrainGradient = 2, // paper-design grain gradient ("Grainy")
    MeshType_Warp = 3,          // paper-design warp
    MeshType_Neuro = 4,         // paper-design neuro-noise ("Neuro")
    MeshType_Simplex = 5,       // paper-design simplex-noise ("Simplex")
    MeshType_Metaballs = 6,     // paper-design metaballs ("Metaballs")
    MeshType_GodRays = 7,       // paper-design god-rays ("God Rays")
    MeshType_Fluid = 8,         // radiant-shaders fluid-amber ("Fluid")
    MeshType_Neon = 9,          // radiant-shaders neon-drip ("Wisp")
    MeshType_Silk = 10,         // radiant-shaders silk-cascade ("Silk")
    MeshType_Strata = 11,       // radiant-shaders painted-strata ("Strata")
    MeshType_Custom = 12,       // user-supplied shader, runtime-compiled
} MeshType;

// The full render state packed into pluginState: the active type plus each
// type's uniform block (only the active one is filled). render/mini-viewer
// pick the pipeline + uniform bytes off `type`.
typedef struct MeshPluginState {
    int type;
    int _pad0;
    MeshGradientUniforms mesh;
    DitheringUniforms dithering;
    GrainGradientUniforms grain;
    WarpUniforms warp;
    NeuroNoiseUniforms neuro;
    SimplexNoiseUniforms simplex;
    MetaballsUniforms metaballs;
    GodRaysUniforms godrays;
    FluidUniforms fluid;
    NeonUniforms neon;
    SilkUniforms silk;
    StrataUniforms strata;
    MeshCommonUniforms common;
} MeshPluginState;

typedef enum MeshFragmentIndex {
    MeshFragmentIndex_Grid = 0,
    // 1 => gamma-encode the output (8-bit unorm target, e.g. the mini-viewer or
    // an SDR 8-bit FCP buffer); 0 => leave it linear (FCP float working buffers
    // are linear-light, so an sRGB-encoded value there reads as washed out).
    MeshFragmentIndex_EncodeSRGB = 1,
    // Shared params (MeshCommonUniforms) - grain + time, common to all Types.
    MeshFragmentIndex_Common = 2
} MeshFragmentIndex;
