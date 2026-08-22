/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKGLSLTranspiler_Internal.h"
#import "MirageTemplateType.h"

// Source-to-source rewrites that run BEFORE wrapping, folding a neighbouring
// GLSL dialect into the image-shader convention this engine speaks
// (`mainImage(out vec4, in vec2)` + iChannel0 / iResolution / iTime). Every
// rewrite here is LINE-COUNT PRESERVING so a glslang error still maps back to
// the editor line the user is looking at.

// GLSL permits identifiers like `or`, `and`, `xor`, `compl` that are reserved
// OPERATOR tokens in MSL/C++ (Metal is C++-based). SPIRV-Cross carries the
// source name straight into the MSL, where it fails the Metal compile. Rename
// them (word-boundary) in the user source before wrapping. `not` is
// DELIBERATELY excluded - it's a GLSL built-in function (`not(bvec)`); renaming
// it would break shaders that use it. Line count is preserved (word -> word),
// so the glslang error-line mapping is unaffected.
NSString *KKRenameReservedIdentifiers(NSString *src) {
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

// gl-transitions.com shaders speak a neighbouring dialect: a
// `vec4 transition(vec2 uv)` entry point, host-supplied `progress` / `ratio` /
// `getFromColor` / `getToColor`, and custom uniforms whose default rides in a
// trailing `// = value` comment. Adapt them rather than make an author
// hand-port every shader in the catalogue. The signature is the tell - nothing
// else declares `vec4 transition(vec2`.
BOOL KKLooksLikeGLTransition(NSString *src) {
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
BOOL KKWantsAlphaOutput(NSString *src) {
  if (!src.length)
    return NO;
  static NSRegularExpression *re;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    re = [NSRegularExpression
        regularExpressionWithPattern:@"(?m)^[ \\t]*//[ \\t]*#alpha(?![-\\w:])"
                             options:0
                               error:nil];
  });
  return [re firstMatchInString:src
                        options:0
                          range:NSMakeRange(0, src.length)] != nil;
}

BOOL KKLooksLikeTransitionShader(NSString *src) {
  return MirageTemplateTypeForSource(src, NULL) == MirageTemplateTypeTransition;
}

BOOL KKLooksLikeColorTransformShader(NSString *src) {
  return MirageTemplateTypeForSource(src, NULL) ==
         MirageTemplateTypeColorTransform;
}

BOOL KKLooksLikeGeneratorShader(NSString *src) {
  return MirageTemplateTypeForSource(src, NULL) == MirageTemplateTypeGenerator;
}

MirageMotionBlurMode MirageMotionBlurModeForSource(NSString *src) {
  if (!src.length)
    return MirageMotionBlurModeAccumulate;
  static NSRegularExpression *re;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    re = [NSRegularExpression
        regularExpressionWithPattern:
            @"(?m)^[ \\t]*//[ \\t]*#motionblur[ \\t]+([a-zA-Z]+)"
                             options:0
                               error:nil];
  });
  NSTextCheckingResult *m = [re firstMatchInString:src
                                           options:0
                                             range:NSMakeRange(0, src.length)];
  if (!m || [m rangeAtIndex:1].location == NSNotFound)
    return MirageMotionBlurModeAccumulate;
  NSString *word =
      [[src substringWithRange:[m rangeAtIndex:1]] lowercaseString];
  if ([word isEqualToString:@"native"])
    return MirageMotionBlurModeNative;
  if ([word isEqualToString:@"off"] || [word isEqualToString:@"none"])
    return MirageMotionBlurModeOff;
  return MirageMotionBlurModeAccumulate;
}

BOOL MirageMotionBlurDefaultsOnForSource(NSString *src) {
  if (!src.length)
    return NO;
  static NSRegularExpression *re;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // The whole directive line after `#motionblur`, so the `on` is found
    // whether or not a mode word precedes it.
    re = [NSRegularExpression
        regularExpressionWithPattern:
            @"(?m)^[ \\t]*//[ \\t]*#motionblur(?![-\\w:])(.*)$"
                             options:0
                               error:nil];
  });
  NSTextCheckingResult *m = [re firstMatchInString:src
                                           options:0
                                             range:NSMakeRange(0, src.length)];
  if (!m || [m rangeAtIndex:1].location == NSNotFound)
    return NO;
  NSString *rest = [src substringWithRange:[m rangeAtIndex:1]];
  return
      [rest rangeOfString:@"\\bon\\b"
                  options:NSRegularExpressionSearch | NSCaseInsensitiveSearch]
          .location != NSNotFound;
}

