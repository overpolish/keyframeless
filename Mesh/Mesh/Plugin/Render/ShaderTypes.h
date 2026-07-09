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

typedef struct MeshGradientUniforms {
    vector_float4 colors[KK_MESH_GRAD_COLORS]; // rgba (straight alpha)
    int colorsCount;                           // active colours (<= 10)
    float time;                                // clip seconds; animates the spots
    float distortion;                          // 0..1 organic noise warp
    float swirl;                               // 0..1 vortex warp
    float speed;                               // time multiplier (motion rate)
    float seed;                                // start-time offset (initial seed)
    float grainMixer;                          // 0..1 grain at the spot edges
    float grainOverlay;                        // 0..1 post grain overlay
    vector_float2 origin;                      // field centre (normalized; 0.5,0.5 = centre)
    vector_float2 scale;                       // common zoom factor per axis (1 = 100%)
    float rotation;                            // common rotation, radians
} MeshGradientUniforms;

// Dithering type: also ported from paper-design/shaders (Apache-2.0). A
// procedural shape (u_shape) rendered through an ordered/random dither
// (u_type) into two colours. resolution is filled at render time (it needs the
// destination pixel dims for the pixel grid).
typedef struct DitheringUniforms {
    vector_float4 colorBack;  // rgba background
    vector_float4 colorFront; // rgba ink
    vector_float2 resolution; // destination pixel dims (set at render time)
    vector_float2 origin;     // swirl/ripple centre (normalized 0..1)
    float time;               // clip seconds
    float speed;              // time multiplier (motion rate)
    float seed;               // start-time offset (shared with Mesh)
    float pxSize;             // dither grid size in reference pixels
    int shape;                // 1..6 (simplex, warp, dots, wave, ripple, swirl)
    int type;                 // 1..4 dither (random, 2x2, 4x4, 8x8 Bayer)
    vector_float2 scale;      // common zoom factor per axis (1 = 100%)
    float rotation;           // common rotation, radians
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
    vector_float2 resolution;                   // destination pixel dims (render time)
    vector_float2 origin;                       // field centre (normalized; 0.5,0.5 = centre)
    float softness;                             // 0..1 band-edge sharpness
    float intensity;                            // 0..1 distortion between bands
    float noise;                                // 0..1 grainy overlay
    float time;                                 // clip seconds
    float speed;                                // time multiplier (motion rate)
    float seed;                                 // start-time offset (shared)
    int shape;                                  // 1..7 (wave, dots, truchet, corners, ripple, blob, sphere)
    vector_float2 scale;                        // common zoom factor per axis (1 = 100%)
    float rotation;                             // common rotation, radians
} GrainGradientUniforms;

// Warp type: also ported from paper-design/shaders (Apache-2.0). Animated colour
// fields warped by noise + iterative swirl over a base pattern (checks / stripes
// / edge). resolution is filled at render time (aspect for the pattern frame +
// the colour-banding dither).
typedef struct WarpUniforms {
    vector_float4 colors[KK_MESH_GRAD_COLORS]; // rgba (straight alpha), up to 10
    int colorsCount;                           // active colours (<= 10)
    vector_float2 resolution;                  // destination pixel dims (render time)
    vector_float2 origin;                      // field centre (normalized; 0.5,0.5 = centre)
    float proportion;                          // 0..1 blend point between colours
    float softness;                            // 0..1 colour-transition sharpness
    float shapeScale;                          // 0..1 base-pattern zoom
    float distortion;                          // 0..1 noise distortion strength
    float swirl;                               // 0..1 swirl strength
    float swirlIterations;                     // 0..20 layered swirl passes
    float time;                                // clip seconds
    float speed;                               // time multiplier (motion rate)
    float seed;                                // start-time offset (shared)
    int shape;                                 // 0..2 (checks, stripes, edge)
    vector_float2 scale;                       // common zoom factor per axis (1 = 100%)
    float rotation;                            // common rotation, radians
} WarpUniforms;

// The Type choice-pill order. Kept in sync with the "Type" pill labels.
typedef enum MeshType {
    MeshType_Mesh = 0,          // paper-design animated mesh gradient
    MeshType_Dithering = 1,     // paper-design dithered procedural shapes
    MeshType_GrainGradient = 2, // paper-design grain gradient ("Grainy")
    MeshType_Warp = 3,          // paper-design warp
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
} MeshPluginState;

typedef enum MeshFragmentIndex {
    MeshFragmentIndex_Grid = 0,
    // 1 => gamma-encode the output (8-bit unorm target, e.g. the mini-viewer or
    // an SDR 8-bit FCP buffer); 0 => leave it linear (FCP float working buffers
    // are linear-light, so an sRGB-encoded value there reads as washed out).
    MeshFragmentIndex_EncodeSRGB = 1
} MeshFragmentIndex;
