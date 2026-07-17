/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKGLSLTranspiler.h"
#import "ShaderDirectives.h" // ShaderParseColorProps (`// #color` block injection)

#include <string>
#include <vector>

#include "glslang/Include/glslang_c_interface.h"
#include "glslang/Public/resource_limits_c.h"
#include "spirv_cross/spirv_cross_c.h"

#import <KeyframelessKit/KKLog.h>

// GLSL body -> full core-450 GLSL. No #version (forced via the API): the
// uniform block is all-vec4 so std140 maps 1:1 to KKGLSLUniforms; iResolution /
// iTime / iTimeDelta / iFrame are aliased onto its lanes. flipY, sRGB-encode and
// premultiply live in main() driven by kkExtra so they stay runtime choices.
// GLSL permits identifiers like `or`, `and`, `xor`, `compl` that are reserved
// OPERATOR tokens in MSL/C++ (Metal is C++-based). SPIRV-Cross carries the
// source name straight into the MSL, where it fails the Metal compile. Rename
// them (word-boundary) in the user source before wrapping. `not` is DELIBERATELY
// excluded - it's a GLSL built-in function (`not(bvec)`); renaming it would break
// shaders that use it. Line count is preserved (word -> word), so the glslang
// error-line mapping is unaffected.
static NSString *KKRenameReservedIdentifiers(NSString *src) {
  if (!src.length)
    return src ?: @"";
  static NSRegularExpression *re;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    re = [NSRegularExpression
        regularExpressionWithPattern:
            @"\\b(and|and_eq|bitand|bitor|compl|not_eq|or|or_eq|xor|xor_eq|new|"
            @"delete|operator|friend|mutable|typename|register|namespace|using|"
            @"private|protected|public|class|template|this)\\b"
                             options:0
                               error:nil];
  });
  return [re stringByReplacingMatchesInString:src
                                      options:0
                                        range:NSMakeRange(0, src.length)
                                 withTemplate:@"kk_$1"];
}

// Best-effort compatibility shim. Plenty of shaders online are written for a raw
// WebGL / three.js / glslCanvas / Book-of-Shaders pipeline: a `void main()` +
// `gl_FragColor` (or a GLSL3 `out vec4`) fragment that reads host-named uniforms
// (uTexture, vUv, u_time, ...). This engine speaks the image-shader convention
// (`mainImage(out vec4, in vec2)` with iChannel0 / iResolution / iTime), so those
// shaders would collide on `main` and reference undeclared names. This pass
// rewrites the common cases into our convention: it maps the well-known host
// uniform / varying names, converts the entry point + output, neutralises the
// gl_ builtins, and drops declarations we supply ourselves. Line-count preserving
// so a glslang error still maps to the editor line. A shader already using
// `mainImage` passes through untouched; uncommon custom uniform names still need
// a hand edit (the validator points at them).
// gl-transitions.com shaders speak a neighbouring dialect: a
// `vec4 transition(vec2 uv)` entry point, host-supplied `progress` / `ratio` /
// `getFromColor` / `getToColor`, and custom uniforms whose default rides in a
// trailing `// = value` comment. Adapt them rather than make an author hand-port
// every shader in the catalogue. The signature is the tell - nothing else
// declares `vec4 transition(vec2`.
static BOOL KKLooksLikeGLTransition(NSString *src) {
  if (!src.length)
    return NO;
  static NSRegularExpression *re;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    re = [NSRegularExpression
        regularExpressionWithPattern:@"\\bvec4\\s+transition\\s*\\(\\s*vec2"
                             options:0
                               error:nil];
  });
  return [re firstMatchInString:src
                        options:0
                          range:NSMakeRange(0, src.length)] != nil;
}

// `// #alpha`: the shader's own alpha is authoritative - emit it premultiplied,
// with no compositing over the source and no forced-opaque.
//
// The two default conventions can't express a shader that MASKS its own clip -
// e.g. a stacked-clips picture-in-picture, where each instance draws its clip
// into one region and must be genuinely TRANSPARENT elsewhere so the lane below
// shows through. Sampling iChannel0 (which such a shader must, to draw itself)
// takes the filter path and forces a=1; the generator path instead composites
// over iChannel0, which here is the very clip being masked. Hence a third mode,
// opt-in because forcing a=1 remains the right default for golfed pastes that
// leave garbage in fragColor.a.
static BOOL KKWantsAlphaOutput(NSString *src) {
  if (!src.length)
    return NO;
  static NSRegularExpression *re;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    re = [NSRegularExpression
        regularExpressionWithPattern:@"(?m)^[ \\t]*//[ \\t]*#alpha\\b"
                             options:0
                               error:nil];
  });
  return [re firstMatchInString:src
                        options:0
                          range:NSMakeRange(0, src.length)] != nil;
}

// Fold a GL-Transitions shader into the image-shader convention.
//
// Both rewrites are LINE-COUNT SAFE so a glslang error still maps to the
// editor: the uniform fold stays on its own line, and `mainImage` is APPENDED
// (appending shifts nothing above it). The preamble that supplies
// getFromColor / getToColor / progress / ratio is emitted by KKWrapGLSL's
// prepended block instead, which `lineOffset` already accounts for.
static NSString *KKShimGLTransition(NSString *src) {
  if (!KKLooksLikeGLTransition(src))
    return src;
  NSMutableString *s = [src mutableCopy];

  // `uniform float strength; // = 1.0` -> `const float strength = 1.0;`.
  // Left as a bare uniform it would get a binding nothing ever writes, so every
  // knob would silently read 0 (and this shader's burst() would flatten to
  // nothing). Constants make it RUN correctly on the author's defaults; turning
  // these into real inspector controls is the next step.
  NSRegularExpression *uni = [NSRegularExpression
      regularExpressionWithPattern:@"(?m)\\buniform\\s+(float|int|bool|vec2|vec3"
                                   @"|vec4)\\s+(\\w+)\\s*;[ \\t]*//[ \\t]*=[ "
                                   @"\\t]*(.+)$"
                           options:0
                             error:nil];
  [uni replaceMatchesInString:s
                      options:0
                        range:NSMakeRange(0, s.length)
                 withTemplate:@"const $1 $2 = $3;"];

  [s appendString:@"\nvoid mainImage(out vec4 O, in vec2 fc){ O = "
                  @"transition(fc / iResolution.xy); }\n"];
  return s;
}