// Fold a GL-Transitions shader into the image-shader convention.
//
// Both rewrites are LINE-COUNT SAFE so a glslang error still maps to the
// editor: the uniform fold stays on its own line, and `mainImage` is APPENDED
// (appending shifts nothing above it). The preamble that supplies
// getFromColor / getToColor / progress / ratio is emitted by KKWrapGLSL's
// prepended block instead, which `lineOffset` already accounts for.
NSString *KKShimGLTransition(NSString *src) {
  if (!KKLooksLikeGLTransition(src))
    return src;
  NSMutableString *s = [src mutableCopy];

  // `uniform float strength; // = 1.0` -> `const float strength = 1.0;`.
  // Left as a bare uniform it would get a binding nothing ever writes, so every
  // knob would silently read 0 (and this shader's burst() would flatten to
  // nothing). Constants make it RUN correctly on the author's defaults; turning
  // these into real inspector controls is the next step.
  NSRegularExpression *uni =
      [NSRegularExpression regularExpressionWithPattern:
                               @"(?m)\\buniform\\s+(float|int|bool|vec2|vec3"
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

// Best-effort compatibility shim. Plenty of shaders online are written for a
// raw WebGL / three.js / glslCanvas / Book-of-Shaders pipeline: a `void main()`
// + `gl_FragColor` (or a GLSL3 `out vec4`) fragment that reads host-named
// uniforms (uTexture, vUv, u_time, ...). This engine speaks the image-shader
// convention
// (`mainImage(out vec4, in vec2)` with iChannel0 / iResolution / iTime), so
// those shaders would collide on `main` and reference undeclared names. This
// pass rewrites the common cases into our convention: it maps the well-known
// host uniform / varying names, converts the entry point + output, neutralises
// the gl_ builtins, and drops declarations we supply ourselves. Line-count
// preserving so a glslang error still maps to the editor line. A shader already
// using `mainImage` passes through untouched; uncommon custom uniform names
// still need a hand edit (the validator points at them).
NSString *KKShimRawGLSL(NSString *src) {
  if (!src.length)
    return src ?: @"";
  if ([src rangeOfString:@"mainImage"].location != NSNotFound)
    return src; // already an image shader

  NSRegularExpression *mainRe = [NSRegularExpression
      regularExpressionWithPattern:@"\\bvoid\\s+main\\s*\\("
                           options:0
                             error:nil];
  BOOL looksRaw = [src rangeOfString:@"gl_FragColor"].location != NSNotFound ||
                  [src rangeOfString:@"gl_FragData"].location != NSNotFound ||
                  [mainRe firstMatchInString:src
                                     options:0
                                       range:NSMakeRange(0, src.length)] != nil;
  if (!looksRaw)
    return src; // a bare helper snippet: leave it be

  NSMutableString *s = [src mutableCopy];
  NSString * (^find)(NSString *) = ^NSString *(NSString *pat) {
    NSRegularExpression *re =
        [NSRegularExpression regularExpressionWithPattern:pat
                                                  options:0
                                                    error:nil];
    NSTextCheckingResult *m = [re firstMatchInString:s
                                             options:0
                                               range:NSMakeRange(0, s.length)];
    return (m && m.numberOfRanges > 1)
               ? [s substringWithRange:[m rangeAtIndex:1]]
               : nil;
  };
  void (^sub)(NSString *, NSString *) = ^(NSString *pat, NSString *repl) {
    NSRegularExpression *re =
        [NSRegularExpression regularExpressionWithPattern:pat
                                                  options:0
                                                    error:nil];
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

  // Capture every declared sampler2D uniform (before we strip declarations).
  // Our engine has one real texture input (iChannel0 = source), so mapping
  // declared samplers to iChannel0..3 in order lets a single-texture raw shader
  // work whatever the sampler is named - no hardcoded name list needed.
  NSMutableArray<NSString *> *samplerNames = [NSMutableArray array];
  {
    NSRegularExpression *sre =
        [NSRegularExpression regularExpressionWithPattern:
                                 @"(?m)^[ \\t]*uniform\\s+sampler2D\\s+(\\w+)"
                                                  options:0
                                                    error:nil];
    [sre enumerateMatchesInString:s
                          options:0
                            range:NSMakeRange(0, s.length)
                       usingBlock:^(NSTextCheckingResult *m,
                                    NSMatchingFlags flg, BOOL *stop) {
                         if (m.numberOfRanges > 1)
                           [samplerNames addObject:[s substringWithRange:
                                                           [m rangeAtIndex:1]]];
                       }];
  }

  // Drop declarations we provide (or can't bind) + #version / precision.
  // Content only, newline kept, so error-line mapping survives.
  sub(@"(?m)^[ \\t]*(?:uniform|varying|attribute|in|out)\\b[^;\\n]*;", @"");
  sub(@"(?m)^[ \\t]*precision\\b[^;\\n]*;", @"");
  sub(@"(?m)^[ \\t]*#version\\b[^\\n]*", @"");

  // Declared samplers -> iChannel0..3 in declaration order (the primary texture
  // becomes the source clip). Handles any name, so `videoTex`, `myFunkyTex`,
  // etc. work without appearing in the list below.
  for (NSUInteger i = 0; i < samplerNames.count && i < 4; i++)
    mapNames(@[ samplerNames[i] ],
             [NSString stringWithFormat:@"iChannel%lu", (unsigned long)i]);

  // Map the well-known host names onto our globals (covers a texture used
  // without an explicit declaration). Deliberately conservative: only
  // distinctive, prefixed names (never bare `time` / `uv` / `resolution`) so a
  // local variable is never clobbered.
  mapNames(
      @[
        @"uTexture", @"u_texture", @"tDiffuse", @"texture0", @"tex0",
        @"uSampler", @"uTex", @"u_tex", @"uImage", @"uMainTex", @"inputTexture",
        @"backbuffer", @"uDiffuse", @"uSource"
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
