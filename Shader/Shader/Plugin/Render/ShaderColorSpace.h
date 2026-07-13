/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

// CPU-side shared-param helpers for the FCP render and the mini-viewer. The
// plugin is Custom-only (runtime-compiled GLSL); the per-Type palette/scalar
// machinery this file used to hold was removed with the built-in Types. Not for
// Metal (uses libm); guarded just in case.
#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>
#import <math.h>
#import <string.h>

#import "ShaderTypes.h"

/// Shared timing defaults.
#define KK_SHADER_GRAD_DEFAULT_SPEED 1.0f // time multiplier (1 = source rate)
#define KK_SHADER_GRAD_DEFAULT_SEED 0.0f

/// Core film-grain overlay (ShaderCommonUniforms). A subtle nonzero default so
/// a fresh instance has tasteful grain that also breaks up 8-bit banding.
#define KK_CORE_GRAIN_DEFAULT 0.06f    // amount (0..1)
#define KK_CORE_GRAINSIZE_DEFAULT 2.0f // grain cell size in whole pixels

/// Default swatch palette (sRGB + alpha) seeding fresh colour lanes and filling
/// un-edited swatches in the render. Kept in sync with the lane catalog.
static const float kShaderDefaultPalette[10][4] = {
    {0.55f, 0.36f, 0.96f, 1.0f}, {0.98f, 0.45f, 0.65f, 1.0f},
    {0.30f, 0.55f, 0.98f, 1.0f}, {0.40f, 0.85f, 0.80f, 1.0f},
    {0.98f, 0.70f, 0.35f, 1.0f}, {0.55f, 0.85f, 0.45f, 1.0f},
    {0.98f, 0.85f, 0.40f, 1.0f}, {0.95f, 0.40f, 0.45f, 1.0f},
    {0.65f, 0.45f, 0.90f, 1.0f}, {0.35f, 0.80f, 0.95f, 1.0f},
};

/// One `// #color`-annotated colour uniform a shader declares. Parsed from the
/// source by the catalog (build lanes), the transpiler (inject the block
/// member) AND the render (fill the colour pool). `count` is the GLSL array
/// dimension (1 for a single); an array also carries a min/max/default count
/// lane. `label` is the display name (from label= or the prettified variable
/// name).
#define KK_SHADER_MAX_COLOR_PROPS 8
typedef struct ShaderColorProp {
  char name[64];    // GLSL uniform name (e.g. "uPalette")
  char label[80];   // display label ("Palette")
  int isArray;      // vec4 name[N] vs vec4 name
  int count;        // array dimension N (single = 1)
  int minCount;     // count lane min (arrays)
  int maxCount;     // count lane max (<= count)
  int defaultCount; // count lane default
  int poolOffset;   // first vec4 index in the colour pool (see
                    // KK_SHADER_COLOR_POOL)
} ShaderColorProp;

