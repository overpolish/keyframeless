/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKGLSLTranspiler_Internal.h"
#import "MirageDirectives.h" // MirageParseColorProps (`// #color` block injection)
#import "MirageFrameOffsets.h" // `// #frames` neighbour-frame samplers

// GLSL body -> full core-450 GLSL. No #version (forced via the API): the
// uniform block is all-vec4 so std140 maps 1:1 to KKGLSLUniforms; iResolution /
// iTime / iTimeDelta / iFrame are aliased onto its lanes. flipY, sRGB-encode
// and premultiply live in main() driven by kkExtra so they stay runtime
// choices.

NSUInteger KKDeclaredChannelMask(NSUInteger channelMask, KKGLSLPassKind pass) {
  BOOL honorAlpha = pass == KKGLSLPassImage && !(channelMask & 1u);
  return channelMask | (honorAlpha ? 1u : 0u);
}

// The tail every directive-uniform strip ends with. A declaration routinely
// carries a trailing comment - authors annotate them constantly ("// 64 bands,
// low frequency first") - and anchoring the strip right after the semicolon
// left those declarations in the body, where glslang rejects them with
// "non-opaque uniforms outside a block: not allowed when using GLSL for
// Vulkan". Allows trailing space, a single-line block comment, and a line
// comment, in that order.
static NSString *const kKKUniformStripTail =
    @"[ \\t]*(?:/\\*[^\\n]*?\\*/[ \\t]*)?(?://[^\\n]*)?$";

// A shader's `// #color`-annotated `uniform vec4 <name>[N]?;` declarations move
// INTO our std140 block (Vulkan-GLSL forbids non-opaque uniforms outside a
// block). Parse them, strip the standalone declarations from `body` (leaving
// blank lines so error line numbers stay aligned), and emit each as a block
// member - plus a count-meta vec4 and a `<name>Count` define for arrays.
// Returns the pool vec4s consumed, which the scalar/audio pools index after.
static int KKEmitColorProps(NSString *userSource, NSMutableString *body,
                            NSMutableString *members,
                            NSMutableString *defines) {
  MirageShaderModel *model = [MirageShaderModel modelForSource:userSource];
  const MirageColorProp *props = model.colorProps;
  int poolCount = model.colorPoolUsed;
  for (int i = 0; i < model.colorCount; i++) {
    NSString *nm = @(props[i].name);
    if (props[i].isArray) {
      [members appendFormat:@"  vec4 %@[%d];\n  vec4 %@_kkmeta;\n", nm,
                            props[i].count, nm];
      [defines appendFormat:@"#define %@Count (int(%@_kkmeta.x))\n", nm, nm];
    } else {
      [members appendFormat:@"  vec4 %@;\n", nm];
    }
    NSString *pat = [NSString
        stringWithFormat:
            @"(?m)^[ \\t]*uniform\\s+vec4\\s+%@\\s*(\\[[^\\]]*\\])?\\s*;%@", nm,
            kKKUniformStripTail];
    [[NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil]
        replaceMatchesInString:body
                       options:0
                         range:NSMakeRange(0, body.length)
                  withTemplate:@""];
  }
  return poolCount;
}

// The `#define <name> ...` that gives one scalar prop its shader-facing type
// and units, unpacking the pool vec4 it folded into.
// Emits the rotate-OSC define: each euler component is delivered as
// radians(-deg), matching #angle's sign (a CW ring reads as a CW turn). The
// lane stores components in canonical X<Y<Z order; the braced axis order maps
// onto the shader vec via a swizzle (uRot.x = first-listed axis). A
// single-axis rotate reduces to `radians(-uRot_kk.x)`.
static void KKEmitRotateDefine(const MirageOSCBlock *blk, NSString *nm,
                               NSString *acc, NSMutableString *defines) {
  [defines appendFormat:@"#define %@ (radians(-%@.%@))\n", nm, acc,
                        MirageOSCBlockRotateSwizzle(blk)];
}

