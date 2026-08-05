/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// `// #gradient` directives: a multi-stop colour ramp the shader samples by
// position. The shader never indexes the declared array - the transpiler emits
// a `<name>At(float t)` sampler over it, so how the stops are packed stays an
// implementation detail.
#pragma once

#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>
#import <ctype.h>
#import <math.h>
#import <string.h>

#import "MirageColorProps.h" // MirageParseHexColor
#import "MirageDirectiveCommon.h"
#import "MirageTypes.h"

/// Stop capacity of one `// #gradient`. The editor adds and removes stops
/// freely, so this is what the pool RESERVES, not a count the author picks.
#define KK_SHADER_MAX_GRADIENT_STOPS 16
#define KK_SHADER_MAX_GRADIENT_PROPS 4

/// Components per stop in the lane's flat value (KKLaneValueTypeGradient with
/// gradientShowsTypeAngle = NO): position, r, g, b, midpoint.
#define KK_GRADIENT_STOP_STRIDE 5

/// One `// #gradient`-annotated ramp a shader declares. `maxStops` is the GLSL
/// array dimension - the ceiling the lane editor can grow to. `label` is the
/// display name (from label= or the prettified variable name).
typedef struct MirageGradientProp {
  char name[64];  // GLSL uniform name (e.g. "uRamp")
  char label[80]; // display label ("Ramp")
  int maxStops;   // array dimension N, 2..KK_SHADER_MAX_GRADIENT_STOPS
  int poolOffset; // first vec4 index in the pool (see KK_SHADER_COLOR_POOL)
  // Author-supplied stops from `default="#hex@pos,..."`, in the SAME flat
  // layout the lane stores (position, r, g, b, midpoint). When hasDefStops is
  // 0 a black -> white ramp is used, matching KKDefaultGradientJSON. These seed
  // the lane AND are what Reset reverts to, so a shader's intended ramp lives
  // in its source.
  int hasDefStops;
  int defStopCount;
  float defStops[KK_SHADER_MAX_GRADIENT_STOPS][KK_GRADIENT_STOP_STRIDE];
} MirageGradientProp;

/// vec4s one gradient occupies: the stop array (rgb in .xyz, position in .w),
/// the midpoints packed 4 per vec4, and a count-meta vec4. A std140 float array
/// pads to a 16-byte stride, so packing the midpoints costs a quarter of what
/// declaring them individually would.
static inline int MirageGradientSlots(int maxStops) {
  return maxStops + ((maxStops + 3) / 4) + 1;
}

/// Write the built-in black -> white ramp into `stops`. Returns the count.
static inline int
MirageGradientDefaultStops(float stops[][KK_GRADIENT_STOP_STRIDE]) {
  const float seed[2][KK_GRADIENT_STOP_STRIDE] = {
      {0.0f, 0.0f, 0.0f, 0.0f, 0.5f},
      {1.0f, 1.0f, 1.0f, 1.0f, 0.5f},
  };
  memcpy(stops, seed, sizeof(seed));
  return 2;
}

