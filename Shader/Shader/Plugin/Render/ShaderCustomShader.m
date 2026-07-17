/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "ShaderCustomShader.h"

#import "Constants.h" // declares ShaderCustomDefaultShaderSource

// The two baked GLSL sources. Both are trivial image-shader bodies, so they
// always transpile - which is the point: they are the fallbacks every other
// path leans on when the user's own source is absent or broken.

// The default shader: the classic cosine-palette plasma, so Custom renders
// something alive out of the box (and seeds the editor). It also ships the two
// directive-driven on-screen controls the timing guide teaches on - a Center
// the pattern radiates from (a point handle) and a Scale (a ring around that
// centre) - so a fresh instance has real OSCs, not just code. Default values
// reproduce the plain plasma: Center at the frame middle, Scale 3.
NSString *ShaderCustomDefaultShaderSource(void) {
  return @"// #point label=\"Center\" osc default=\"0.5,0.5\"\n"
         @"uniform vec2 uCenter;\n"
         @"// #float label=\"Scale\" osc=ring link=uCenter min=1 max=8 "
         @"default=3\n"
         @"uniform float uScale;\n"
         @"\n"
         @"void mainImage( out vec4 fragColor, in vec2 fragCoord ) {\n"
         @"    vec2 uv = (fragCoord - uCenter) / iResolution.xy;\n"
         @"    vec3 col = 0.5 + 0.5 * cos(iTime + uv.xyx * uScale + "
         @"vec3(0.0, 2.0, 4.0));\n"
         @"    fragColor = vec4(col, 1.0);\n"
         @"}\n";
}

// Shown when the user's shader fails to compile (e.g. uses iChannel textures or
// has a syntax error): animated dark-red hazard stripes, so a broken shader
// reads as clearly broken instead of a stale / blank frame.
NSString *ShaderCustomErrorShaderSource(void) {
  return @"void mainImage( out vec4 fragColor, in vec2 fragCoord ) {\n"
         @"    vec2 uv = fragCoord / iResolution.xy;\n"
         @"    float s = step(0.5, fract((uv.x + uv.y) * 10.0 - iTime));\n"
         @"    vec3 col = mix(vec3(0.22,0.0,0.0), vec3(0.5,0.02,0.02), s);\n"
         @"    fragColor = vec4(col, 1.0);\n"
         @"}\n";
}
