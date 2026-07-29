/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Shared plumbing for the `// #` directive parsers: attribute scraping, the
// uniform-name prettifier, and the always-present shared params (timing +
// grain). Every per-kind header below builds on this one.
#pragma once

#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>
#import <ctype.h>
#import <math.h>
#import <string.h>

#import "MirageTypes.h"

/// Shared timing defaults.
#define KK_SHADER_GRAD_DEFAULT_SPEED 1.0f // time multiplier (1 = source rate)
#define KK_SHADER_GRAD_DEFAULT_SEED 0.0f

/// Film-grain overlay (MirageCommonUniforms). These are the values the LANES
/// start at once a shader opts in with `// #grain`: a subtle nonzero amount
/// that reads as tasteful and also breaks up 8-bit banding. A shader that never
/// asks for grain renders with none at all (see MirageCommonDefault), so this
/// is a starting point rather than a baseline.
#define KK_CORE_GRAIN_DEFAULT 0.06f    // amount (0..1)
#define KK_CORE_GRAINSIZE_DEFAULT 2.0f // grain cell size in whole pixels

static inline int MirageAttrInt(NSString *s, NSString *pattern, int fallback) {
  NSTextCheckingResult *m =
      [[NSRegularExpression regularExpressionWithPattern:pattern
                                                 options:0
                                                   error:nil]
          firstMatchInString:s
                     options:0
                       range:NSMakeRange(0, s.length)];
  if (!m || [m rangeAtIndex:1].location == NSNotFound)
    return fallback;
  return [s substringWithRange:[m rangeAtIndex:1]].intValue;
}

static inline double MirageAttrDouble(NSString *s, NSString *pattern,
                                      double fallback) {
  NSTextCheckingResult *m =
      [[NSRegularExpression regularExpressionWithPattern:pattern
                                                 options:0
                                                   error:nil]
          firstMatchInString:s
                     options:0
                       range:NSMakeRange(0, s.length)];
  if (!m || [m rangeAtIndex:1].location == NSNotFound)
    return fallback;
  return [s substringWithRange:[m rangeAtIndex:1]].doubleValue;
}

/// A quoted string attribute (`key="value"`), or nil when absent.
static inline NSString *MirageAttrString(NSString *s, NSString *key) {
  if (!s.length)
    return nil;
  NSString *pat =
      [NSString stringWithFormat:@"\\b%@\\s*=\\s*\"([^\"]*)\"", key];
  NSTextCheckingResult *m =
      [[NSRegularExpression regularExpressionWithPattern:pat
                                                 options:0
                                                   error:nil]
          firstMatchInString:s
                     options:0
                       range:NSMakeRange(0, s.length)];
  if (!m || [m rangeAtIndex:1].location == NSNotFound)
    return nil;
  return [s substringWithRange:[m rangeAtIndex:1]];
}

/// Whether `word` appears as a bare directive flag. Quoted attribute values are
/// ignored, so labels and option names cannot accidentally enable behaviour.
static inline BOOL MirageAttrHasBareFlag(NSString *attrs, NSString *word) {
  if (!attrs.length || !word.length)
    return NO;
  NSString *bare =
      [[NSRegularExpression regularExpressionWithPattern:@"\"[^\"]*\""
                                                 options:0
                                                   error:nil]
          stringByReplacingMatchesInString:attrs
                                   options:0
                                     range:NSMakeRange(0, attrs.length)
                              withTemplate:@""];
  NSString *pattern = [NSString
      stringWithFormat:@"\\b%@\\b",
                       [NSRegularExpression escapedPatternForString:word]];
  return [[NSRegularExpression regularExpressionWithPattern:pattern
                                                    options:0
                                                      error:nil]
             firstMatchInString:bare
                        options:0
                          range:NSMakeRange(0, bare.length)] != nil;
}

