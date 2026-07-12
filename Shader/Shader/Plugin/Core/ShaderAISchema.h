/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// Plain-text lane/value-space description handed to the AI values-pass. The
// plugin is Custom-only (runtime-compiled GLSL): the look is driven entirely by
// the shader source, so only the shared lanes are described here.
#import <Foundation/Foundation.h>

static inline NSString *ShaderAILaneSchemaText(void) {
  return @"Lane labels and value spaces. This is a Shadertoy-style GLSL "
         @"generator: the visuals are driven by the user's shader source (the "
         @"\"Shader\" code lane), and a few shared lanes control timing and "
         @"grain.\n\n"
         @"- \"Speed\": single value, 0..3 multiplier of the animation rate "
         @"(1 = normal, 0 = frozen, 2 = twice as fast). Animatable. Default "
         @"1.\n"
         @"- \"Seed\": integer, the animation start-frame / offset (any "
         @"value). "
         @"NOT animatable. Default 0.\n"
         @"- \"Grain\": percent 0..100. Core film-grain overlay (subtle "
         @"default "
         @"also removes 8-bit banding; higher = stylistic grain). Default 6.\n"
         @"- \"Grain Size\": grain cell size in whole pixels (higher = "
         @"coarser). Default 2.\n"
         @"- \"Shader\": the GLSL (Shadertoy-style) source that draws the "
         @"effect. NOT animatable; the text lives in the lane's code, not a "
         @"keypose.\n";
}
