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

/// Core film-grain overlay (MirageCommonUniforms). A subtle nonzero default so
/// a fresh instance has tasteful grain that also breaks up 8-bit banding.
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
  c.grain = KK_CORE_GRAIN_DEFAULT;
  c.grainSize = KK_CORE_GRAINSIZE_DEFAULT;
  c.grainScale = 1.0f;
  c.resolution = (vector_float2){1920.0f, 1080.0f};
  return c;
}

#endif // __METAL_VERSION__
