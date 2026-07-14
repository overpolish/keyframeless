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
#import <ctype.h>
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
        else {
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
      else {
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

// --- Scalar properties (`// #float`, `// #choice`) -----------------------
// Same declaration-annotated pattern as `// #color`, but for a `uniform float`
// (slider lane) or `uniform int` (choice-pill lane). Each occupies ONE vec4 in
// the pool (value in .x), appended AFTER the colour props so the colour path is
// unchanged. The transpiler folds them into the block with `#define <name>
// (<name>_kk.x)` (float) / `(int(<name>_kk.x))` (choice).
#define KK_SHADER_MAX_SCALAR_PROPS 12
typedef struct ShaderScalarProp {
  int isChoice;   // 0 = float slider, 1 = choice (int pills)
  int isPercent;  // float shown as % (0..100 lane); pool gets value / 100
  int isSeed;     // random-seed field (dice, integer, non-animatable)
  int isPoint;    // 2D point (vec2 uniform; xy of the pool vec4)
  int isBool;     // on/off checkbox (bool uniform; .x > 0.5)
  int isInt;      // integer slider (int uniform)
  int isAngle;    // rotation knob, degrees lane; uniform gets radians
  int hasMax;     // `max=` was specified (else the field is unbounded)
  char name[64];  // GLSL uniform name
  char label[80]; // display label
  int poolOffset; // vec4 index in the pool (value in .x, or xy for a point)
  double fmin, fmax,
      fdefault;        // float (percent: in 0..100); fmax = nominal when
                       // !hasMax (slider cap; the field is unbounded)
  double pdefx, pdefy; // point default (normalized 0..1)
  char options[256];   // choice: comma-separated pill labels
  int choiceCount;     // number of options
  int cdefault;        // choice default index
  // On-screen control opt-in (`osc` attribute). oscKind: "" = none, "point"
  // (position handle, #point), "ring"/"box" (radial-extent OSC editing the
  // normalized value as an ellipse ring or a rectangle box,
  // #float/#percent/#int/#multi), "scale", "rotate" (#angle osc).
  // oscAxis: 'x'/'y'/'z' ring plane for rotate (default 'z').
  char oscKind[16];
  char oscAxis;
  char uniformType[8]; // declared GLSL type: float/int/vec2/vec3/vec4/bool
  double rcenterx, rcentery; // ring OSC center, object space 0..1 (default 0.5)
  char linkName[64];     // ring OSC: `link=<uniform>` -> centre follows that
                         // #point's live value (empty = fixed `center=`)
  int isMulti;           // `#multi`: an N-component numeric field (vec2/vec3)
  int fieldCount;        // number of components (from fields={} / arity)
  char fieldLabels[256]; // comma-separated per-component field names
  int aspectLinked;      // `lockaspect` flag: components aspect-linkable (+
                         // locked by default) so an OSC drag keeps their ratio
  double mdef[4];        // per-component defaults (#multi)
} ShaderScalarProp;

/// A scalar prop editable by a radius ring: a bounded numeric slider (the
/// `#float`/`#percent`/`#int` family). Points, bools, choices, seeds and angles
/// have no 0..1 value to map onto a radius, so `osc=ring` on them is rejected.
static inline BOOL ShaderScalarRingEligible(const ShaderScalarProp *p) {
  return !p->isPoint && !p->isBool && !p->isChoice && !p->isSeed && !p->isAngle;
}

/// A radial-extent OSC: a draggable ring or box editing the value(s) normalized
/// 0..1. `osc=ring` (ellipse) and `osc=box` (rectangle) share EVERY behaviour -
/// value model, drag math, linking, `lockaspect`, opt-hide - and differ only in
/// the drawn/hit-tested outline. Callers that build the OSC treat them alike;
/// only the shape flag differs.
static inline BOOL ShaderScalarRadialOSC(const ShaderScalarProp *p) {
  return strcmp(p->oscKind, "ring") == 0 || strcmp(p->oscKind, "box") == 0;
}
static inline BOOL ShaderScalarOSCIsBox(const ShaderScalarProp *p) {
  return strcmp(p->oscKind, "box") == 0;
}

static inline double ShaderAttrDouble(NSString *s, NSString *pattern,
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

/// Parse every `// #float` / `// #choice` directive + its `uniform float|int
/// <name>;` (before the next directive), in source order. Pool offsets start at
/// `startOffset` (the colour pool count). Returns the count; `outUsed` = vec4s
/// used (one per prop).
static inline int ShaderParseScalarProps(NSString *source,
                                         ShaderScalarProp *props, int maxProps,
                                         int startOffset, int *outUsed) {
  int n = 0, pool = startOffset;
  if (outUsed)
    *outUsed = 0;
  if (!source.length || maxProps <= 0)
    return 0;
  NSRegularExpression *dirRe = [NSRegularExpression
      regularExpressionWithPattern:
          @"(?m)^[ \\t]*//[ "
          @"\\t]*#(float|percent|seed|point|int|angle|bool|choice|multi)\\b([^"
          @"\\n]*)$"
                           options:0
                             error:nil];
  NSRegularExpression *uniRe = [NSRegularExpression
      regularExpressionWithPattern:
          @"\\buniform\\s+(float|int|vec2|vec3|vec4|bool)\\s+(\\w+)\\s*;"
                           options:0
                             error:nil];
  NSArray<NSTextCheckingResult *> *dirs =
      [dirRe matchesInString:source
                     options:0
                       range:NSMakeRange(0, source.length)];
  for (int di = 0; di < (int)dirs.count && n < maxProps; di++) {
    if (pool + 1 > KK_SHADER_COLOR_POOL)
      break;
    NSTextCheckingResult *dm = dirs[di];
    NSString *kind = [source substringWithRange:[dm rangeAtIndex:1]];
    NSString *attrs = [source substringWithRange:[dm rangeAtIndex:2]];
    NSUInteger after = NSMaxRange(dm.range);
    NSUInteger limit = (di + 1 < (int)dirs.count) ? dirs[di + 1].range.location
                                                  : source.length;
    NSTextCheckingResult *um =
        [uniRe firstMatchInString:source
                          options:0
                            range:NSMakeRange(after, limit - after)];
    if (!um || [um rangeAtIndex:2].location == NSNotFound)
      continue;
    NSString *nm = [source substringWithRange:[um rangeAtIndex:2]];
    ShaderScalarProp p;
    memset(&p, 0, sizeof(p));
    p.isChoice = [kind isEqualToString:@"choice"];
    p.isPercent = [kind isEqualToString:@"percent"];
    p.isSeed = [kind isEqualToString:@"seed"];
    p.isPoint = [kind isEqualToString:@"point"];
    p.isBool = [kind isEqualToString:@"bool"];
    p.isInt = [kind isEqualToString:@"int"];
    p.isAngle = [kind isEqualToString:@"angle"];
    p.isMulti = [kind isEqualToString:@"multi"];
    strncpy(p.name, nm.UTF8String ?: "", sizeof(p.name) - 1);
    NSString *uty = [source substringWithRange:[um rangeAtIndex:1]];
    strncpy(p.uniformType, uty.UTF8String ?: "", sizeof(p.uniformType) - 1);
    p.rcenterx = 0.5;
    p.rcentery = 0.5;
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
    p.poolOffset = pool;
    // On-screen control opt-in: `osc` (bare) or `osc=<ring|scale>`. #point ->
    // position handle; #angle -> rotation ring (axis=x|y|z, default z); #float
    // -> ring or scale per the osc value.
    p.oscAxis = 'z';
    if ([[NSRegularExpression regularExpressionWithPattern:@"\\bosc\\b"
                                                   options:0
                                                     error:nil]
            firstMatchInString:attrs
                       options:0
                         range:NSMakeRange(0, attrs.length)]) {
      NSTextCheckingResult *ov = [[NSRegularExpression
          regularExpressionWithPattern:@"\\bosc\\s*=\\s*(\\w+)"
                               options:0
                                 error:nil]
          firstMatchInString:attrs
                     options:0
                       range:NSMakeRange(0, attrs.length)];
      NSString *val = (ov && [ov rangeAtIndex:1].location != NSNotFound)
                          ? [attrs substringWithRange:[ov rangeAtIndex:1]]
                          : nil;
      NSString *kindStr =
          val ? val.lowercaseString
              : (p.isPoint ? @"point" : (p.isAngle ? @"rotate" : @""));
      strncpy(p.oscKind, kindStr.UTF8String ?: "", sizeof(p.oscKind) - 1);
      NSTextCheckingResult *am = [[NSRegularExpression
          regularExpressionWithPattern:@"\\baxis\\s*=\\s*([xyzXYZ])"
                               options:0
                                 error:nil]
          firstMatchInString:attrs
                     options:0
                       range:NSMakeRange(0, attrs.length)];
      if (am && [am rangeAtIndex:1].location != NSNotFound)
        p.oscAxis = (char)tolower([[attrs
            substringWithRange:[am rangeAtIndex:1]] characterAtIndex:0]);
      // A radial OSC (ring or box) is placed at `center=x,y` (object space
      // 0..1) unless it is linked to a #point. Default is the clip centre.
      if (ShaderScalarRadialOSC(&p)) {
        NSTextCheckingResult *cm = [[NSRegularExpression
            regularExpressionWithPattern:
                @"\\bcenter\\s*=\\s*\"?(-?[0-9.]+)\\s*,\\s*(-?[0-9.]+)\"?"
                                 options:0
                                   error:nil]
            firstMatchInString:attrs
                       options:0
                         range:NSMakeRange(0, attrs.length)];
        if (cm && [cm rangeAtIndex:2].location != NSNotFound) {
          p.rcenterx =
              [attrs substringWithRange:[cm rangeAtIndex:1]].doubleValue;
          p.rcentery =
              [attrs substringWithRange:[cm rangeAtIndex:2]].doubleValue;
        }
        // `link=<uniform>`: the ring centre tracks that #point's live value
        // instead of the fixed `center=`.
        NSTextCheckingResult *lk = [[NSRegularExpression
            regularExpressionWithPattern:@"\\blink\\s*=\\s*(\\w+)"
                                 options:0
                                   error:nil]
            firstMatchInString:attrs
                       options:0
                         range:NSMakeRange(0, attrs.length)];
        if (lk && [lk rangeAtIndex:1].location != NSNotFound)
          strncpy(p.linkName,
                  [attrs substringWithRange:[lk rangeAtIndex:1]].UTF8String
                      ?: "",
                  sizeof(p.linkName) - 1);
      }
    }
    if (p.isChoice) {
      NSTextCheckingResult *om = [[NSRegularExpression
          regularExpressionWithPattern:@"\\boptions\\s*=\\s*\"([^\"]*)\""
                               options:0
                                 error:nil]
          firstMatchInString:attrs
                     options:0
                       range:NSMakeRange(0, attrs.length)];
      NSString *opts = (om && [om rangeAtIndex:1].location != NSNotFound)
                           ? [attrs substringWithRange:[om rangeAtIndex:1]]
                           : @"";
      strncpy(p.options, opts.UTF8String ?: "", sizeof(p.options) - 1);
      int cnt = opts.length ? 1 : 0;
      for (NSUInteger i = 0; i < opts.length; i++)
        if ([opts characterAtIndex:i] == ',')
          cnt++;
      p.choiceCount = cnt;
      int def = ShaderColorAttrInt(attrs, @"\\bdefault\\s*=\\s*(\\d+)", 0);
      if (def < 0)
        def = 0;
      if (cnt > 0 && def >= cnt)
        def = cnt - 1;
      p.cdefault = def;
    } else if (p.isSeed) {
      // A random seed: any integer, non-animatable, dice-rerolled. Passes
      // straight to the float uniform (no normalization).
      p.fmin = 0.0;
      p.fmax = 1000000.0;
      p.fdefault = ShaderColorAttrInt(attrs, @"\\bdefault\\s*=\\s*(\\d+)", 0);
    } else if (p.isBool) {
      p.fdefault =
          ShaderColorAttrInt(attrs, @"\\bdefault\\s*=\\s*(\\d+)", 0) ? 1 : 0;
    } else if (p.isAngle) {
      // Rotation knob, degrees; unconstrained (accumulates past 360).
      p.fdefault =
          ShaderAttrDouble(attrs, @"\\bdefault\\s*=\\s*(-?[0-9.]+)", 0);
    } else if (p.isPoint) {
      // A 2D point (vec2), normalized 0..1. Default center, or default="x,y".
      p.pdefx = 0.5;
      p.pdefy = 0.5;
      NSTextCheckingResult *pm = [[NSRegularExpression
          regularExpressionWithPattern:@"\\bdefault\\s*=\\s*\"([^\"]*)\""
                               options:0
                                 error:nil]
          firstMatchInString:attrs
                     options:0
                       range:NSMakeRange(0, attrs.length)];
      if (pm && [pm rangeAtIndex:1].location != NSNotFound) {
        NSArray<NSString *> *xy =
            [[attrs substringWithRange:[pm rangeAtIndex:1]]
                componentsSeparatedByString:@","];
        if (xy.count >= 2) {
          p.pdefx = xy[0].doubleValue;
          p.pdefy = xy[1].doubleValue;
        }
      }
    } else if (p.isMulti) {
      // An N-component numeric field (vec2/vec3). Component count from
      // `fields={A,B}` (which also names the components), else the uniform
      // arity.
      int arity = (strcmp(p.uniformType, "vec3") == 0)   ? 3
                  : (strcmp(p.uniformType, "vec4") == 0) ? 4
                  : (strcmp(p.uniformType, "vec2") == 0) ? 2
                                                         : 0;
      NSTextCheckingResult *fm = [[NSRegularExpression
          regularExpressionWithPattern:@"\\bfields\\s*=\\s*\\{([^}]*)\\}"
                               options:0
                                 error:nil]
          firstMatchInString:attrs
                     options:0
                       range:NSMakeRange(0, attrs.length)];
      NSString *fieldsStr = (fm && [fm rangeAtIndex:1].location != NSNotFound)
                                ? [attrs substringWithRange:[fm rangeAtIndex:1]]
                                : @"";
      strncpy(p.fieldLabels, fieldsStr.UTF8String ?: "",
              sizeof(p.fieldLabels) - 1);
      int cnt = 0;
      if (fieldsStr.length) {
        cnt = 1;
        for (NSUInteger i = 0; i < fieldsStr.length; i++)
          if ([fieldsStr characterAtIndex:i] == ',')
            cnt++;
      }
      p.fieldCount = cnt > 0 ? cnt : (arity > 0 ? arity : 2);
      p.aspectLinked =
          ([[NSRegularExpression
               regularExpressionWithPattern:@"\\blockaspect\\b"
                                    options:0
                                      error:nil]
               firstMatchInString:attrs
                          options:0
                            range:NSMakeRange(0, attrs.length)] != nil)
              ? 1
              : 0;
      double mn = ShaderAttrDouble(attrs, @"\\bmin\\s*=\\s*(-?[0-9.]+)", 0.0);
      double mx = ShaderAttrDouble(attrs, @"\\bmax\\s*=\\s*(-?[0-9.]+)", NAN);
      p.hasMax = !isnan(mx);
      if (!p.hasMax)
        mx = 1.0; // nominal range (the field stays unbounded)
      if (mx < mn)
        mx = mn;
      p.fmin = mn;
      p.fmax = mx;
      for (int k = 0; k < 4; k++)
        p.mdef[k] = mn;
      NSTextCheckingResult *dm = [[NSRegularExpression
          regularExpressionWithPattern:
              @"\\bdefault\\s*=\\s*\"?([-0-9.]+(?:\\s*,\\s*[-0-9.]+)*)\"?"
                               options:0
                                 error:nil]
          firstMatchInString:attrs
                     options:0
                       range:NSMakeRange(0, attrs.length)];
      if (dm && [dm rangeAtIndex:1].location != NSNotFound) {
        NSArray<NSString *> *parts =
            [[attrs substringWithRange:[dm rangeAtIndex:1]]
                componentsSeparatedByString:@","];
        for (int k = 0; k < 4; k++) {
          if (k < (int)parts.count)
            p.mdef[k] = parts[k].doubleValue;
          else if (parts.count == 1)
            p.mdef[k] =
                parts[0].doubleValue; // single default -> all components
        }
      }
    } else {
      double defMax = p.isPercent ? 100.0 : (p.isInt ? 10.0 : 1.0);
      double mn = ShaderAttrDouble(attrs, @"\\bmin\\s*=\\s*(-?[0-9.]+)", 0.0);
      double mx = ShaderAttrDouble(attrs, @"\\bmax\\s*=\\s*(-?[0-9.]+)", NAN);
      p.hasMax = !isnan(mx);
      if (!p.hasMax)
        mx = defMax; // nominal slider cap; the field stays unbounded
      double df =
          ShaderAttrDouble(attrs, @"\\bdefault\\s*=\\s*(-?[0-9.]+)", mn);
      if (mx < mn)
        mx = mn;
      if (df < mn)
        df = mn;
      if (df > mx)
        df = mx;
      p.fmin = mn;
      p.fmax = mx;
      p.fdefault = df;
    }
    props[n++] = p;
    pool += 1;
  }
  if (outUsed)
    *outUsed = pool - startOffset;
  return n;
}

/// Fill the scalar props into the pool (each = one vec4, value in .x), starting
/// at `startOffset` (the colour pool count). Returns the new total vec4 count.
static inline int
ShaderFillScalarPool(NSString *source, vector_float4 *pool, int startOffset,
                     NSArray<NSNumber *> * (^valuesForLabel)(NSString *)) {
  ShaderScalarProp props[KK_SHADER_MAX_SCALAR_PROPS];
  int used = 0;
  int nProps = ShaderParseScalarProps(source, props, KK_SHADER_MAX_SCALAR_PROPS,
                                      startOffset, &used);
  for (int pi = 0; pi < nProps; pi++) {
    ShaderScalarProp *p = &props[pi];
    // Look up by the uniform NAME (the lane identity), not the display label.
    NSArray<NSNumber *> *v = valuesForLabel(@(p->name));
    if (p->isPoint) {
      double x = v.count >= 1 ? v[0].doubleValue : p->pdefx;
      double y = v.count >= 2 ? v[1].doubleValue : p->pdefy;
      pool[p->poolOffset] = (vector_float4){(float)x, (float)y, 0, 0};
      continue;
    }
    if (p->isMulti) {
      // N components packed into .xyz (one pool vec4). Missing components fall
      // back to the per-component default.
      float c[4] = {0, 0, 0, 0};
      for (int k = 0; k < p->fieldCount && k < 4; k++)
        c[k] = (float)(v.count > k ? v[k].doubleValue : p->mdef[k]);
      pool[p->poolOffset] = (vector_float4){c[0], c[1], c[2], c[3]};
      continue;
    }
    double val = v.count ? v[0].doubleValue
                         : (p->isChoice ? (double)p->cdefault : p->fdefault);
    if (p->isPercent)
      val /= 100.0; // lane is 0..100 %, shader wants 0..1
    pool[p->poolOffset] = (vector_float4){(float)val, 0, 0, 0};
  }
  return startOffset + used;
}

/// The first control label used by more than one directive (colour or scalar),
/// or nil when all are unique. The label is the lane identity (values, OSC,
/// pool fill all key on it), so a duplicate is a compile error - the editor
/// surfaces this rather than silently merging two controls into one.
static inline NSString *ShaderFirstDuplicateLabel(NSString *source) {
  if (!source.length)
    return nil;
  NSMutableSet<NSString *> *seen = [NSMutableSet set];
  ShaderColorProp cp[KK_SHADER_MAX_COLOR_PROPS];
  int cpool = 0;
  int nc = ShaderParseColorProps(source, cp, KK_SHADER_MAX_COLOR_PROPS, &cpool);
  for (int i = 0; i < nc; i++) {
    NSString *l = @(cp[i].label);
    if ([seen containsObject:l])
      return l;
    [seen addObject:l];
  }
  ShaderScalarProp sp[KK_SHADER_MAX_SCALAR_PROPS];
  int used = 0;
  int ns =
      ShaderParseScalarProps(source, sp, KK_SHADER_MAX_SCALAR_PROPS, 0, &used);
  for (int i = 0; i < ns; i++) {
    NSString *l = @(sp[i].label);
    if ([seen containsObject:l])
      return l;
    [seen addObject:l];
  }
  return nil;
}

/// The first uniform NAME declared by more than one directive, or nil when all
/// are unique. Two same-named uniforms produce two identically-named block
/// members (`<name>_kk`) and a cryptic glslang "duplicate member name" - catch
/// it here for a clear editor error instead.
static inline NSString *ShaderFirstDuplicateUniform(NSString *source) {
  if (!source.length)
    return nil;
  NSMutableSet<NSString *> *seen = [NSMutableSet set];
  ShaderColorProp cp[KK_SHADER_MAX_COLOR_PROPS];
  int cpool = 0;
  int nc = ShaderParseColorProps(source, cp, KK_SHADER_MAX_COLOR_PROPS, &cpool);
  for (int i = 0; i < nc; i++) {
    NSString *nm = @(cp[i].name);
    if ([seen containsObject:nm])
      return nm;
    [seen addObject:nm];
  }
  ShaderScalarProp sp[KK_SHADER_MAX_SCALAR_PROPS];
  int used = 0;
  int ns =
      ShaderParseScalarProps(source, sp, KK_SHADER_MAX_SCALAR_PROPS, 0, &used);
  for (int i = 0; i < ns; i++) {
    NSString *nm = @(sp[i].name);
    if ([seen containsObject:nm])
      return nm;
    [seen addObject:nm];
  }
  return nil;
}

/// The first directive whose `osc` kind is incompatible with its uniform type,
/// or nil when every OSC opt-in is valid. `osc=point` needs a `vec2`;
/// `osc=ring` needs a single-value numeric slider (`float`/`int`, i.e.
/// #float/#percent/#int)
/// - a radius has no meaning for a vec2/vec3/vec4, a bool, a choice or a seed.
/// `outIsRing` distinguishes the two cases so the caller picks the right
/// message.
static inline NSString *ShaderFirstInvalidOSC(NSString *source,
                                              BOOL *outIsRing) {
  if (!source.length)
    return nil;
  ShaderScalarProp sp[KK_SHADER_MAX_SCALAR_PROPS];
  int used = 0;
  int ns =
      ShaderParseScalarProps(source, sp, KK_SHADER_MAX_SCALAR_PROPS, 0, &used);
  for (int i = 0; i < ns; i++) {
    if (strcmp(sp[i].oscKind, "point") == 0 &&
        strcmp(sp[i].uniformType, "vec2") != 0) {
      if (outIsRing)
        *outIsRing = NO;
      return @(sp[i].name);
    }
    if (ShaderScalarRadialOSC(&sp[i])) {
      BOOL scalarOK = strcmp(sp[i].uniformType, "float") == 0 ||
                      strcmp(sp[i].uniformType, "int") == 0;
      BOOL multiOK = sp[i].isMulti && strcmp(sp[i].uniformType, "vec2") == 0;
      if (!ShaderScalarRingEligible(&sp[i]) || !(scalarOK || multiOK)) {
        if (outIsRing)
          *outIsRing = YES;
        return @(sp[i].name);
      }
    }
  }
  return nil;
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