// `nm` is the identifier the define creates and `acc` the block member it
// unpacks.
static void KKEmitScalarDefine(const MirageScalarProp *p,
                               const MirageOSCBlock *blk, NSString *nm,
                               NSString *acc, NSMutableString *defines) {
  // The rotate-OSC form is per-kind below (never for int/choice/bool, which
  // historically outrank it) rather than one early check, so the kind switch
  // stays exhaustive for -Wswitch.
  BOOL rotate = MirageOSCBlockIsRotate(blk);
  switch (p->kind) {
  case MirageScalarKindInt:
  case MirageScalarKindChoice:
    // Scalar int/choice only; a `#multi int` is still a vector (its
    // integer-ness is just field stepping) and lands in the Multi case.
    [defines appendFormat:@"#define %@ (int(%@.x))\n", nm, acc];
    break;
  case MirageScalarKindBool:
    [defines appendFormat:@"#define %@ (%@.x > 0.5)\n", nm, acc];
    break;
  case MirageScalarKindAngle:
    if (rotate) {
      KKEmitRotateDefine(blk, nm, acc, defines);
      break;
    }
    // Lane is degrees; the shader gets radians. Negated so a clockwise knob
    // turn reads as a clockwise on-screen rotation (the knob increases CW, but
    // a standard rotation matrix turns CCW for a positive angle in the
    // shader's y-up coordinate space).
    [defines appendFormat:@"#define %@ (radians(-%@.x))\n", nm, acc];
    break;
  case MirageScalarKindMulti: {
    if (rotate) {
      KKEmitRotateDefine(blk, nm, acc, defines);
      break;
    }
    // An N-component numeric field, delivered RAW (the shader owns the units):
    // vec2 -> `.xy`, vec3 -> `.xyz`. One pool vec4 member as usual.
    const char *uty = p->uniformType;
    NSString *swizzle = (strcmp(uty, "vec3") == 0)   ? @"xyz"
                        : (strcmp(uty, "vec4") == 0) ? @"xyzw"
                                                     : @"xy";
    [defines appendFormat:@"#define %@ (%@.%@)\n", nm, acc, swizzle];
    break;
  }
  case MirageScalarKindPoint:
    if (rotate) {
      KKEmitRotateDefine(blk, nm, acc, defines);
      break;
    }
    // Delivered in PIXELS (fragCoord space), not normalized: scale by
    // iResolution. No Y flip - the shader's fragCoord is bottom-origin
    // (Shadertoy convention), the SAME origin as the object-space lane, so the
    // point lines up directly. Per-pass iResolution keeps it correct in
    // smaller buffer passes.
    [defines appendFormat:@"#define %@ (%@.xy * iResolution.xy)\n", nm, acc];
    break;
  case MirageScalarKindFloat:
  case MirageScalarKindPercent:
  case MirageScalarKindProgress:
  case MirageScalarKindRandom:
    if (rotate) {
      KKEmitRotateDefine(blk, nm, acc, defines);
      break;
    }
    [defines appendFormat:@"#define %@ (%@.x)\n", nm, acc];
    break;
  }
}

// `// #float`/`// #choice` scalar props: each folds into ONE vec4 block member
// (value in .x), appended after the colour members. Returns the pool vec4s
// used.
static int KKEmitScalarProps(NSString *userSource, NSMutableString *body,
                             NSMutableString *members,
                             NSMutableString *defines) {
  MirageShaderModel *model = [MirageShaderModel modelForSource:userSource];
  const MirageScalarProp *scalars = model.scalarProps;
  int scalarUsed = model.scalarPoolUsed;
  for (int i = 0; i < model.scalarCount; i++) {
    NSString *nm = @(scalars[i].name);
    [members appendFormat:@"  vec4 %@_kk;\n", nm];
    KKEmitScalarDefine(&scalars[i], [model oscBlockForUniform:scalars[i].name],
                       nm, [nm stringByAppendingString:@"_kk"], defines);
    // Strip the standalone declaration regardless of its declared GLSL type:
    // the
    // `#define` above owns the real access, so an `#int` fed a `uniform float`
    // (or any type/name match) is still removed instead of surviving to collide
    // with the macro (a cryptic "unexpected LEFT_PAREN" from glslang).
    NSString *pat =
        [NSString stringWithFormat:@"(?m)^[ \\t]*uniform\\s+\\w+\\s+%@\\s*;%@",
                                   nm, kKKUniformStripTail];
    [[NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil]
        replaceMatchesInString:body
                       options:0
                         range:NSMakeRange(0, body.length)
                  withTemplate:@""];
  }
  return scalarUsed;
}