static NSString *KKShimRawGLSL(NSString *src) {
  if (!src.length)
    return src ?: @"";
  if ([src rangeOfString:@"mainImage"].location != NSNotFound)
    return src; // already an image shader

  NSRegularExpression *mainRe = [NSRegularExpression
      regularExpressionWithPattern:@"\\bvoid\\s+main\\s*\\("
                           options:0
                             error:nil];
  BOOL looksRaw =
      [src rangeOfString:@"gl_FragColor"].location != NSNotFound ||
      [src rangeOfString:@"gl_FragData"].location != NSNotFound ||
      [mainRe firstMatchInString:src
                         options:0
                           range:NSMakeRange(0, src.length)] != nil;
  if (!looksRaw)
    return src; // a bare helper snippet: leave it be

  NSMutableString *s = [src mutableCopy];
  NSString *(^find)(NSString *) = ^NSString *(NSString *pat) {
    NSRegularExpression *re =
        [NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:s
                                             options:0
                                               range:NSMakeRange(0, s.length)];
    return (m && m.numberOfRanges > 1) ? [s substringWithRange:[m rangeAtIndex:1]]
                                       : nil;
  };
  void (^sub)(NSString *, NSString *) = ^(NSString *pat, NSString *repl) {
    NSRegularExpression *re =
        [NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil];
    [re replaceMatchesInString:s
                       options:0
                         range:NSMakeRange(0, s.length)
                  withTemplate:repl];
  };
  void (^mapNames)(NSArray<NSString *> *, NSString *) =
      ^(NSArray<NSString *> *names, NSString *repl) {
        NSMutableArray *esc = [NSMutableArray array];
        for (NSString *n in names)
          [esc addObject:[NSRegularExpression escapedPatternForString:n]];
        sub([NSString stringWithFormat:@"\\b(?:%@)\\b",
                                       [esc componentsJoinedByString:@"|"]],
            repl);
      };

  // GLSL3 shaders name their output arbitrarily: capture `out vec4 <name>;`
  // before we strip declarations so we can route <name> to our out param.
  NSString *outName = find(@"(?m)^[ \\t]*out\\s+vec4\\s+(\\w+)\\s*;");

  // Capture every declared sampler2D uniform (before we strip declarations). Our
  // engine has one real texture input (iChannel0 = source), so mapping declared
  // samplers to iChannel0..3 in order lets a single-texture raw shader work
  // whatever the sampler is named - no hardcoded name list needed.
  NSMutableArray<NSString *> *samplerNames = [NSMutableArray array];
  {
    NSRegularExpression *sre = [NSRegularExpression
        regularExpressionWithPattern:
            @"(?m)^[ \\t]*uniform\\s+sampler2D\\s+(\\w+)"
                             options:0
                               error:nil];
    [sre enumerateMatchesInString:s
                          options:0
                            range:NSMakeRange(0, s.length)
                       usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flg,
                                    BOOL *stop) {
                         if (m.numberOfRanges > 1)
                           [samplerNames
                               addObject:[s substringWithRange:[m rangeAtIndex:1]]];
                       }];
  }

  // Drop declarations we provide (or can't bind) + #version / precision. Content
  // only, newline kept, so error-line mapping survives.
  sub(@"(?m)^[ \\t]*(?:uniform|varying|attribute|in|out)\\b[^;\\n]*;", @"");
  sub(@"(?m)^[ \\t]*precision\\b[^;\\n]*;", @"");
  sub(@"(?m)^[ \\t]*#version\\b[^\\n]*", @"");

  // Declared samplers -> iChannel0..3 in declaration order (the primary texture
  // becomes the source clip). Handles any name, so `videoTex`, `myFunkyTex`, etc.
  // work without appearing in the list below.
  for (NSUInteger i = 0; i < samplerNames.count && i < 4; i++)
    mapNames(@[ samplerNames[i] ],
             [NSString stringWithFormat:@"iChannel%lu", (unsigned long)i]);

  // Map the well-known host names onto our globals (covers a texture used without
  // an explicit declaration). Deliberately conservative: only distinctive,
  // prefixed names (never bare `time` / `uv` / `resolution`) so a local variable
  // is never clobbered.
  mapNames(@[
    @"uTexture", @"u_texture", @"tDiffuse", @"texture0", @"tex0", @"uSampler",
    @"uTex", @"u_tex", @"uImage", @"uMainTex", @"inputTexture", @"backbuffer",
    @"uDiffuse", @"uSource"
  ],
           @"iChannel0");
  // Raw-GL resolution / mouse uniforms are vec2; iResolution is vec3 and iMouse
  // vec4, so map to the .xy swizzle or a `vec2 / iResolution` divide fails to
  // type-check. `.xy.x` / `.xy.xy` chains stay legal for the `.x` access case.
  mapNames(@[ @"u_resolution", @"uResolution", @"uRes", @"u_res" ],
           @"iResolution.xy");
  mapNames(@[ @"u_time", @"uTime", @"iGlobalTime", @"uElapsedTime" ], @"iTime");
  mapNames(@[ @"u_mouse", @"uMouse" ], @"iMouse.xy");
  mapNames(@[ @"vUv", @"vUV", @"v_uv", @"vTexCoord", @"vTextureCoord", @"vST" ],
           @"(kk_fragCoord.xy / iResolution.xy)");

  // Output + coordinate builtins. gl_FragCoord becomes the incoming coord (its
  // .z/.w are effectively unused by image shaders).
  if (outName.length)
    mapNames(@[ outName ], @"kk_fragColor");
  sub(@"gl_FragData\\s*\\[\\s*0\\s*\\]", @"kk_fragColor");
  mapNames(@[ @"gl_FragColor", @"gl_FragData" ], @"kk_fragColor");
  mapNames(@[ @"gl_FragCoord" ], @"vec4(kk_fragCoord, 0.0, 1.0)");
  mapNames(@[ @"texture2D", @"textureCube" ], @"texture");

  // The entry point itself (kept on one line to preserve mapping).
  sub(@"\\bvoid\\s+main\\s*\\([^)\\n]*\\)",
      @"void mainImage(out vec4 kk_fragColor, in vec2 kk_fragCoord)");
  return s;
}

/// Which iChannels the WRAPPED shader declares - what the render must bind.
///
/// Not the same as what the user's source references: a generator that never
/// samples iChannel0 still gets it declared, so its alpha can composite over the
/// footage (see `honorAlpha` below). Binding follows the declaration, so this is
/// the set that matters; reporting the user's set instead left channel 0
/// declared but its sampler never created, and the draw bound nil.
static NSUInteger KKDeclaredChannelMask(NSUInteger channelMask, BOOL bufferMode) {
  BOOL honorAlpha = !bufferMode && !(channelMask & 1u);
  return channelMask | (honorAlpha ? 1u : 0u);
}

