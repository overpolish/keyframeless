/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// CPU-side shared-param helpers for the FCP render and the mini-viewer. The
// plugin is Custom-only (runtime-compiled GLSL); the per-Type palette/scalar
// machinery this file used to hold was removed with the built-in Types. Not for
// Metal (uses libm); guarded just in case.
#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>
#import <math.h>
#import <string.h>

#import "ShaderTypes.h"

/// Shared timing defaults.
#define KK_SHADER_GRAD_DEFAULT_SPEED 1.0f // time multiplier (1 = source rate)
#define KK_SHADER_GRAD_DEFAULT_SEED 0.0f

/// Core film-grain overlay (ShaderCommonUniforms). A subtle nonzero default so a
/// fresh instance has tasteful grain that also breaks up 8-bit banding.
#define KK_CORE_GRAIN_DEFAULT 0.06f    // amount (0..1)
#define KK_CORE_GRAINSIZE_DEFAULT 2.0f // grain cell size in whole pixels

/// Fallback shared-params block (timing + grain). `origin`/`scale`/`rotation`
/// are vestigial identity values (the legacy transform lanes are gone).
static inline ShaderCommonUniforms ShaderCommonDefault(void) {
    ShaderCommonUniforms c;
    memset(&c, 0, sizeof(c));
    c.origin = (vector_float2){0.5f, 0.5f};
    c.scale = (vector_float2){1.0f, 1.0f};
    c.rotation = 0.0f;
    c.time = 0.0f;
    c.speed = KK_SHADER_GRAD_DEFAULT_SPEED;
    c.seed = 0.0f;
    c.grain = KK_CORE_GRAIN_DEFAULT;
    c.grainSize = KK_CORE_GRAINSIZE_DEFAULT;
    c.grainScale = 1.0f;
    c.resolution = (vector_float2){1920.0f, 1080.0f};
    return c;
}

#endif // __METAL_VERSION__