// `// #audio` props: a vec4 array in the block (4 bands packed per vec4 - a
// std140 float array pads to a 16-byte stride and would cost 4x the pool).
// The shader never sees that packing: `<name>Band(i)` unpacks it and
// `<name>Bands` is the count. Appended AFTER the scalars so both earlier
// pools keep their offsets.
static void KKEmitAudioProps(NSString *userSource, NSMutableString *body,
                             NSMutableString *members,
                             NSMutableString *defines) {
  MirageShaderModel *model = [MirageShaderModel modelForSource:userSource];
  const MirageAudioProp *audios = model.audioProps;
  for (int i = 0; i < model.audioCount; i++) {
    NSString *nm = @(audios[i].name);
    [members appendFormat:@"  vec4 %@[%d];\n", nm, audios[i].vecCount];
    [defines appendFormat:@"#define %@Bands %d\n", nm, audios[i].bands];
    [defines
        appendFormat:@"#define %@Band(i) (%@[(i) >> 2][(i) & 3])\n", nm, nm];
    // `flow`: a cumulative energy clock alongside the bars. Its member comes
    // right after the band array so the std140 layout still matches the pool's
    // per-prop offsets (bands, then this scalar). `.x` holds the value.
    if (audios[i].wantsFlow) {
      NSString *fm = [nm stringByAppendingString:@"_flow"];
      [members appendFormat:@"  vec4 %@;\n", fm];
      [defines appendFormat:@"#define %@Flow (%@.x)\n", nm, fm];
    }
    // `waveform=N`: a centred time-domain window, packed just like the
    // spectrum but signed. The helper hides the storage and keeps N available
    // as a compile-time constant for bounded GLSL loops.
    if (audios[i].wantsWaveform) {
      NSString *wm = [nm stringByAppendingString:@"_wave"];
      [members
          appendFormat:@"  vec4 %@[%d];\n", wm, audios[i].waveformVecCount];
      [defines appendFormat:@"#define %@WaveSamples %d\n", nm,
                            audios[i].waveformSamples];
      [defines
          appendFormat:@"#define %@Wave(i) (%@[(i) >> 2][(i) & 3])\n", nm, wm];
    }
    NSString *pat = [NSString
        stringWithFormat:
            @"(?m)^[ \\t]*uniform\\s+vec4\\s+%@\\s*\\[[^\\]]*\\]\\s*;%@", nm,
            kKKUniformStripTail];
    [[NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil]
        replaceMatchesInString:body
                       options:0
                         range:NSMakeRange(0, body.length)
                  withTemplate:@""];
  }
}

// `// #gradient` props: a stop array (rgb in .xyz, position in .w), the
// midpoints packed 4 per vec4, and a count meta. The shader never sees that
// packing - `<name>At(t)` samples the ramp and `<name>Stops` is the live stop
// count. Appended AFTER the audio bands so all three earlier pools keep their
// offsets. The sampler functions go in `fns` rather than `defines` because they
// call kkGradBias, which is emitted with the colour helpers further down.
static void KKEmitGradientProps(NSString *userSource, NSMutableString *body,
                                NSMutableString *members,
                                NSMutableString *defines,
                                NSMutableString *fns) {
  MirageShaderModel *model = [MirageShaderModel modelForSource:userSource];
  const MirageGradientProp *grads = model.gradientProps;
  for (int i = 0; i < model.gradientCount; i++) {
    NSString *nm = @(grads[i].name);
    int n = grads[i].maxStops;
    [members appendFormat:@"  vec4 %@_kks[%d];\n  vec4 %@_kkm[%d];\n"
                          @"  vec4 %@_kkmeta;\n",
                          nm, n, nm, (n + 3) / 4, nm];
    [defines appendFormat:@"#define %@Stops (int(%@_kkmeta.x))\n", nm, nm];
    // Chained saturating mix: below a segment its fraction is 0 (the colour so
    // far stands), above it the fraction is 1 (the segment's end colour wins),
    // so after the loop `c` is the ramp at t. Branch-free, and correct for any
    // live stop count without a dynamic loop bound.
    [fns appendFormat:
             @"vec3 %@At(float t) {\n"
             @"  t = clamp(t, 0.0, 1.0);\n"
             @"  int kkn = %@Stops;\n"
             @"  vec3 c = %@_kks[0].rgb;\n"
             @"  for (int i = 0; i + 1 < %d; i++) {\n"
             @"    if (i + 1 >= kkn) break;\n"
             @"    float p0 = %@_kks[i].w, p1 = %@_kks[i + 1].w;\n"
             @"    float f = clamp((t - p0) / max(p1 - p0, 1e-5), 0.0, 1.0);\n"
             @"    c = mix(c, %@_kks[i + 1].rgb,\n"
             @"            kkGradBias(f, %@_kkm[i >> 2][i & 3]));\n"
             @"  }\n"
             @"  return c;\n}\n",
             nm, nm, nm, n, nm, nm, nm, nm];
    NSString *pat = [NSString
        stringWithFormat:
            @"(?m)^[ \\t]*uniform\\s+vec4\\s+%@\\s*\\[[^\\]]*\\]\\s*;%@", nm,
            kKKUniformStripTail];
    [[NSRegularExpression regularExpressionWithPattern:pat options:0 error:nil]
        replaceMatchesInString:body
                       options:0
                         range:NSMakeRange(0, body.length)
                  withTemplate:@""];
  }
}