static NSString *KKWrapGLSL(NSString *userSource, NSUInteger channelMask,
                                     NSInteger *outUserLineOffset,
                                     BOOL bufferMode) {
  // A shader's `// #color`-annotated `uniform vec4 <name>[N]?;` declarations move
  // INTO our std140 block (Vulkan-GLSL forbids non-opaque uniforms outside a
  // block). Parse them, strip the standalone declarations (leaving blank lines so
  // error line numbers stay aligned), and inject each as a block member - plus a
  // count-meta vec4 and a `<name>Count` define for arrays.
  ShaderColorProp props[KK_SHADER_MAX_COLOR_PROPS];
  int poolCount = 0;
  int nProps = ShaderParseColorProps(userSource, props,
                                     KK_SHADER_MAX_COLOR_PROPS, &poolCount);
  NSMutableString *colorMembers = [NSMutableString string];
  NSMutableString *colorDefines = [NSMutableString string];
  NSMutableString *body = [userSource mutableCopy];
  for (int i = 0; i < nProps; i++) {
    NSString *nm = @(props[i].name);
    if (props[i].isArray) {
      [colorMembers appendFormat:@"  vec4 %@[%d];\n  vec4 %@_kkmeta;\n", nm,
                                 props[i].count, nm];
      [colorDefines appendFormat:@"#define %@Count (int(%@_kkmeta.x))\n", nm,
                                 nm];
    } else {
      [colorMembers appendFormat:@"  vec4 %@;\n", nm];
    }
    NSString *pat = [NSString
        stringWithFormat:
            @"(?m)^[ \\t]*uniform\\s+vec4\\s+%@\\s*(\\[[^\\]]*\\])?\\s*;[ \\t]*$",
            nm];
    [[NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil]
        replaceMatchesInString:body
                       options:0
                         range:NSMakeRange(0, body.length)
                  withTemplate:@""];
  }

  // `// #float`/`// #choice` scalar props: each folds into ONE vec4 block member
  // (value in .x), appended after the colour members. Float -> `#define <name>
  // (<name>_kk.x)`; choice -> `(int(<name>_kk.x))`. Strip the standalone
  // `uniform float|int <name>;` (blank line keeps error lines aligned).
  ShaderScalarProp scalars[KK_SHADER_MAX_SCALAR_PROPS];
  int scalarUsed = 0;
  int nScalars = ShaderParseScalarProps(userSource, scalars,
                                        KK_SHADER_MAX_SCALAR_PROPS, poolCount,
                                        &scalarUsed);
  for (int i = 0; i < nScalars; i++) {
    NSString *nm = @(scalars[i].name);
    [colorMembers appendFormat:@"  vec4 %@_kk;\n", nm];
    if (scalars[i].isChoice || scalars[i].isInt) {
      [colorDefines appendFormat:@"#define %@ (int(%@_kk.x))\n", nm, nm];
    } else if (scalars[i].isBool) {
      [colorDefines appendFormat:@"#define %@ (%@_kk.x > 0.5)\n", nm, nm];
    } else if (ShaderScalarOSCIsRotate(&scalars[i])) {
      // A rotation OSC (`osc={..}`): each euler component is delivered as
      // radians(-deg), matching #angle's sign (a CW ring reads as a CW turn).
      // The lane stores components in canonical X<Y<Z order; the braced axis
      // order maps onto the shader vec via a swizzle (uRot.x = first-listed
      // axis). A single-axis rotate reduces to `radians(-uRot_kk.x)`.
      NSString *swizzle = ShaderRotateCanonicalSwizzle(&scalars[i]);
      [colorDefines appendFormat:@"#define %@ (radians(-%@_kk.%@))\n", nm, nm,
                                 swizzle];
    } else if (scalars[i].isAngle) {
      // Lane is degrees; the shader gets radians. Negated so a clockwise knob
      // turn reads as a clockwise on-screen rotation (the knob increases CW, but
      // a standard rotation matrix turns CCW for a positive angle in the shader's
      // y-up coordinate space).
      [colorDefines appendFormat:@"#define %@ (radians(-%@_kk.x))\n", nm, nm];
    } else if (scalars[i].isMulti) {
      // An N-component numeric field, delivered RAW (the shader owns the units):
      // vec2 -> `.xy`, vec3 -> `.xyz`. One pool vec4 member as usual.
      const char *uty = scalars[i].uniformType;
      NSString *swizzle = (strcmp(uty, "vec3") == 0)   ? @"xyz"
                          : (strcmp(uty, "vec4") == 0) ? @"xyzw"
                                                       : @"xy";
      [colorDefines appendFormat:@"#define %@ (%@_kk.%@)\n", nm, nm, swizzle];
    } else if (scalars[i].isPoint) {
      // Delivered in PIXELS (fragCoord space), not normalized: scale by
      // iResolution. No Y flip - the shader's fragCoord is bottom-origin
      // (Shadertoy convention), the SAME origin as the object-space lane, so the
      // point lines up directly. Per-pass iResolution keeps it correct in smaller
      // buffer passes.
      [colorDefines
          appendFormat:@"#define %@ (%@_kk.xy * iResolution.xy)\n", nm, nm];
    } else {
      [colorDefines appendFormat:@"#define %@ (%@_kk.x)\n", nm, nm];
    }
    // Strip the standalone declaration regardless of its declared GLSL type: the
    // `#define` above owns the real access, so an `#int` fed a `uniform float`
    // (or any type/name match) is still removed instead of surviving to collide
    // with the macro (a cryptic "unexpected LEFT_PAREN" from glslang).
    NSString *pat = [NSString
        stringWithFormat:@"(?m)^[ \\t]*uniform\\s+\\w+\\s+%@\\s*;[ \\t]*$", nm];
    [[NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil]
        replaceMatchesInString:body
                       options:0
                         range:NSMakeRange(0, body.length)
                  withTemplate:@""];
  }

  // `// #audio` props: a vec4 array in the block (4 bands packed per vec4 - a
  // std140 float array pads to a 16-byte stride and would cost 4x the pool).
  // The shader never sees that packing: `<name>Band(i)` unpacks it and
  // `<name>Bands` is the count. Appended AFTER the scalars so both earlier
  // pools keep their offsets.
  ShaderAudioProp audios[KK_SHADER_MAX_AUDIO_PROPS];
  int audioUsed = 0;
  int nAudio = ShaderParseAudioProps(userSource, audios,
                                     KK_SHADER_MAX_AUDIO_PROPS,
                                     poolCount + scalarUsed, &audioUsed);
  for (int i = 0; i < nAudio; i++) {
    NSString *nm = @(audios[i].name);
    [colorMembers appendFormat:@"  vec4 %@[%d];\n", nm, audios[i].vecCount];
    [colorDefines appendFormat:@"#define %@Bands %d\n", nm, audios[i].bands];
    [colorDefines appendFormat:@"#define %@Band(i) (%@[(i) >> 2][(i) & 3])\n",
                               nm, nm];
    NSString *pat = [NSString
        stringWithFormat:
            @"(?m)^[ \\t]*uniform\\s+vec4\\s+%@\\s*\\[[^\\]]*\\]\\s*;[ \\t]*$",
            nm];
    [[NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil]
        replaceMatchesInString:body
                       options:0
                         range:NSMakeRange(0, body.length)
                  withTemplate:@""];
  }

  NSMutableString *s = [NSMutableString string];
  [s appendString:@"layout(location = 0) out vec4 kk_outColor;\n"
                  @"layout(std140, binding = 0) uniform KKUniforms {\n"
                  @"  vec4 kkResTime;\n  vec4 iMouse;\n  vec4 iDate;\n"
                  @"  vec4 kkExtra;\n  vec4 kkGrain;\n  vec4 kkChanRes[4];\n"
                  @"  vec4 kkTransition;\n"];
  [s appendString:colorMembers]; // the shader's own colour uniforms
  [s appendString:@"};\n"
                  @"#define iResolution (kkResTime.xyz)\n"
                  @"#define iTime (kkResTime.w)\n"
                  @"#define iTimeDelta (kkExtra.x)\n"
                  @"#define iFrame (int(kkExtra.y))\n"
                  @"#define iChannelResolution kkChanRes\n"
                  // Not `progress`: that's a plausible local-variable name in an
                  // ordinary shader, and a #define would rewrite it.
                  @"#define iProgress (kkTransition.x)\n"];
  // GL-Transitions dialect. Scoped to shaders that actually declare
  [s appendString:colorDefines];
  // Alpha is honoured by DEFAULT for a shader that does NOT sample the source
  // itself: its transparent areas composite over iChannel0 (the footage) so a
  // generator-style shader never renders a black background. That needs
  // iChannel0 bound even when the shader never references it, so force channel 0
  // on. A shader that DOES sample iChannel0 manages the source itself (that use
  // wins), so it keeps the opaque image convention (a=1) - which also protects
  // golfed Shadertoy pastes that leave garbage in fragColor.a.
  BOOL honorAlpha = !bufferMode && !(channelMask & 1u);
  NSUInteger declMask = KKDeclaredChannelMask(channelMask, bufferMode);
  for (NSUInteger ch = 0; ch < 4; ch++) {
    if (declMask & (1u << ch))
      [s appendFormat:@"layout(binding = %lu) uniform sampler2D iChannel%lu;\n",
                      (unsigned long)(ch + 1), (unsigned long)ch];
  }
  // GL-Transitions dialect. Scoped to shaders that actually declare
  // `vec4 transition(vec2 ...)`, so `progress` stays a usable local name
  // everywhere else. Emitted AFTER the sampler declarations above - these
  // reference iChannel0/1, and GLSL wants them declared first.
  //
  // getFromColor/getToColor are real functions, not #defines: the catalogue
  // passes computed expressions (`getFromColor(safeUv(uv + s))`), which a macro
  // would mangle.
  if (KKLooksLikeGLTransition(userSource))
    [s appendString:@"#define progress iProgress\n"
                    @"#define ratio (iResolution.x / iResolution.y)\n"
                    @"vec4 getFromColor(vec2 uv){ return texture(iChannel0, "
                    @"uv); }\n"
                    @"vec4 getToColor(vec2 uv){ return texture(iChannel1, uv); "
                    @"}\n"];
  [s appendString:@"vec3 kkSrgbToLinear(vec3 c) {\n"
                  @"  c = clamp(c, 0.0, 1.0);\n"
                  @"  bvec3 lo = lessThanEqual(c, vec3(0.04045));\n"
                  @"  return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, "
                  @"vec3(lo));\n}\n"];
  // Core film-grain overlay, ported verbatim from ShaderCommon.h so Custom
  // grain matches the built-in Types. Applied in gamma space before encoding.
  [s appendString:
         @"float kkGrainHash(vec2 p){p=fract(p*vec2(123.34,456.21));"
         @"p+=dot(p,p+45.164);return fract(p.x*p.y);}\n"
         @"vec2 kkGrainRot(vec2 v,float a){float s=sin(a),c=cos(a);"
         @"return vec2(c*v.x+s*v.y,-s*v.x+c*v.y);}\n"
         @"float kkGrainNoise(vec2 st){vec2 i=floor(st),f=fract(st);"
         @"float a=kkGrainHash(i),b=kkGrainHash(i+vec2(1.,0.)),"
         @"c=kkGrainHash(i+vec2(0.,1.)),d=kkGrainHash(i+vec2(1.,1.));"
         @"vec2 u=f*f*(3.-2.*f);return mix(mix(a,b,u.x),mix(c,d,u.x),u.y);}\n"
         @"float kkGrainSample(vec2 g){float v=kkGrainNoise(kkGrainRot(g,1.)"
         @"+vec2(3.));v=mix(v,kkGrainNoise(kkGrainRot(g,2.)+vec2(-1.)),0.5);"
         @"v=pow(v,1.3);return v*2.-1.;}\n"
         @"vec3 kkApplyGrain(vec3 color,vec2 fc){float amt=max(kkGrain.x,0.0);"
         @"vec2 g=fc/max(kkGrain.y,0.25);float gv=kkGrainSample(g);"
         @"vec3 gc=vec3(step(0.0,gv));float st=pow(amt*abs(gv),0.8);"
         @"color=mix(color,gc,0.35*st);"
         @"float d=(kkGrainHash(fc)-kkGrainHash(fc.yx+7.0))/255.0;"
         @"return clamp(color+d,0.0,1.0);}\n"];
  // Strip any leading unsupported #version the user pasted (rare); our
  // forced version must be the effective one.
  [s appendString:@"\n"];
  // The user's source begins on the next line: a glslang error at wrapped line L
  // is the editor's line (L - <newlines so far>).
  if (outUserLineOffset) {
    NSInteger n = 0;
    for (NSUInteger i = 0; i < s.length; i++)
      if ([s characterAtIndex:i] == '\n')
        n++;
    *outUserLineOffset = n;
  }
  [s appendString:KKRenameReservedIdentifiers(body)];
  [s appendString:@"\nvoid main() {\n"
                  @"  vec2 fragCoord = gl_FragCoord.xy;\n"
                  @"  if (kkExtra.z != 0.0) fragCoord.y = kkResTime.y - "
                  @"fragCoord.y;\n"
                  @"  vec4 kkColor = vec4(0.0, 0.0, 0.0, 1.0);\n"
                  @"  mainImage(kkColor, fragCoord);\n"];
  if (bufferMode) {
    // A Buffer pass stores raw DATA a later pass samples (e.g. a distance /
    // position packed into RGBA). No grain, no sRGB, no clamp, no forced-opaque
    // - pass mainImage's output straight through.
    [s appendString:@"  kk_outColor = kkColor;\n}\n"];
  } else if (KKWantsAlphaOutput(userSource)) {
    // `// #alpha`: premultiplied passthrough of the shader's own alpha. No
    // composite over the source (the shader is masking that source), no forced
    // opaque. Grain + sRGB exactly as the other display paths.
    [s appendString:
           @"  vec3 disp = kkApplyGrain(clamp(kkColor.rgb, 0.0, 1.0), "
           @"gl_FragCoord.xy);\n"
           @"  vec3 rgb = (kkExtra.w == 0.0) ? kkSrgbToLinear(disp) : disp;\n"
           @"  float kka = clamp(kkColor.a, 0.0, 1.0);\n"
           @"  kk_outColor = vec4(rgb * kka, kka);\n}\n"];
  } else if (honorAlpha) {
    // Composite the shader over the source using its own alpha, so transparent
    // areas show the footage (iChannel0) rather than black - the shader is a
    // filter, and its source IS the background. Grain then sRGB, same as the
    // opaque path. Output is opaque (over the footage); where the source itself
    // is transparent its alpha carries through so lower layers still show.
    [s appendString:
           @"  vec3 disp = kkApplyGrain(clamp(kkColor.rgb, 0.0, 1.0), "
           @"gl_FragCoord.xy);\n"
           @"  float kka = clamp(kkColor.a, 0.0, 1.0);\n"
           @"  vec4 kkSrc = texture(iChannel0, fragCoord / iResolution.xy);\n"
           @"  vec3 comp = mix(kkSrc.rgb, disp, kka);\n"
           @"  vec3 rgb = (kkExtra.w == 0.0) ? kkSrgbToLinear(comp) : comp;\n"
           @"  float outA = max(kka, kkSrc.a);\n"
           @"  kk_outColor = vec4(rgb * outA, outA);\n}\n"];
  } else {
    // The image convention ignores fragColor.a (always opaque): golfed shaders
    // accumulate garbage into alpha, so forcing a=1 is safest. Grain in gamma/
    // display space (screen-fixed, raw gl_FragCoord) before the sRGB encode.
    [s appendString:
           @"  vec3 disp = kkApplyGrain(clamp(kkColor.rgb, 0.0, 1.0), "
           @"gl_FragCoord.xy);\n"
           @"  vec3 rgb = (kkExtra.w == 0.0) ? kkSrgbToLinear(disp) : disp;\n"
           @"  kk_outColor = vec4(rgb, 1.0);\n}\n"];
  }
  return s;
}

