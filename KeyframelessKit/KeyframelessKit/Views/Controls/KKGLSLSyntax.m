/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKGLSLSyntax.h"

NSColor *KKHex(uint32_t rgb) {
  return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xff) / 255.0
                             green:((rgb >> 8) & 0xff) / 255.0
                              blue:(rgb & 0xff) / 255.0
                             alpha:1.0];
}
NSColor *KKCodeBG(void) { return KKHex(0x0d1117); }
NSColor *KKCodeBorder(void) { return KKHex(0x30363d); }
NSColor *KKCodeText(void) { return KKHex(0xe6edf3); }
NSColor *KKCodeComment(void) { return KKHex(0x8b949e); }
NSColor *KKCodeKeyword(void) { return KKHex(0xff7b72); }
NSColor *KKCodeUniform(void) { return KKHex(0xffa657); }
NSColor *KKCodeFunction(void) { return KKHex(0xd2a8ff); }
NSColor *KKCodeNumber(void) { return KKHex(0x79c0ff); }
NSColor *KKCodeCursor(void) { return KKHex(0x58a6ff); }
NSColor *KKCodeError(void) { return KKHex(0xf85149); }

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