static inline int ShaderColorAttrInt(NSString *s, NSString *pattern,
                                     int fallback) {
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

/// A readable display name for a GLSL uniform: drop a leading u/u_/i/i_ prefix,
/// split camelCase + underscores into words, capitalise. `uBackground` ->
/// "Background", `u_foreground_hue` -> "Foreground Hue".
static inline NSString *ShaderPrettifyColorName(NSString *name) {
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

/// Parse every `// #color [label=] [min=] [max=] [default=]` directive and the
/// `uniform vec4 <name>[N]?;` declaration that follows it (before the next
/// directive). Fills `props` in directive order with pool offsets; returns the
/// count and (via outPoolCount) the total vec4s the colour block tail needs.
static inline int ShaderParseColorProps(NSString *source,
                                        ShaderColorProp *props, int maxProps,
                                        int *outPoolCount) {
  if (outPoolCount)
    *outPoolCount = 0;
  int n = 0, pool = 0;
  if (!source.length || maxProps <= 0)
    return 0;
  NSRegularExpression *dirRe = [NSRegularExpression
      regularExpressionWithPattern:@"(?m)^[ \\t]*//[ \\t]*#color\\b([^\\n]*)$"
                           options:0
                             error:nil];
  NSRegularExpression *uniRe = [NSRegularExpression
      regularExpressionWithPattern:
          @"\\buniform\\s+vec4\\s+(\\w+)\\s*(\\[\\s*(\\d+)\\s*\\])?\\s*;"
                           options:0
                             error:nil];
  NSArray<NSTextCheckingResult *> *dirs =
      [dirRe matchesInString:source
                     options:0
                       range:NSMakeRange(0, source.length)];
  for (int di = 0; di < (int)dirs.count && n < maxProps; di++) {
    NSTextCheckingResult *dm = dirs[di];
    NSString *attrs = [source substringWithRange:[dm rangeAtIndex:1]];
    NSUInteger after = NSMaxRange(dm.range);
    // Bound the declaration search to before the next directive so it belongs
    // to THIS directive.
    NSUInteger limit = (di + 1 < (int)dirs.count) ? dirs[di + 1].range.location
                                                  : source.length;
    NSTextCheckingResult *um =
        [uniRe firstMatchInString:source
                          options:0
                            range:NSMakeRange(after, limit - after)];
    if (!um || [um rangeAtIndex:1].location == NSNotFound)
      continue; // a directive with no declaration is ignored
    NSString *nm = [source substringWithRange:[um rangeAtIndex:1]];
    BOOL isArray = [um rangeAtIndex:2].location != NSNotFound;
    int N = [um rangeAtIndex:3].location != NSNotFound
                ? [source substringWithRange:[um rangeAtIndex:3]].intValue
                : 1;
    if (N < 1)
      N = 1;
    if (N > KK_SHADER_MAX_COLORS)
      N = KK_SHADER_MAX_COLORS;
    int slots = isArray ? N + 1 : 1; // array adds a count-meta vec4
    if (pool + slots > KK_SHADER_COLOR_POOL)
      break; // pool full - drop the rest

    ShaderColorProp p;
    memset(&p, 0, sizeof(p));
    strncpy(p.name, nm.UTF8String ?: "", sizeof(p.name) - 1);
    NSTextCheckingResult *lm = [[NSRegularExpression
        regularExpressionWithPattern:@"\\blabel\\s*=\\s*\"([^\"]*)\""
                             options:0
                               error:nil]
        firstMatchInString:attrs
                   options:0
                     range:NSMakeRange(0, attrs.length)];
    NSString *label =
        (lm && [lm rangeAtIndex:1].location != NSNotFound && lm.range.length)
            ? [attrs substringWithRange:[lm rangeAtIndex:1]]
            : ShaderPrettifyColorName(nm);
    strncpy(p.label, label.UTF8String ?: "", sizeof(p.label) - 1);
    p.isArray = isArray;
    p.count = N;
    p.poolOffset = pool;
    if (isArray) {
      int minC = ShaderColorAttrInt(attrs, @"\\bmin\\s*=\\s*(\\d+)", 0);
      int maxC = ShaderColorAttrInt(attrs, @"\\bmax\\s*=\\s*(\\d+)", 0);
      int defC = ShaderColorAttrInt(attrs, @"\\bdefault\\s*=\\s*(\\d+)", 0);
      minC = minC <= 0 ? 1 : minC;
      maxC = (maxC <= 0 || maxC > N) ? N : maxC; // `[N]` is the hard ceiling
      if (minC > maxC)
        minC = maxC;
      if (defC <= 0)
        defC = maxC < 4 ? maxC : 4;
      if (defC > maxC)
        defC = maxC;
      if (defC < minC)
        defC = minC;
      p.minCount = minC;
      p.maxCount = maxC;
      p.defaultCount = defC;
    } else {
      p.minCount = p.maxCount = p.defaultCount = 1;
    }
    props[n++] = p;
    pool += slots;
  }
  if (outPoolCount)
    *outPoolCount = pool;
  return n;
}

/// Fill the colour pool (the transpiled block's std140 tail) from `source`'s
/// `// #color` properties, reading lane values via `valuesForLabel` (label ->
/// [r,g,b,a] or nil). Single props write one vec4; array props write N swatches
/// (fallback: default palette) + a count-meta vec4 (fallback: directive
/// default). Returns the vec4 count written. `pool` must hold
/// KK_SHADER_COLOR_POOL vec4s.
static inline int
ShaderFillColorPool(NSString *source, vector_float4 *pool,
                    NSArray<NSNumber *> * (^valuesForLabel)(NSString *)) {
  for (int i = 0; i < KK_SHADER_COLOR_POOL; i++)
    pool[i] = (vector_float4){0, 0, 0, 0};
  ShaderColorProp props[KK_SHADER_MAX_COLOR_PROPS];
  int poolCount = 0;
  int nProps = ShaderParseColorProps(source, props, KK_SHADER_MAX_COLOR_PROPS,
                                     &poolCount);
  for (int pi = 0; pi < nProps; pi++) {
    ShaderColorProp *p = &props[pi];
    if (p->isArray) {
      NSArray<NSNumber *> *ccV =
          valuesForLabel([NSString stringWithFormat:@"%s Count", p->label]);
      int cc = ccV.count ? (int)lround(ccV[0].doubleValue) : p->defaultCount;
      if (cc < 0)
        cc = 0;
      if (cc > p->count)
        cc = p->count;
      for (int i = 0; i < p->count; i++) {
        NSArray<NSNumber *> *cv = valuesForLabel(
            [NSString stringWithFormat:@"%s %d", p->label, i + 1]);
        if (cv.count >= 4)
          pool[p->poolOffset + i] =
              (vector_float4){cv[0].floatValue, cv[1].floatValue,
                              cv[2].floatValue, cv[3].floatValue};
        else {
          const float *d = kShaderDefaultPalette[i % 10];
          pool[p->poolOffset + i] = (vector_float4){d[0], d[1], d[2], d[3]};
        }
      }
      pool[p->poolOffset + p->count] = (vector_float4){(float)cc, 0, 0, 0};
    } else {
      NSArray<NSNumber *> *cv = valuesForLabel(@(p->label));
      if (cv.count >= 4)
        pool[p->poolOffset] =
            (vector_float4){cv[0].floatValue, cv[1].floatValue,
                            cv[2].floatValue, cv[3].floatValue};
      else {
        const float *d = kShaderDefaultPalette[0];
        pool[p->poolOffset] = (vector_float4){d[0], d[1], d[2], d[3]};
      }
    }
  }
  return poolCount;
}

/// Fallback shared-params block (timing + grain). `origin`/`scale`/`rotation`
/// are vestigial identity values (the legacy transform lanes are gone).
static inline ShaderCommonUniforms ShaderCommonDefault(void) {
  ShaderCommonUniforms c;
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