// `// #frames offsets="..."`: one sampler per declared offset, in declaration
// order, at the bindings straight after iChannel0-3. The render fills each with
// the source clip at that frame - gamma-encoded exactly as iChannel0 is, so a
// temporal blend mixes like values instead of shifting colour.
//
// Emitted for the IMAGE pass only. A Buffer pass stores data a later pass
// samples and is not the place a frame arrives; it also has no guaranteed
// iChannel0 for `iNeighborAt` to fall back on.
//
// The samplers are declared but reached through `iNeighborAt(i, uv)`: a GLSL
// sampler array cannot be indexed by a runtime value under Vulkan rules, and a
// trail loop wants exactly that. The chained constant-index compares below give
// the loop back, and an out-of-range index reads the current frame rather than
// whatever the last texture unit happens to hold.
static void KKAppendFrameSamplers(NSMutableString *s, NSString *userSource,
                                  KKGLSLPassKind pass) {
  if (pass != KKGLSLPassImage)
    return;
  MirageFrameOffsets fo = MirageFrameOffsetsForSource(userSource, NULL);
  if (fo.count <= 0)
    return;
  for (int i = 0; i < fo.count; i++)
    [s appendFormat:@"layout(binding = %d) uniform sampler2D iNeighbor%d;\n",
                    5 + i, i];
  [s appendFormat:@"#define iNeighborCount %d\n", fo.count];
  NSMutableString *values = [NSMutableString string];
  for (int i = 0; i < fo.count; i++)
    [values appendFormat:@"%@%d", i ? @", " : @"", fo.offsets[i]];
  [s appendFormat:@"const int kkNeighborOffsets[%d] = int[%d](%@);\n", fo.count,
                  fo.count, values];
  [s appendString:@"int iNeighborOffset(int kki) {\n"
                  @"  return (kki < 0 || kki >= iNeighborCount) ? 0\n"
                  @"       : kkNeighborOffsets[kki];\n}\n"
                  @"vec4 iNeighborAt(int kki, vec2 kkuv) {\n"];
  for (int i = 0; i < fo.count; i++)
    [s appendFormat:@"  if (kki == %d) return texture(iNeighbor%d, kkuv);\n", i,
                    i];
  [s appendString:@"  return texture(iChannel0, kkuv);\n}\n"];
}