void KKBindGLSLUniforms(id<MTLRenderCommandEncoder> encoder,
                        const KKGLSLUniforms *u, const simd_float4 *pool,
                        int poolCount) {
  if (poolCount <= 0 || !pool) {
    [encoder setFragmentBytes:u length:sizeof(*u) atIndex:0];
    return;
  }
  size_t poolBytes = (size_t)poolCount * sizeof(simd_float4);
  size_t total = sizeof(*u) + poolBytes;
  void *buf = malloc(total);
  memcpy(buf, u, sizeof(*u));
  memcpy((char *)buf + sizeof(*u), pool, poolBytes);
  [encoder setFragmentBytes:buf length:total atIndex:0];
  free(buf);
}

// Full-screen vertex appended after the SPIRV-Cross fragment: emits the quad and
// a window-space [[position]] that feeds the fragment's gl_FragCoord.
static NSString *const kKKVertexMSL =
    @"\nstruct KKVsOut { float4 position [[position]]; };\n"
    @"vertex KKVsOut kkVertex(uint vid [[vertex_id]]) {\n"
    @"  float2 corners[4] = { float2(-1.0, -1.0), float2(-1.0, 1.0), "
    @"float2(1.0, -1.0), float2(1.0, 1.0) };\n"
    @"  KKVsOut o; o.position = float4(corners[vid], 0.0, 1.0); return o;\n}\n";

