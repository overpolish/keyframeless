/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageCustomShader.h"

#import "Constants.h" // declares MirageCustomDefaultShaderSource

// The two baked GLSL sources. Both are trivial image-shader bodies, so they
// always transpile - which is the point: they are the fallbacks every other
// path leans on when the user's own source is absent or broken.

// The default shader: the classic cosine-palette plasma, so Custom renders
// something alive out of the box (and seeds the editor). It also ships the two
// directive-driven on-screen controls the timing guide teaches on - a Center
// the pattern radiates from (a point handle) and a Scale (a ring around that
// centre) - so a fresh instance has real OSCs, not just code. Default values
// reproduce the plain plasma: Center at the frame middle, Scale 3.
NSString *MirageCustomDefaultShaderSource(void) {
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

// The shipped Rounded filter: rounds (and optionally crops / slides) the clip's
// own frame, masking with `// #alpha` so the corners are genuinely transparent
// and a lane below shows through. Ported from the standalone Rounded plugin -
// its whole control set was Radius + Crop, both of which are directive lanes
// here, with the on-screen controls as authored `// @osc` blocks rather than
// the per-plugin Obj-C the original needed.
//
// Both blocks fold in the Position slide, so the box and the radius handle sit
// on the rectangle as DRAWN. `rPix` restates the shader's own radius formula
// (`uRadius * min(halfSize.x, halfSize.y)`) and is divided by `size` per axis,
// which keeps the inset equal in PIXELS - object space is aspect-distorted, so
// a single normalized inset would slide the handle off the corner arc on any
// non-square frame. The radius block omits `fromPos` deliberately: a scalar
// point is numerically inverted by the engine, so the inverse can't drift out
// of sync with `toPos` the way a hand-written one would.
NSString *MirageRoundedShaderSource(void) {
  return @"// #alpha\n"
         @"\n"
         @"// #percent label=\"Radius\" min=0 max=100 default=20\n"
         @"uniform float uRadius;\n"
         @"\n"
         @"// W,H = crop size (% of frame); X,Y = TOP-LEFT corner. W,H clamp "
         @"0-100; X,Y can\n"
         @"// run off-frame (negative / past 100).\n"
         @"// #multi label=\"Crop\" fields={W,H,X,Y} percent min={0,0,,} "
         @"max={100,100,,} default=\"100,100,0,0\"\n"
         @"uniform vec4 uCrop;\n"
         @"\n"
         @"// Slide the whole window from where it sits. 0,0 = in place. (+X "
         @"right, +Y down.)\n"
         @"// % of frame; takes negatives (no min= -> unbounded).\n"
         @"// #multi label=\"Position\" fields={X,Y} percent default=\"0,0\"\n"
         @"uniform vec2 uPosition;\n"
         @"\n"
         @"// @osc Crop\n"
         @"//   primitive = box\n"
         @"//   binds     = uCrop\n"
         @"//   slide     = vec2(uPosition.x, -uPosition.y)\n"
         @"//   lo        = vec2(uCrop.z + slide.x, 1.0 - uCrop.w - uCrop.y + "
         @"slide.y)\n"
         @"//   hi        = vec2(uCrop.z + uCrop.x + slide.x, 1.0 - uCrop.w + "
         @"slide.y)\n"
         @"//   toRect    = rect(lo, hi)\n"
         @"//   fromRect  = vec4(rect.width, rect.height, rect.min.x - "
         @"slide.x, "
         @"1.0 - rect.max.y + slide.y)\n"
         @"\n"
         @"// @osc Radius\n"
         @"//   primitive = point\n"
         @"//   binds     = uRadius\n"
         @"//   style     = square\n"
         @"//   cursor    = resize-diag\n"
         @"//   slide     = vec2(uPosition.x, -uPosition.y)\n"
         @"//   corner    = vec2(uCrop.z + uCrop.x + slide.x, 1.0 - uCrop.w + "
         @"slide.y)\n"
         @"//   rPix      = uRadius * min(uCrop.x * size.x, uCrop.y * size.y) "
         @"* "
         @"0.5\n"
         @"//   toPos     = corner - vec2(rPix / size.x, rPix / size.y)\n"
         @"\n"
         @"float roundedCoverage(vec2 p, vec2 halfSize, float r, float "
         @"radius01) "
         @"{\n"
         @"  float dist;\n"
         @"  if (r < 0.5) {\n"
         @"    vec2 d = abs(p) - halfSize;\n"
         @"    dist = length(max(d, 0.0)) + min(max(d.x, d.y), 0.0);\n"
         @"  } else {\n"
         @"    vec2 inset = max(halfSize - r, 0.0);\n"
         @"    vec2 q = max(abs(p) - inset, 0.0) / r;\n"
         @"    float power = mix(5.0, 2.0, radius01);\n"
         @"    dist = pow(pow(q.x, power) + pow(q.y, power), 1.0 / power) - "
         @"1.0;\n"
         @"  }\n"
         @"  return 1.0 - smoothstep(0.0, fwidth(dist) * 2.0, dist);\n"
         @"}\n"
         @"\n"
         @"void mainImage(out vec4 O, in vec2 fc) {\n"
         @"  vec2 res = iResolution.xy;\n"
         @"\n"
         @"  // Crop window in the clip (top-left origin, Y from the top -> "
         @"flip "
         @"into fc).\n"
         @"  vec2 halfSize  = uCrop.xy * res * 0.5;\n"
         @"  vec2 winCentre = vec2((uCrop.z + uCrop.x * 0.5) * res.x,\n"
         @"                        (1.0 - uCrop.w - uCrop.y * 0.5) * res.y);\n"
         @"\n"
         @"  // Slide the whole window (mask + content) together. +Y = down.\n"
         @"  vec2 offset = vec2(uPosition.x, -uPosition.y) * res;\n"
         @"\n"
         @"  vec2 p     = fc - (winCentre + offset);\n"
         @"  vec2 srcUV = (fc - offset) / res;\n"
         @"  vec4 s     = texture(iChannel0, srcUV);\n"
         @"\n"
         @"  float r     = uRadius * min(halfSize.x, halfSize.y);\n"
         @"  float alpha = roundedCoverage(p, halfSize, r, uRadius);\n"
         @"\n"
         @"  if (any(lessThan(srcUV, vec2(0.0))) || any(greaterThan(srcUV, "
         @"vec2(1.0))))\n"
         @"    alpha = 0.0;\n"
         @"\n"
         @"  O = vec4(s.rgb * alpha, s.a * alpha);\n"
         @"}\n";
}

// Shown when the user's shader fails to compile (e.g. uses iChannel textures or
// has a syntax error): animated dark-red hazard stripes, so a broken shader
// reads as clearly broken instead of a stale / blank frame.
NSString *MirageCustomErrorShaderSource(void) {
  return @"void mainImage( out vec4 fragColor, in vec2 fragCoord ) {\n"
         @"    vec2 uv = fragCoord / iResolution.xy;\n"
         @"    float s = step(0.5, fract((uv.x + uv.y) * 10.0 - iTime));\n"
         @"    vec3 col = mix(vec3(0.22,0.0,0.0), vec3(0.5,0.02,0.02), s);\n"
         @"    fragColor = vec4(col, 1.0);\n"
         @"}\n";
}
