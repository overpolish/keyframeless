/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <simd/simd.h>

// Shared by the FCP render (Plugin+Render.m), the mini-viewer renderer
// (ShaderMiniViewerRenderer.m), and the Metal shader (Shader.metal).
//
// The gradient is the paper-design/shaders mesh-gradient (Apache-2.0), ported
// GLSL -> MSL: up to `colorsCount` colour spots animate along procedural
// trajectories and are blended by inverse-distance, warped by noise distortion
// + swirl, with an in-shader grain mixer and overlay. Colours are straight
// sRGB+alpha; the shader blends them directly (no OKLab pass) and linearises
// only for FCP's float working buffer.

// Max colour spots (the source shader blends up to 10 by inverse-distance).
#define KK_SHADER_GRAD_COLORS 10

// Shared params common to every Type, passed in their own fragment buffer
// (ShaderFragmentIndex_Common) so the per-Type uniform structs don't each
// re-declare them. Filled once per render. `grain` is the core film-grain
// overlay (also anti-banding); `grainScale` is the per-Type multiplier so e.g.
// Grainy reads stylistically grainy by default while others stay subtle.
typedef struct ShaderCommonUniforms {
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
} ShaderCommonUniforms;

// The full render state packed into pluginState. The plugin is Custom-only
// (runtime-compiled GLSL), so this now carries just the shared params; the user
// shader source rides in the blob tail after this struct.
typedef struct ShaderPluginState {
    ShaderCommonUniforms common;
} ShaderPluginState;

typedef enum ShaderFragmentIndex {
    ShaderFragmentIndex_Grid = 0,
    // 1 => gamma-encode the output (8-bit unorm target, e.g. the mini-viewer or
    // an SDR 8-bit FCP buffer); 0 => leave it linear (FCP float working buffers
    // are linear-light, so an sRGB-encoded value there reads as washed out).
    ShaderFragmentIndex_EncodeSRGB = 1,
    // Shared params (ShaderCommonUniforms) - grain + time, common to all Types.
    ShaderFragmentIndex_Common = 2
} ShaderFragmentIndex;