@implementation KKGLSLTranspileResult {
  NSInteger _texIdx[4];
  NSInteger _sampIdx[4];
}
- (instancetype)init {
  if ((self = [super init])) {
    for (int i = 0; i < 4; i++) {
      _texIdx[i] = NSNotFound;
      _sampIdx[i] = NSNotFound;
    }
    _fragmentName = @"main0";
    _vertexName = @"kkVertex";
  }
  return self;
}
- (BOOL)firstError:(NSString **)outMessage line:(NSInteger *)outLine {
  if (!self.errorLog.length)
    return NO;
  // glslang: "ERROR: 0:23: 'x' : undeclared identifier". The middle number is
  // the (wrapped) line; map it back to the editor via userLineOffset.
  static NSRegularExpression *re;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    re = [NSRegularExpression
        regularExpressionWithPattern:@"(?:ERROR|WARNING):\\s*\\d+:(\\d+):\\s*(.*)"
                             options:0
                               error:nil];
  });
  NSTextCheckingResult *m =
      [re firstMatchInString:self.errorLog
                     options:0
                       range:NSMakeRange(0, self.errorLog.length)];
  if (m) {
    NSInteger wrapped =
        [self.errorLog substringWithRange:[m rangeAtIndex:1]].integerValue;
    NSInteger editorLine = wrapped - self.userLineOffset;
    if (outLine)
      *outLine = editorLine > 0 ? editorLine : 0;
    if (outMessage) {
      NSString *raw = [[self.errorLog substringWithRange:[m rangeAtIndex:2]]
          stringByTrimmingCharactersInSet:NSCharacterSet
                                              .whitespaceAndNewlineCharacterSet];
      // glslang bodies read "'<token>' : <description>". Drop an empty token
      // (the noisy "'' :" case); fold a real token inline.
      static NSRegularExpression *tok;
      static dispatch_once_t tonce;
      dispatch_once(&tonce, ^{
        tok = [NSRegularExpression
            regularExpressionWithPattern:@"^'([^']*)'\\s*:\\s*(.*)$"
                                 options:0
                                   error:nil];
      });
      NSTextCheckingResult *tm =
          [tok firstMatchInString:raw options:0 range:NSMakeRange(0, raw.length)];
      if (tm) {
        NSString *token = [raw substringWithRange:[tm rangeAtIndex:1]];
        NSString *desc = [raw substringWithRange:[tm rangeAtIndex:2]];
        raw = token.length
                  ? [NSString stringWithFormat:@"%@: %@", token, desc]
                  : desc;
      }
      // A raw-GL paste whose entry point we shimmed, but that still trips
      // "undeclared identifier", almost always names a uniform the shim doesn't
      // know. Point the user at the fix instead of a bare compiler error.
      if (self.shimmedFromRawGL &&
          [raw rangeOfString:@"undeclared identifier"].location != NSNotFound)
        raw = [raw stringByAppendingString:
                       @" - looks like a uniform from another shader host; "
                       @"rename it to iChannel0 / iResolution / iTime"];
      *outMessage = raw;
    }
    return YES;
  }
  // No parseable line: surface the first non-empty log line.
  if (outLine)
    *outLine = 0;
  if (outMessage) {
    for (NSString *ln in [self.errorLog componentsSeparatedByString:@"\n"]) {
      NSString *t = [ln stringByTrimmingCharactersInSet:
                            NSCharacterSet.whitespaceAndNewlineCharacterSet];
      if (t.length) {
        *outMessage = t;
        break;
      }
    }
  }
  return YES;
}

- (NSInteger)textureIndexForChannel:(NSUInteger)ch {
  return ch < 4 ? _texIdx[ch] : NSNotFound;
}
- (NSInteger)samplerIndexForChannel:(NSUInteger)ch {
  return ch < 4 ? _sampIdx[ch] : NSNotFound;
}
- (void)setTexture:(NSInteger)t sampler:(NSInteger)sm forChannel:(NSUInteger)ch {
  if (ch < 4) {
    _texIdx[ch] = t;
    _sampIdx[ch] = sm;
  }
}
@end

id<MTLTexture> KKCustomChannelNoiseTexture(id<MTLDevice> device) {
  static NSMapTable<id<MTLDevice>, id<MTLTexture>> *cache;
  static NSLock *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cache = [NSMapTable strongToStrongObjectsMapTable];
    lock = [NSLock new];
  });
  [lock lock];
  id<MTLTexture> tex = [cache objectForKey:device];
  [lock unlock];
  if (tex)
    return tex;
  const NSUInteger N = 256;
  MTLTextureDescriptor *d = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA8Unorm
                                   width:N
                                  height:N
                               mipmapped:NO];
  d.usage = MTLTextureUsageShaderRead;
  tex = [device newTextureWithDescriptor:d];
  uint8_t *bytes = (uint8_t *)malloc(N * N * 4);
  arc4random_buf(bytes, N * N * 4);
  [tex replaceRegion:MTLRegionMake2D(0, 0, N, N)
         mipmapLevel:0
           withBytes:bytes
         bytesPerRow:N * 4];
  free(bytes);
  [lock lock];
  [cache setObject:tex forKey:device];
  [lock unlock];
  return tex;
}

