/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// `// #color` directives: colour swatches and palette bars.
#pragma once

#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>
#import <ctype.h>
#import <math.h>
#import <string.h>

#import "ShaderDirectiveCommon.h"
#import "ShaderTypes.h"

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
  // Author-supplied default swatches from `default="#hex,#hex,..."`
  // (sRGB+alpha, like kShaderDefaultPalette). When hasDefColors is 0 the
  // built-in palette is used, preserving the old behaviour. These seed the
  // lanes AND are what Reset reverts to, so a shader's intended palette lives
  // in its source.
  int hasDefColors;
  int defColorCount;
  float defColors[KK_SHADER_MAX_COLORS][4];
} ShaderColorProp;

/// One nibble of a hex digit, or -1.
static inline int ShaderHexNibble(char c) {
  if (c >= '0' && c <= '9')
    return c - '0';
  if (c >= 'a' && c <= 'f')
    return c - 'a' + 10;
  if (c >= 'A' && c <= 'F')
    return c - 'A' + 10;
  return -1;
}

/// Parse one `#RGB` / `#RRGGBB` / `#RRGGBBAA` token (leading `#` optional) into
/// an sRGB+alpha float4. Returns NO on any non-hex or wrong-length token.
static inline BOOL ShaderParseHexColor(NSString *tok, float out[4]) {
  NSString *t = [tok
      stringByTrimmingCharactersInSet:[NSCharacterSet whitespaceCharacterSet]];
  const char *s = t.UTF8String;
  if (!s)
    return NO;
  if (*s == '#')
    s++;
  int d[8], nd = 0;
  while (nd < 8 && s[nd]) {
    int v = ShaderHexNibble(s[nd]);
    if (v < 0)
      break;
    d[nd] = v;
    nd++;
  }
  if (s[nd] != '\0')
    return NO; // trailing garbage
  out[3] = 1.0f;
  if (nd == 3) {
    out[0] = (d[0] * 16 + d[0]) / 255.0f;
    out[1] = (d[1] * 16 + d[1]) / 255.0f;
    out[2] = (d[2] * 16 + d[2]) / 255.0f;
  } else if (nd == 6 || nd == 8) {
    out[0] = (d[0] * 16 + d[1]) / 255.0f;
    out[1] = (d[2] * 16 + d[3]) / 255.0f;
    out[2] = (d[4] * 16 + d[5]) / 255.0f;
    if (nd == 8)
      out[3] = (d[6] * 16 + d[7]) / 255.0f;
  } else {
    return NO;
  }
  return YES;
}