// The sRGB decode + core film-grain overlay every display path calls. Grain is
// ported verbatim from MirageCommon.h so Custom grain matches the built-in
// Types; it is applied in gamma space before encoding.
//
// EDITING THIS FILE DURING DEVELOPMENT: restart FCP, don't just rebuild.
// KKTranspileMemoized keys its cache on the USER SOURCE ALONE, and the pipeline
// cache below it keys on the resulting MSL digest - so a wrapper change that
// leaves the user source untouched returns the OLD MSL from the memo, produces
// the same digest, and quietly reuses the OLD pipeline. The cache is a
// process-wide static, so a fresh effect instance won't clear it either.
// Shipped builds are unaffected (new process, cold cache); this only bites
// while iterating.
static void KKAppendColorHelpers(NSMutableString *s) {
  [s appendString:
          @"vec3 kkSrgbToLinear(vec3 c) {\n"
          @"  c = clamp(c, 0.0, 1.0);\n"
          @"  bvec3 lo = lessThanEqual(c, vec3(0.04045));\n"
          @"  return mix(pow((c + 0.055) / 1.055, vec3(2.4)), c / 12.92, "
          @"vec3(lo));\n}\n"
          @"vec3 kkLinearToSrgb(vec3 c) {\n"
          @"  c = clamp(c, 0.0, 1.0);\n"
          @"  bvec3 lo = lessThanEqual(c, vec3(0.0031308));\n"
          @"  return mix(1.055 * pow(c, vec3(1.0 / 2.4)) - 0.055, c * 12.92, "
          @"vec3(lo));\n}\n"];
  // A gradient stop's MIDPOINT: where the halfway colour of the segment BELOW
  // it lands. Two straight ramps meeting at (m, 0.5) - the same piecewise bias
  // KKGradientSampleStopsToLUT applies, so the shader matches the gradient bar
  // in the inspector exactly rather than approximately.
  [s appendString:@"float kkGradBias(float f, float m) {\n"
                  @"  if (m <= 0.0 || m >= 1.0) return f;\n"
                  @"  return (f <= m) ? 0.5 * (f / m)\n"
                  @"                  : 0.5 + 0.5 * ((f - m) / (1.0 - m));\n"
                  @"}\n"];
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
}

// The tail of main(): turn mainImage's output into what this pass must store.
// The three display branches differ only in how alpha is treated. `// #alpha`
// and two-input transition shaders both own their output coverage; forcing
// either opaque would turn an unpaired transition side into a black frame.
static void KKAppendOutputBranch(NSMutableString *s, NSString *userSource,
                                 KKGLSLPassKind pass, BOOL honorAlpha) {
  if (pass == KKGLSLPassBuffer) {
    // A Buffer pass stores raw DATA a later pass samples (e.g. a distance /
    // position packed into RGBA). No grain, no sRGB, no clamp, no forced-opaque
    // - pass mainImage's output straight through.
    [s appendString:@"  kk_outColor = kkColor;\n}\n"];
    return;
  }
  if (KKLooksLikeColorTransformShader(userSource)) {
    // FxPlug float surfaces carry linear host values. A technical transform
    // deliberately consumes and produces those values directly; applying the
    // ordinary Shadertoy sRGB compatibility decode here would corrupt log
    // curves and wide-gamut linear outputs. Encode only for an 8-bit target.
    [s appendString:@"  vec3 rgb = max(kkColor.rgb, vec3(0.0));\n"
                    @"  rgb = (kkExtra.w == 0.0) ? rgb : kkLinearToSrgb(rgb);\n"
                    @"  float kka = clamp(kkColor.a, 0.0, 1.0);\n"
                    @"  kk_outColor = vec4(rgb * kka, kka);\n}\n"];
    return;
  }
  // Grain in gamma/display space (screen-fixed, raw gl_FragCoord) before the
  // sRGB encode, on every display path.
  [s appendString:@"  vec3 disp = kkApplyGrain(clamp(kkColor.rgb, 0.0, 1.0), "
                  @"gl_FragCoord.xy);\n"];
  if (KKWantsAlphaOutput(userSource) ||
      KKLooksLikeTransitionShader(userSource)) {
    // `// #alpha`: premultiplied passthrough of the shader's own alpha. No
    // composite over the source (the shader is masking that source), no forced
    // opaque.
    // Premultiply in LINEAR on BOTH paths, then encode back for a gamma
    // target. Multiplying colour by coverage is only meaningful in linear
    // light, and doing it in gamma (as the 8-bit path used to) displays the
    // faint end of a ramp 3-5x darker than the float path does - the same
    // shader looked materially different in the mini viewer and the main
    // viewer, which is a preview you can't trust for anything soft-edged.
    [s appendString:
            @"  float kka = clamp(kkColor.a, 0.0, 1.0);\n"
            @"  vec3 pm = kkSrgbToLinear(disp) * kka;\n"
            @"  kk_outColor = (kkExtra.w == 0.0) ? vec4(pm, kka)\n"
            @"                                  : vec4(kkLinearToSrgb(pm), "
            @"kka);\n}\n"];
  } else if (honorAlpha) {
    // Composite the shader over the source using its own alpha, so transparent
    // areas show the footage (iChannel0) rather than black - the shader is a
    // filter, and its source IS the background. Output is opaque (over the
    // footage); where the source itself is transparent its alpha carries
    // through so lower layers still show.
    [s appendString:
            @"  float kka = clamp(kkColor.a, 0.0, 1.0);\n"
            @"  vec4 kkSrc = texture(iChannel0, fragCoord / iResolution.xy);\n"
            @"  vec3 comp = mix(kkSrc.rgb, disp, kka);\n"
            @"  vec3 rgb = (kkExtra.w == 0.0) ? kkSrgbToLinear(comp) : comp;\n"
            @"  float outA = max(kka, kkSrc.a);\n"
            @"  kk_outColor = vec4(rgb * outA, outA);\n}\n"];
  } else {
    // The image convention ignores fragColor.a (always opaque): golfed shaders
    // accumulate garbage into alpha, so forcing a=1 is safest.
    [s appendString:
            @"  vec3 rgb = (kkExtra.w == 0.0) ? kkSrgbToLinear(disp) : disp;\n"
            @"  kk_outColor = vec4(rgb, 1.0);\n}\n"];
  }
}