id<MTLSamplerState> KKCustomChannelSampler(id<MTLDevice> device) {
  static NSMapTable<id<MTLDevice>, id<MTLSamplerState>> *cache;
  static NSLock *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cache = [NSMapTable strongToStrongObjectsMapTable];
    lock = [NSLock new];
  });
  [lock lock];
  id<MTLSamplerState> s = [cache objectForKey:device];
  [lock unlock];
  if (s)
    return s;
  MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
  sd.minFilter = MTLSamplerMinMagFilterLinear;
  sd.magFilter = MTLSamplerMinMagFilterLinear;
  sd.sAddressMode = MTLSamplerAddressModeRepeat;
  sd.tAddressMode = MTLSamplerAddressModeRepeat;
  s = [device newSamplerStateWithDescriptor:sd];
  [lock lock];
  [cache setObject:s forKey:device];
  [lock unlock];
  return s;
}

id<MTLSamplerState> KKCustomSourceSampler(id<MTLDevice> device) {
  static NSMapTable<id<MTLDevice>, id<MTLSamplerState>> *cache;
  static NSLock *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cache = [NSMapTable strongToStrongObjectsMapTable];
    lock = [NSLock new];
  });
  [lock lock];
  id<MTLSamplerState> s = [cache objectForKey:device];
  [lock unlock];
  if (s)
    return s;
  MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
  sd.minFilter = MTLSamplerMinMagFilterLinear;
  sd.magFilter = MTLSamplerMinMagFilterLinear;
  sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
  sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
  s = [device newSamplerStateWithDescriptor:sd];
  [lock lock];
  [cache setObject:s forKey:device];
  [lock unlock];
  return s;
}

// Cached render pipeline (fullscreen quad, vertex + fragment) that samples a
// linear source and writes its sRGB/gamma encode. Sampling (not compute .read)
// matches exactly how the shader reads the source, so any texture the shader can
// sample this pass can sample too. Built once per device.
static id<MTLRenderPipelineState> KKGammaEncodePipeline(id<MTLDevice> device) {
  static NSMapTable<id<MTLDevice>, id<MTLRenderPipelineState>> *cache;
  static NSLock *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cache = [NSMapTable strongToStrongObjectsMapTable];
    lock = [NSLock new];
  });
  [lock lock];
  id<MTLRenderPipelineState> ps = [cache objectForKey:device];
  [lock unlock];
  if (ps)
    return ps;
  NSString *src =
      @"#include <metal_stdlib>\n"
      @"using namespace metal;\n"
      @"struct KKGEOut { float4 pos [[position]]; float2 uv; };\n"
      @"vertex KKGEOut kkGammaVS(uint vid [[vertex_id]]) {\n"
      @"  float2 c[4] = { float2(-1,-1), float2(-1,1), float2(1,-1), "
      @"float2(1,1) };\n"
      @"  float2 p = c[vid];\n"
      @"  KKGEOut o;\n"
      @"  o.pos = float4(p, 0.0, 1.0);\n"
      @"  o.uv = float2(p.x * 0.5 + 0.5, 0.5 - p.y * 0.5);\n"
      @"  return o;\n"
      @"}\n"
      @"static inline float3 kk_lin2srgb(float3 c) {\n"
      @"  c = clamp(c, 0.0, 1.0);\n"
      @"  float3 lo = c * 12.92;\n"
      @"  float3 hi = 1.055 * pow(c, 1.0 / 2.4) - 0.055;\n"
      @"  return select(hi, lo, c <= 0.0031308);\n"
      @"}\n"
      @"fragment float4 kkGammaFS(KKGEOut in [[stage_in]],\n"
      @"                          texture2d<float> tex [[texture(0)]],\n"
      @"                          sampler smp [[sampler(0)]]) {\n"
      @"  float4 c = tex.sample(smp, in.uv);\n"
      @"  return float4(kk_lin2srgb(c.rgb), c.a);\n"
      @"}\n";
  NSError *err = nil;
  id<MTLLibrary> lib = [device newLibraryWithSource:src options:nil error:&err];
  id<MTLFunction> vfn = [lib newFunctionWithName:@"kkGammaVS"];
  id<MTLFunction> ffn = [lib newFunctionWithName:@"kkGammaFS"];
  if (!vfn || !ffn) {
    KKLogError(@"[Custom] gamma-encode shader build failed: %@", err);
    return nil;
  }
  MTLRenderPipelineDescriptor *desc = [MTLRenderPipelineDescriptor new];
  desc.vertexFunction = vfn;
  desc.fragmentFunction = ffn;
  desc.colorAttachments[0].pixelFormat = MTLPixelFormatRGBA16Float;
  ps = [device newRenderPipelineStateWithDescriptor:desc error:&err];
  if (!ps) {
    KKLogError(@"[Custom] gamma-encode pipeline build failed: %@", err);
    return nil;
  }
  [lock lock];
  [cache setObject:ps forKey:device];
  [lock unlock];
  return ps;
}

static id<MTLSamplerState> KKGammaEncodeSampler(id<MTLDevice> device) {
  static NSMapTable<id<MTLDevice>, id<MTLSamplerState>> *cache;
  static NSLock *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cache = [NSMapTable strongToStrongObjectsMapTable];
    lock = [NSLock new];
  });
  [lock lock];
  id<MTLSamplerState> s = [cache objectForKey:device];
  [lock unlock];
  if (s)
    return s;
  MTLSamplerDescriptor *sd = [MTLSamplerDescriptor new];
  sd.minFilter = MTLSamplerMinMagFilterNearest;
  sd.magFilter = MTLSamplerMinMagFilterNearest;
  sd.sAddressMode = MTLSamplerAddressModeClampToEdge;
  sd.tAddressMode = MTLSamplerAddressModeClampToEdge;
  s = [device newSamplerStateWithDescriptor:sd];
  [lock lock];
  [cache setObject:s forKey:device];
  [lock unlock];
  return s;
}

id<MTLTexture> KKGammaEncodeSourceTextureOnBuffer(
    id<MTLCommandBuffer> commandBuffer, id<MTLTexture> src) {
  if (!commandBuffer || !src)
    return src;
  id<MTLDevice> device = commandBuffer.device;
  id<MTLRenderPipelineState> ps = KKGammaEncodePipeline(device);
  if (!ps)
    return src;
  MTLTextureDescriptor *td = [MTLTextureDescriptor
      texture2DDescriptorWithPixelFormat:MTLPixelFormatRGBA16Float
                                   width:src.width
                                  height:src.height
                               mipmapped:NO];
  td.usage = MTLTextureUsageRenderTarget | MTLTextureUsageShaderRead;
  td.storageMode = MTLStorageModePrivate;
  id<MTLTexture> dst = [device newTextureWithDescriptor:td];
  if (!dst)
    return src;
  MTLRenderPassDescriptor *rpd = [MTLRenderPassDescriptor renderPassDescriptor];
  rpd.colorAttachments[0].texture = dst;
  rpd.colorAttachments[0].loadAction = MTLLoadActionDontCare;
  rpd.colorAttachments[0].storeAction = MTLStoreActionStore;
  id<MTLRenderCommandEncoder> e =
      [commandBuffer renderCommandEncoderWithDescriptor:rpd];
  [e setViewport:(MTLViewport){0, 0, (double)src.width, (double)src.height, -1.0,
                               1.0}];
  [e setRenderPipelineState:ps];
  [e setFragmentTexture:src atIndex:0];
  [e setFragmentSamplerState:KKGammaEncodeSampler(device) atIndex:0];
  [e drawPrimitives:MTLPrimitiveTypeTriangleStrip vertexStart:0 vertexCount:4];
  [e endEncoding];
  return dst;
}