/// Parse a `default="#hex,#hex,..."` attribute into up to `maxN` swatches.
/// Returns the number parsed (0 when the attribute is absent or not a hex list,
/// e.g. a bare `default=3` count). Stops at the first non-hex token.
static inline int ShaderParseColorDefaults(NSString *attrs,
                                           float defColors[][4], int maxN) {
  NSTextCheckingResult *m = [[NSRegularExpression
      regularExpressionWithPattern:@"\\bdefault\\s*=\\s*\"([^\"]*)\""
                           options:0
                             error:nil]
      firstMatchInString:attrs
                 options:0
                   range:NSMakeRange(0, attrs.length)];
  if (!m || [m rangeAtIndex:1].location == NSNotFound)
    return 0;
  NSString *list = [attrs substringWithRange:[m rangeAtIndex:1]];
  NSArray<NSString *> *toks = [list componentsSeparatedByString:@","];
  int n = 0;
  for (NSString *tok in toks) {
    if (n >= maxN)
      break;
    float c[4];
    if (!ShaderParseHexColor(tok, c))
      break;
    defColors[n][0] = c[0];
    defColors[n][1] = c[1];
    defColors[n][2] = c[2];
    defColors[n][3] = c[3];
    n++;
  }
  return n;
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
            : ShaderPrettifyUniformName(nm);
    strncpy(p.label, label.UTF8String ?: "", sizeof(p.label) - 1);
    p.isArray = isArray;
    p.count = N;
    p.poolOffset = pool;
    if (isArray) {
      int minC = ShaderAttrInt(attrs, @"\\bmin\\s*=\\s*(\\d+)", 0);
      int maxC = ShaderAttrInt(attrs, @"\\bmax\\s*=\\s*(\\d+)", 0);
      int defC = ShaderAttrInt(attrs, @"\\bdefault\\s*=\\s*(\\d+)", 0);
      // A quoted hex list, e.g. default="#06080F,#57E0FF", seeds the swatches
      // (a bare default=3 stays count-only). The list also sets the default
      // active count when no numeric count is given.
      int ndc = ShaderParseColorDefaults(attrs, p.defColors, N);
      if (ndc > 0) {
        p.hasDefColors = 1;
        p.defColorCount = ndc;
      }
      minC = minC <= 0 ? 1 : minC;
      maxC = (maxC <= 0 || maxC > N) ? N : maxC; // `[N]` is the hard ceiling
      if (minC > maxC)
        minC = maxC;
      if (defC <= 0)
        defC = ndc > 0 ? ndc : (maxC < 4 ? maxC : 4);
      if (defC > maxC)
        defC = maxC;
      if (defC < minC)
        defC = minC;
      p.minCount = minC;
      p.maxCount = maxC;
      p.defaultCount = defC;
    } else {
      p.minCount = p.maxCount = p.defaultCount = 1;
      float dc[1][4];
      if (ShaderParseColorDefaults(attrs, dc, 1) > 0) {
        p.hasDefColors = 1;
        p.defColorCount = 1;
        p.defColors[0][0] = dc[0][0];
        p.defColors[0][1] = dc[0][1];
        p.defColors[0][2] = dc[0][2];
        p.defColors[0][3] = dc[0][3];
      }
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
      // Look up by the uniform NAME (lane identity), not the display label.
      NSArray<NSNumber *> *ccV =
          valuesForLabel([NSString stringWithFormat:@"%s Count", p->name]);
      int cc = ccV.count ? (int)lround(ccV[0].doubleValue) : p->defaultCount;
      if (cc < 0)
        cc = 0;
      if (cc > p->count)
        cc = p->count;
      for (int i = 0; i < p->count; i++) {
        NSArray<NSNumber *> *cv = valuesForLabel(
            [NSString stringWithFormat:@"%s %d", p->name, i + 1]);
        if (cv.count >= 4)
          pool[p->poolOffset + i] =
              (vector_float4){cv[0].floatValue, cv[1].floatValue,
                              cv[2].floatValue, cv[3].floatValue};
        else if (p->hasDefColors && i < p->defColorCount) {
          const float *d = p->defColors[i];
          pool[p->poolOffset + i] = (vector_float4){d[0], d[1], d[2], d[3]};
        } else {
          const float *d = kShaderDefaultPalette[i % 10];
          pool[p->poolOffset + i] = (vector_float4){d[0], d[1], d[2], d[3]};
        }
      }
      pool[p->poolOffset + p->count] = (vector_float4){(float)cc, 0, 0, 0};
    } else {
      NSArray<NSNumber *> *cv = valuesForLabel(@(p->name));
      if (cv.count >= 4)
        pool[p->poolOffset] =
            (vector_float4){cv[0].floatValue, cv[1].floatValue,
                            cv[2].floatValue, cv[3].floatValue};
      else if (p->hasDefColors) {
        const float *d = p->defColors[0];
        pool[p->poolOffset] = (vector_float4){d[0], d[1], d[2], d[3]};
      } else {
        // Fall back to the SAME per-index palette colour the catalog seeds the
        // lane with (pal[pi % 10]); using pal[0] for every single colour made
        // an un-seeded first render collapse all colours to one (purple).
        const float *d = kShaderDefaultPalette[pi % 10];
        pool[p->poolOffset] = (vector_float4){d[0], d[1], d[2], d[3]};
      }
    }
  }
  return poolCount;
}

#endif // __METAL_VERSION__