NSString *KKWrapGLSL(NSString *userSource, NSUInteger channelMask,
                     NSInteger *outUserLineOffset, KKGLSLPassKind pass) {
  NSMutableString *colorMembers = [NSMutableString string];
  NSMutableString *colorDefines = [NSMutableString string];
  NSMutableString *gradientFns = [NSMutableString string];
  NSMutableString *body = [userSource mutableCopy];
  // Emission order (colours, scalars, audio, gradients) must stay canonical:
  // the std140 member order IS the pool layout the model's offsets describe.
  KKEmitColorProps(userSource, body, colorMembers, colorDefines);
  KKEmitScalarProps(userSource, body, colorMembers, colorDefines);
  KKEmitAudioProps(userSource, body, colorMembers, colorDefines);
  KKEmitGradientProps(userSource, body, colorMembers, colorDefines,
                      gradientFns);

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
                  // Not `progress`: that's a plausible local-variable name in
                  // an ordinary shader, and a #define would rewrite it.
                  @"#define iProgress (kkTransition.x)\n"
                  // Motion blur exposed to `// #motionblur native` shaders: y =
                  // shutter 0..1 (0 when off / not native), z = sample count.
                  @"#define iMotionBlur (kkTransition.y)\n"
                  @"#define iMotionBlurSamples (int(kkTransition.z))\n"
                  // 0 = Transition, 1 = In (transparent From), 2 = Out
                  // (transparent To). Useful when a transition has an
                  // intentional backdrop or source-specific embellishment.
                  @"#define iTransitionMode (int(kkTransition.w))\n"];
  [s appendString:colorDefines];
  // Alpha is honoured by DEFAULT for a shader that does NOT sample the source
  // itself: its transparent areas composite over iChannel0 (the footage) so a
  // generator-style shader never renders a black background. That needs
  // iChannel0 bound even when the shader never references it, so force channel
  // 0 on. A shader that DOES sample iChannel0 manages the source itself (that
  // use wins), so it keeps the opaque image convention (a=1) - which also
  // protects golfed Shadertoy pastes that leave garbage in fragColor.a.
  BOOL honorAlpha = pass == KKGLSLPassImage && !(channelMask & 1u);
  NSUInteger declMask = KKDeclaredChannelMask(channelMask, pass);
  for (NSUInteger ch = 0; ch < 4; ch++) {
    if (declMask & (1u << ch))
      [s appendFormat:@"layout(binding = %lu) uniform sampler2D iChannel%lu;\n",
                      (unsigned long)(ch + 1), (unsigned long)ch];
  }
  KKAppendFrameSamplers(s, userSource, pass);
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
  KKAppendColorHelpers(s);
  [s appendString:gradientFns]; // after kkGradBias, which the samplers call
  [s appendString:@"\n"];
  // The user's source begins on the next line: a glslang error at wrapped line
  // L is the editor's line (L - <newlines so far>).
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
  KKAppendOutputBranch(s, userSource, pass, honorAlpha);
  return s;
}