/// Parse a `default="#hex@pos,#hex,..."` attribute into up to `maxN` stops.
/// The `@pos` suffix is optional; stops that omit it are spread evenly across
/// 0..1. Midpoints are always centred (the editor is where you shape a
/// segment's falloff - a directive that could set it would be a fourth number
/// nobody reads). Returns the number parsed, 0 when the attribute is absent or
/// its first token isn't a colour.
static inline int
MirageParseGradientDefaults(NSString *attrs,
                            float stops[][KK_GRADIENT_STOP_STRIDE], int maxN) {
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
  // Which stops stated a position, so the rest can be spread between them.
  BOOL placed[KK_SHADER_MAX_GRADIENT_STOPS];
  memset(placed, 0, sizeof(placed));
  for (NSString *rawTok in toks) {
    if (n >= maxN)
      break;
    NSString *tok =
        [rawTok stringByTrimmingCharactersInSet:[NSCharacterSet
                                                    whitespaceCharacterSet]];
    NSRange at = [tok rangeOfString:@"@"];
    NSString *hex =
        at.location == NSNotFound ? tok : [tok substringToIndex:at.location];
    float c[4];
    if (!MirageParseHexColor(hex, c))
      break;
    stops[n][1] = c[0];
    stops[n][2] = c[1];
    stops[n][3] = c[2];
    stops[n][4] = 0.5f;
    if (at.location != NSNotFound) {
      double p = [tok substringFromIndex:at.location + 1].doubleValue;
      stops[n][0] = (float)fmax(0.0, fmin(1.0, p));
      placed[n] = YES;
    }
    n++;
  }
  if (n < 2)
    return 0; // a one-stop ramp isn't a gradient
  // Spread every unplaced stop evenly across the run it sits in, so
  // `default="#000,#f00,#fff"` lands on 0 / 0.5 / 1 and a partly-placed list
  // still fills the gaps between the positions it did state.
  if (!placed[0]) {
    stops[0][0] = 0.0f;
    placed[0] = YES;
  }
  if (!placed[n - 1]) {
    stops[n - 1][0] = 1.0f;
    placed[n - 1] = YES;
  }
  for (int i = 0; i < n; i++) {
    if (placed[i])
      continue;
    int lo = i - 1; // always placed: index 0 is pinned above
    int hi = i;
    while (hi < n && !placed[hi])
      hi++;
    float span = stops[hi][0] - stops[lo][0];
    for (int k = lo + 1; k < hi; k++)
      stops[k][0] = stops[lo][0] + span * (float)(k - lo) / (float)(hi - lo);
    i = hi - 1;
  }
  return n;
}

/// Parse every `// #gradient [label=] [default=]` directive and the
/// `uniform vec4 <name>[N];` declaration that follows it (before the next
/// directive). Fills `props` in directive order with pool offsets starting at
/// `base`; returns the count and (via outPoolCount) the vec4s the gradient
/// block tail needs.
static inline int MirageParseGradientProps(NSString *source,
                                           MirageGradientProp *props,
                                           int maxProps, int base,
                                           int *outPoolCount) {
  if (outPoolCount)
    *outPoolCount = 0;
  int n = 0, pool = 0;
  if (!source.length || maxProps <= 0)
    return 0;
  NSRegularExpression *dirRe = [NSRegularExpression
      regularExpressionWithPattern:
          @"(?m)^[ \\t]*//[ \\t]*#gradient(?![-\\w:])([^\\n]*)$"
                           options:0
                             error:nil];
  NSRegularExpression *uniRe = [NSRegularExpression
      regularExpressionWithPattern:
          @"\\buniform\\s+vec4\\s+(\\w+)\\s*\\[\\s*(\\d+)\\s*\\]\\s*;"
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
    int N = [source substringWithRange:[um rangeAtIndex:2]].intValue;
    if (N < 2)
      N = 2;
    if (N > KK_SHADER_MAX_GRADIENT_STOPS)
      N = KK_SHADER_MAX_GRADIENT_STOPS;
    int slots = MirageGradientSlots(N);
    if (base + pool + slots > KK_SHADER_COLOR_POOL)
      break; // pool full - drop the rest

    MirageGradientProp p;
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
            : MiragePrettifyUniformName(nm);
    strncpy(p.label, label.UTF8String ?: "", sizeof(p.label) - 1);
    p.maxStops = N;
    p.poolOffset = base + pool;
    int nds = MirageParseGradientDefaults(attrs, p.defStops, N);
    if (nds > 0) {
      p.hasDefStops = 1;
      p.defStopCount = nds;
    } else {
      p.defStopCount = MirageGradientDefaultStops(p.defStops);
    }
    props[n++] = p;
    pool += slots;
  }
  if (outPoolCount)
    *outPoolCount = pool;
  return n;
}

#endif // __METAL_VERSION__