id<MTLTexture> KKGammaEncodeSourceTexture(id<MTLCommandQueue> queue,
                                          id<MTLTexture> src) {
  if (!queue || !src)
    return src;
  id<MTLCommandBuffer> cb = [queue commandBuffer];
  id<MTLTexture> dst = KKGammaEncodeSourceTextureOnBuffer(cb, src);
  if (dst == src)
    return src;
  [cb commit];
  [cb waitUntilCompleted];
  return dst;
}

void KKBindCustomChannels(id<MTLRenderCommandEncoder> encoder,
                          KKGLSLTranspileResult *tr, id<MTLTexture> source,
                          id<MTLSamplerState> sourceSampler,
                          id<MTLTexture> noise, id<MTLSamplerState> sampler) {
  for (NSUInteger ch = 0; ch < 4; ch++) {
    NSInteger ti = [tr textureIndexForChannel:ch];
    if (ti == NSNotFound)
      continue;
    BOOL useSource = (ch == 0 && source != nil);
    [encoder setFragmentTexture:(useSource ? source : noise)
                        atIndex:(NSUInteger)ti];
    NSInteger si = [tr samplerIndexForChannel:ch];
    if (si != NSNotFound) {
      id<MTLSamplerState> smp =
          (useSource && sourceSampler) ? sourceSampler : sampler;
      [encoder setFragmentSamplerState:smp atIndex:(NSUInteger)si];
    }
  }
}

void KKBindCustomChannelTextures(id<MTLRenderCommandEncoder> encoder,
                                 KKGLSLTranspileResult *tr, NSArray *chTex,
                                 id<MTLSamplerState> sampler,
                                 id<MTLTexture> noise,
                                 id<MTLSamplerState> noiseSampler) {
  for (NSUInteger ch = 0; ch < 4; ch++) {
    NSInteger ti = [tr textureIndexForChannel:ch];
    if (ti == NSNotFound)
      continue;
    id t = (ch < chTex.count) ? chTex[ch] : (id)[NSNull null];
    BOOL real = (t != [NSNull null]);
    [encoder setFragmentTexture:(real ? (id<MTLTexture>)t : noise)
                        atIndex:(NSUInteger)ti];
    NSInteger si = [tr samplerIndexForChannel:ch];
    if (si != NSNotFound)
      [encoder setFragmentSamplerState:(real ? sampler : noiseSampler)
                               atIndex:(NSUInteger)si];
  }
}

// SPIRV-Cross's force-zero-init misses some loop-hoisted variables - a C-style
// `for (O *= i; i < n; i++)` leaves the counter as a bare `float i;`, the exact
// uninitialised-read UB that WebGL/ANGLE zero-inits. Backstop it: give
// every bare local declaration inside a function body a `= {}` initialiser.
// Struct members look identical, so skip them by tracking brace scope (SPIRV-
// Cross emits all structs before any function and puts braces on their own
// lines). Matrices are excluded from the pattern (their zero-init is handled and
// `{}` on a matrix is dicey).
static NSString *KKZeroInitLocals(NSString *msl) {
  static NSRegularExpression *decl;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    decl = [NSRegularExpression
        regularExpressionWithPattern:@"^(\\s+)(bool|u?char|u?short|u?int|float|"
                                     @"half)([234])?\\s+(\\w+);\\s*$"
                             options:0
                               error:nil];
  });
  NSArray<NSString *> *lines = [msl componentsSeparatedByString:@"\n"];
  NSMutableArray<NSString *> *out =
      [NSMutableArray arrayWithCapacity:lines.count];
  NSMutableArray<NSNumber *> *structStack = [NSMutableArray array];
  BOOL pendingStruct = NO;
  for (NSString *line in lines) {
    NSString *trimmed = [line
        stringByTrimmingCharactersInSet:[NSCharacterSet
                                            whitespaceCharacterSet]];
    if ([trimmed hasPrefix:@"struct"])
      pendingStruct = YES;
    BOOL inStruct = structStack.count && structStack.lastObject.boolValue;
    NSString *emit = line;
    if (structStack.count && !inStruct) {
      NSRange r = NSMakeRange(0, line.length);
      if ([decl firstMatchInString:line options:0 range:r])
        emit = [decl stringByReplacingMatchesInString:line
                                              options:0
                                                range:r
                                         withTemplate:@"$1$2$3 $4 = {};"];
    }
    [out addObject:emit];
    for (NSUInteger k = 0; k < trimmed.length; k++) {
      unichar c = [trimmed characterAtIndex:k];
      if (c == '{') {
        [structStack addObject:@(pendingStruct)];
        pendingStruct = NO;
      } else if (c == '}' && structStack.count) {
        [structStack removeLastObject];
      }
    }
  }
  return [out componentsJoinedByString:@"\n"];
}

static NSUInteger KKChannelMask(NSString *src) {
  NSUInteger mask = 0;
  for (NSUInteger ch = 0; ch < 4; ch++) {
    NSString *tok = [NSString stringWithFormat:@"iChannel%lu", (unsigned long)ch];
    if ([src rangeOfString:tok].location != NSNotFound)
      mask |= (1u << ch);
  }
  return mask;
}

static KKGLSLTranspileResult *KKTranspileUncached(NSString *userGLSL,
                                                  BOOL bufferMode);

// Memoise by source hash: the MSL, entry names and channel bindings are
// device-independent, so both the main render and the mini-viewer share one
// cache and a given shader is transpiled once.
static KKGLSLTranspileResult *KKTranspileMemoized(NSString *userGLSL,
                                                  BOOL bufferMode) {
  static NSMutableDictionary<NSNumber *, KKGLSLTranspileResult *> *cache;
  static NSLock *cacheLock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    cache = [NSMutableDictionary dictionary];
    cacheLock = [NSLock new];
  });
  NSNumber *key = @(userGLSL.hash * 2u + (bufferMode ? 1u : 0u));
  [cacheLock lock];
  KKGLSLTranspileResult *hit = cache[key];
  [cacheLock unlock];
  if (hit)
    return hit;
  KKGLSLTranspileResult *r = KKTranspileUncached(userGLSL, bufferMode);
  [cacheLock lock];
  cache[key] = r;
  [cacheLock unlock];
  return r;
}

KKGLSLTranspileResult *KKTranspileGLSL(NSString *userGLSL) {
  return KKTranspileMemoized(userGLSL, NO);
}

