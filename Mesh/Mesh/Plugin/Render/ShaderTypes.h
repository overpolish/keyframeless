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
} MeshGradientUniforms;

typedef enum MeshFragmentIndex {
    MeshFragmentIndex_Grid = 0,
    // 1 => gamma-encode the output (8-bit unorm target, e.g. the mini-viewer or
    // an SDR 8-bit FCP buffer); 0 => leave it linear (FCP float working buffers
    // are linear-light, so an sRGB-encoded value there reads as washed out).
    MeshFragmentIndex_EncodeSRGB = 1
} MeshFragmentIndex;
