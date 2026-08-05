/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// GLSL + expression GRAMMAR for the code editor: the tokenizer regexes and
// per-word colour classification. Theme palette -> KKCodeTheme.m; the
// expression vocabulary/catalog -> KKExprCatalog.m.

#import "KKGLSLSyntax.h"

NSColor *KKGLSLWordColor(NSString *w) {
  static NSSet *keywords, *uniforms;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    keywords = [NSSet setWithArray:@[
      // control + qualifiers
      @"if", @"else", @"for", @"while", @"do", @"return", @"break", @"continue",
      @"discard", @"const", @"in", @"out", @"inout", @"struct", @"true",
      @"false", @"uniform", @"varying", @"attribute", @"precision", @"highp",
      @"mediump", @"lowp", @"switch", @"case", @"default", @"layout",
      // types (GitHub colours storage types like keywords)
      @"void", @"float", @"int", @"uint", @"bool", @"double", @"vec2", @"vec3",
      @"vec4", @"ivec2", @"ivec3", @"ivec4", @"uvec2", @"uvec3", @"uvec4",
      @"bvec2", @"bvec3", @"bvec4", @"mat2", @"mat3", @"mat4", @"mat2x2",
      @"mat3x3", @"mat4x4", @"sampler2D", @"sampler3D", @"samplerCube",
      @"sampler2DArray"
    ]];
    uniforms = [NSSet setWithArray:@[
      @"iResolution", @"iTime", @"iTimeDelta", @"iFrame", @"iFrameRate",
      @"iChannelTime", @"iChannelResolution", @"iMouse", @"iDate",
      @"iSampleRate", @"iChannel0", @"iChannel1", @"iChannel2", @"iChannel3"
    ]];
  });
  if ([keywords containsObject:w])
    return KKCodeKeyword();
  if ([uniforms containsObject:w])
    return KKCodeUniform();
  return nil;
}

NSColor *KKExprWordColor(NSString *w) {
  static NSSet *fns, *vars;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    fns = [NSSet setWithArray:@[
      @"sin",      @"cos",       @"tan",     @"abs",        @"sign",
      @"floor",    @"ceil",      @"round",   @"sqrt",       @"exp",
      @"log",      @"rad",       @"deg",     @"min",        @"max",
      @"mod",      @"pow",       @"atan2",   @"hypot",      @"step",
      @"clamp",    @"lerp",      @"mix",     @"smoothstep", @"easeIn",
      @"easeOut",  @"easeInOut", @"elastic", @"bounce",     @"repeat",
      @"pingpong", @"vec2",      @"vec3",    @"vec4",       @"random",
      @"noise"
    ]];
    vars = [NSSet setWithArray:@[
      @"value", @"t", @"progress", @"ct", @"pi", @"tau", @"e"
    ]];
  });
  if ([fns containsObject:w])
    return KKCodeFunction();
  if ([vars containsObject:w])
    return KKCodeKeyword();
  return nil;
}

NSSet<NSString *> *KKGLSLDeclaredUniforms(NSString *source) {
  if (source.length == 0)
    return [NSSet set];
  static NSRegularExpression *re;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    // `uniform` ... last identifier before an optional `[array]` and the `;`.
    // The lazy `[^;{}]*?` swallows the type + any qualifiers (highp, etc).
    re = [NSRegularExpression
        regularExpressionWithPattern:
            @"\\buniform\\b[^;{}]*?([A-Za-z_]\\w*)\\s*(?:\\[[^\\]]*\\])?\\s*;"
                             options:0
                               error:nil];
  });
  NSMutableSet<NSString *> *out = [NSMutableSet set];
  [re enumerateMatchesInString:source
                       options:0
                         range:NSMakeRange(0, source.length)
                    usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags,
                                 BOOL *stop) {
                      NSRange r = [m rangeAtIndex:1];
                      if (r.location != NSNotFound)
                        [out addObject:[source substringWithRange:r]];
                    }];
  return out;
}

NSRegularExpression *KKExprTokenizer(void) {
  static NSRegularExpression *re;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    re = [NSRegularExpression
        regularExpressionWithPattern:
            @"(\\$\\{[^}]*\\})"                                  // 1 ${ref}
            @"|((?:\\d+\\.?\\d*(?:[eE][+-]?\\d+)?)|(?:\\.\\d+))" // 2 num
            @"|([A-Za-z_]\\w*)"                                  // 3 ident
                             options:0
                               error:nil];
  });
  return re;
}

NSRegularExpression *KKGLSLTokenizer(void) {
  static NSRegularExpression *re;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    re = [NSRegularExpression regularExpressionWithPattern:
                                  @"(/\\*[\\s\\S]*?\\*/|//[^\\n]*)" // 1 comment
                                  @"|(#[A-Za-z_]+)"                 // 2 pp
                                  @"|(\\b\\d+\\.?\\d*(?:[eE][+-]?\\d+)?[fFuU]?"
                                  @"\\b|\\.\\d+[fF]?)" // 3 num
                                  @"|([A-Za-z_]\\w*)"  // 4 ident
                                                   options:0
                                                     error:nil];
  });
  return re;
}