KKGLSLTranspileResult *KKTranspileGLSLBuffer(NSString *userGLSL) {
  return KKTranspileMemoized(userGLSL, YES);
}

static KKGLSLTranspileResult *KKTranspileUncached(NSString *userGLSL,
                                                  BOOL bufferMode) {
  static NSLock *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    glslang_initialize_process();
    lock = [NSLock new];
  });

  KKGLSLTranspileResult *result = [KKGLSLTranspileResult new];
  BOOL hadMainImage = [userGLSL rangeOfString:@"mainImage"].location != NSNotFound;
  // Before the raw-GL shim: this one SUPPLIES mainImage, which is exactly the
  // condition KKShimRawGLSL bails on, so it then correctly leaves us alone.
  BOOL glTransition = KKLooksLikeGLTransition(userGLSL);
  userGLSL = KKShimGLTransition(userGLSL); // gl-transitions -> image-shader
  userGLSL = KKShimRawGLSL(userGLSL);      // raw-GL -> image-shader convention
  result.shimmedFromRawGL =
      !hadMainImage && !glTransition &&
      [userGLSL rangeOfString:@"mainImage"].location != NSNotFound;
  NSUInteger channelMask = KKChannelMask(userGLSL);
  // A GL transition names its sources getFromColor/getToColor and never writes
  // `iChannel` anywhere, so the scan returns 0 and BOTH clips would go unbound.
  // Force the two it always samples.
  if (glTransition)
    channelMask |= 0x3u;
  result.declaredChannelMask = KKDeclaredChannelMask(channelMask, bufferMode);
  NSInteger lineOffset = 0;
  NSString *glsl =
      KKWrapGLSL(userGLSL, channelMask, &lineOffset, bufferMode);
  result.userLineOffset = lineOffset;
  std::string glslStr = glsl.UTF8String;

  [lock lock];

  glslang_input_t input = {};
  input.language = GLSLANG_SOURCE_GLSL;
  input.stage = GLSLANG_STAGE_FRAGMENT;
  input.client = GLSLANG_CLIENT_VULKAN;
  input.client_version = GLSLANG_TARGET_VULKAN_1_0;
  input.target_language = GLSLANG_TARGET_SPV;
  input.target_language_version = GLSLANG_TARGET_SPV_1_0;
  input.code = glslStr.c_str();
  input.default_version = 450;
  input.default_profile = GLSLANG_CORE_PROFILE;
  input.force_default_version_and_profile = 1;
  input.forward_compatible = 0;
  input.messages =
      (glslang_messages_t)(GLSLANG_MSG_SPV_RULES_BIT | GLSLANG_MSG_VULKAN_RULES_BIT);
  input.resource = glslang_default_resource();

  glslang_shader_t *shader = glslang_shader_create(&input);
  if (!glslang_shader_preprocess(shader, &input) ||
      !glslang_shader_parse(shader, &input)) {
    result.errorLog = [NSString stringWithFormat:@"%s\n%s",
                                                 glslang_shader_get_info_log(shader),
                                                 glslang_shader_get_info_debug_log(shader)];
    glslang_shader_delete(shader);
    [lock unlock];
    return result;
  }
  glslang_program_t *program = glslang_program_create();
  glslang_program_add_shader(program, shader);
  if (!glslang_program_link(program, GLSLANG_MSG_SPV_RULES_BIT |
                                         GLSLANG_MSG_VULKAN_RULES_BIT)) {
    result.errorLog = @(glslang_program_get_info_log(program));
    glslang_program_delete(program);
    glslang_shader_delete(shader);
    [lock unlock];
    return result;
  }
  glslang_program_SPIRV_generate(program, GLSLANG_STAGE_FRAGMENT);
  size_t words = glslang_program_SPIRV_get_size(program);
  std::vector<unsigned int> spirv(words);
  glslang_program_SPIRV_get(program, spirv.data());
  glslang_program_delete(program);
  glslang_shader_delete(shader);

  spvc_context ctx = nullptr;
  spvc_context_create(&ctx);
  spvc_parsed_ir ir = nullptr;
  if (spvc_context_parse_spirv(ctx, spirv.data(), words, &ir) != SPVC_SUCCESS) {
    result.errorLog = @(spvc_context_get_last_error_string(ctx));
    spvc_context_destroy(ctx);
    [lock unlock];
    return result;
  }
  spvc_compiler compiler = nullptr;
  spvc_context_create_compiler(ctx, SPVC_BACKEND_MSL, ir,
                               SPVC_CAPTURE_MODE_TAKE_OWNERSHIP, &compiler);
  spvc_compiler_options options = nullptr;
  spvc_compiler_create_compiler_options(compiler, &options);
  spvc_compiler_options_set_uint(options, SPVC_COMPILER_OPTION_MSL_VERSION, 20300);
  spvc_compiler_options_set_uint(options, SPVC_COMPILER_OPTION_MSL_PLATFORM, 1);
  // Zero-initialise all locals, matching Chrome/ANGLE (WebGL).
  // A lot of golfed shaders rely on `float i;` starting at 0 (`for(O*=i; i<n;
  // i++)`); without this those read garbage and render differently per compile.
  spvc_compiler_options_set_uint(
      options, SPVC_COMPILER_OPTION_FORCE_ZERO_INITIALIZED_VARIABLES, 1);
  spvc_compiler_install_compiler_options(compiler, options);

  const char *msl = nullptr;
  if (spvc_compiler_compile(compiler, &msl) != SPVC_SUCCESS || !msl) {
    result.errorLog = @(spvc_context_get_last_error_string(ctx));
    spvc_context_destroy(ctx);
    [lock unlock];
    return result;
  }

  // Reflect the fragment entry name and each channel's MSL texture/sampler index.
  const char *cleansed = spvc_compiler_get_cleansed_entry_point_name(
      compiler, "main", SpvExecutionModelFragment);
  if (cleansed)
    result.fragmentName = @(cleansed);

  spvc_resources resources = nullptr;
  if (spvc_compiler_create_shader_resources(compiler, &resources) == SPVC_SUCCESS) {
    const spvc_reflected_resource *list = nullptr;
    size_t count = 0;
    spvc_resources_get_resource_list_for_type(
        resources, SPVC_RESOURCE_TYPE_SAMPLED_IMAGE, &list, &count);
    for (size_t i = 0; i < count; i++) {
      NSString *name = @(list[i].name);
      for (NSUInteger ch = 0; ch < 4; ch++) {
        if ([name isEqualToString:[NSString stringWithFormat:@"iChannel%lu",
                                                             (unsigned long)ch]]) {
          unsigned t = spvc_compiler_msl_get_automatic_resource_binding(
              compiler, list[i].id);
          unsigned sm = spvc_compiler_msl_get_automatic_resource_binding_secondary(
              compiler, list[i].id);
          [result setTexture:(NSInteger)t sampler:(NSInteger)sm forChannel:ch];
          break;
        }
      }
    }
  }

  result.msl =
      [KKZeroInitLocals(@(msl)) stringByAppendingString:kKKVertexMSL];
  spvc_context_destroy(ctx);
  [lock unlock];
  return result;
}