/// A readable display name for a GLSL uniform: drop a leading u/u_/i/i_ prefix,
/// split camelCase + underscores into words, capitalise. `uBackground` ->
/// "Background", `u_foreground_hue` -> "Foreground Hue".
static inline NSString *MiragePrettifyUniformName(NSString *name) {
  if (!name.length)
    return @"Color";
  NSString *base = name;
  if (name.length >= 2) {
    unichar c0 = [name characterAtIndex:0], c1 = [name characterAtIndex:1];
    BOOL upperNext = (c1 >= 'A' && c1 <= 'Z');
    if ((c0 == 'u' || c0 == 'i') && (upperNext || c1 == '_'))
      base = [name substringFromIndex:(c1 == '_' ? 2 : 1)];
  }
  base = [base stringByReplacingOccurrencesOfString:@"_" withString:@" "];
  NSMutableString *out = [NSMutableString string];
  for (NSUInteger i = 0; i < base.length; i++) {
    unichar c = [base characterAtIndex:i];
    if (i > 0 && c >= 'A' && c <= 'Z') {
      unichar p = [base characterAtIndex:i - 1];
      if (!(p >= 'A' && p <= 'Z') && p != ' ')
        [out appendString:@" "];
    }
    [out appendFormat:@"%C", c];
  }
  NSString *t = [out
      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  if (!t.length)
    return @"Color";
  return [[[t substringToIndex:1] uppercaseString]
      stringByAppendingString:[t substringFromIndex:1]];
}

/// Where a control lands when its directive names no group. Free-form like
/// every other group name, so a shader writing `group={"Options"}` merges into
/// the same group rather than making a second one that looks identical.
static NSString *const kMirageDefaultGroup = @"Options";
static NSString *const kMirageDefaultGroupSymbol = @"slider.horizontal.3";

/// The groups that are not the shader's to name (the code editor and the
/// colour swatches; audio's lives in MirageAudioProps.h). These lead the
/// inspector in a fixed order, so editing directives never shuffles them.
static NSString *const kMirageShaderCategory = @"Shader";
static NSString *const kMirageColorCategory = @"Colors";

/// Parse a `group=` attribute into its display name and optional SF Symbol.
/// Accepts the braced pair `group={"Glow Options", "sparkles"}` (the symbol is
/// optional) and the bare `group="Glow Options"`. The quoted strings are pulled
/// out in order rather than split on commas, so a group name may contain one.
/// Absent attribute = both buffers left as they were (the caller's default).
static inline void MirageParseGroupAttr(NSString *attrs, char *outGroup,
                                        size_t groupSize, char *outSymbol,
                                        size_t symbolSize) {
  if (!attrs.length)
    return;
  NSTextCheckingResult *m = [[NSRegularExpression
      regularExpressionWithPattern:@"\\bgroup\\s*=\\s*(\\{[^}]*\\}|\"[^\"]*\")"
                           options:0
                             error:nil]
      firstMatchInString:attrs
                 options:0
                   range:NSMakeRange(0, attrs.length)];
  if (!m || [m rangeAtIndex:1].location == NSNotFound)
    return;
  NSString *body = [attrs substringWithRange:[m rangeAtIndex:1]];
  NSArray<NSTextCheckingResult *> *qs =
      [[NSRegularExpression regularExpressionWithPattern:@"\"([^\"]*)\""
                                                 options:0
                                                   error:nil]
          matchesInString:body
                  options:0
                    range:NSMakeRange(0, body.length)];
  for (int k = 0; k < 2 && k < (int)qs.count; k++) {
    NSString *t = [[body substringWithRange:[qs[k] rangeAtIndex:1]]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!t.length)
      continue;
    if (k == 0)
      strncpy(outGroup, t.UTF8String ?: "", groupSize - 1);
    else
      strncpy(outSymbol, t.UTF8String ?: "", symbolSize - 1);
  }
}

/// Fallback shared-params block (timing + grain). `origin`/`scale`/`rotation`
/// are vestigial identity values (the legacy transform lanes are gone).
static inline MirageCommonUniforms MirageCommonDefault(void) {
  MirageCommonUniforms c;
  memset(&c, 0, sizeof(c));
  c.origin = (vector_float2){0.5f, 0.5f};
  c.scale = (vector_float2){1.0f, 1.0f};
  c.rotation = 0.0f;
  c.time = 0.0f;
  c.speed = KK_SHADER_GRAD_DEFAULT_SPEED;
  c.seed = 0.0f;
  // NEUTRAL, not the lane default: these are what a shader that declared no
  // `// #grain` renders with, and an opt-in control that still applied when
  // nobody opted in would not be one.
  c.grain = 0.0f;
  c.grainSize = KK_CORE_GRAINSIZE_DEFAULT;
  c.grainScale = 1.0f;
  c.resolution = (vector_float2){1920.0f, 1080.0f};
  return c;
}

#endif // __METAL_VERSION__
