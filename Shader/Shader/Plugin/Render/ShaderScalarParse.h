/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Reading `// #float` / `#choice` / `#point` / ... declarations out of shader
// source into ShaderScalarProps, and filling the render pool from them.
#pragma once

#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>
#import <ctype.h>
#import <math.h>
#import <string.h>

#import "ShaderScalarOSC.h"
#import "ShaderScalarProps.h"
#import "ShaderTypes.h"

static inline void ShaderScalarParseDefaults(NSString *attrs,
                                             ShaderScalarProp *p) {
  if (p->isChoice) {
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
    strncpy(p->options, opts.UTF8String ?: "", sizeof(p->options) - 1);
    int cnt = opts.length ? 1 : 0;
    for (NSUInteger i = 0; i < opts.length; i++)
      if ([opts characterAtIndex:i] == ',')
        cnt++;
    p->choiceCount = cnt;
    // `dropdown`: a searchable list instead of pills. Opt-in rather than a
    // count threshold, because only the author knows whether their options are
    // worth showing all at once - and a set that silently changed shape at the
    // 6th option would be worse than either.
    p->choiceDropdown =
        ([[NSRegularExpression regularExpressionWithPattern:@"\\bdropdown\\b"
                                                    options:0
                                                      error:nil]
             firstMatchInString:attrs
                        options:0
                          range:NSMakeRange(0, attrs.length)] != nil)
            ? 1
            : 0;
    int def = ShaderAttrInt(attrs, @"\\bdefault\\s*=\\s*(\\d+)", 0);
    if (def < 0)
      def = 0;
    if (cnt > 0 && def >= cnt)
      def = cnt - 1;
    p->cdefault = def;
  } else if (p->isSeed) {
    // A random seed: any integer, non-animatable, dice-rerolled. Passes
    // straight to the float uniform (no normalization).
    p->fmin = 0.0;
    p->fmax = 1000000.0;
    p->fdefault = ShaderAttrInt(attrs, @"\\bdefault\\s*=\\s*(\\d+)", 0);
  } else if (p->isBool) {
    p->fdefault = ShaderAttrInt(attrs, @"\\bdefault\\s*=\\s*(\\d+)", 0) ? 1 : 0;
  } else if (p->isAngle) {
    // Rotation knob, degrees; unconstrained (accumulates past 360).
    p->fdefault = ShaderAttrDouble(attrs, @"\\bdefault\\s*=\\s*(-?[0-9.]+)", 0);
  } else if (p->isPoint) {
    // A 2D point (vec2), normalized 0..1. Default center, or default="x,y".
    p->pdefx = 0.5;
    p->pdefy = 0.5;
    NSTextCheckingResult *pm = [[NSRegularExpression
        regularExpressionWithPattern:@"\\bdefault\\s*=\\s*\"([^\"]*)\""
                             options:0
                               error:nil]
        firstMatchInString:attrs
                   options:0
                     range:NSMakeRange(0, attrs.length)];
    if (pm && [pm rangeAtIndex:1].location != NSNotFound) {
      NSArray<NSString *> *xy = [[attrs substringWithRange:[pm rangeAtIndex:1]]
          componentsSeparatedByString:@","];
      if (xy.count >= 2) {
        p->pdefx = xy[0].doubleValue;
        p->pdefy = xy[1].doubleValue;
      }
    }
  } else if (p->isMulti) {
    // An N-component numeric field (vec2/vec3). Component count from
    // `fields={A,B}` (which also names the components), else the uniform
    // arity.
    int arity = (strcmp(p->uniformType, "vec3") == 0)   ? 3
                : (strcmp(p->uniformType, "vec4") == 0) ? 4
                : (strcmp(p->uniformType, "vec2") == 0) ? 2
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
    strncpy(p->fieldLabels, fieldsStr.UTF8String ?: "",
            sizeof(p->fieldLabels) - 1);
    int cnt = 0;
    if (fieldsStr.length) {
      cnt = 1;
      for (NSUInteger i = 0; i < fieldsStr.length; i++)
        if ([fieldsStr characterAtIndex:i] == ',')
          cnt++;
    }
    p->fieldCount = cnt > 0 ? cnt : (arity > 0 ? arity : 2);
    p->aspectLinked =
        ([[NSRegularExpression regularExpressionWithPattern:@"\\blockaspect\\b"
                                                    options:0
                                                      error:nil]
             firstMatchInString:attrs
                        options:0
                          range:NSMakeRange(0, attrs.length)] != nil)
            ? 1
            : 0;
    double mn = ShaderAttrDouble(attrs, @"\\bmin\\s*=\\s*(-?[0-9.]+)", 0.0);
    double mx = ShaderAttrDouble(attrs, @"\\bmax\\s*=\\s*(-?[0-9.]+)", NAN);
    p->hasMax = !isnan(mx);
    if (!p->hasMax)
      mx = 1.0; // nominal range (the field stays unbounded)
    if (mx < mn)
      mx = mn;
    p->fmin = mn;
    p->fmax = mx;
    for (int k = 0; k < 4; k++)
      p->mdef[k] = mn;
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
          p->mdef[k] = parts[k].doubleValue;
        else if (parts.count == 1)
          p->mdef[k] = parts[0].doubleValue; // single default -> all components
      }
    }
  } else {
    double defMax = p->isPercent ? 100.0 : (p->isInt ? 10.0 : 1.0);
    double mn = ShaderAttrDouble(attrs, @"\\bmin\\s*=\\s*(-?[0-9.]+)", 0.0);
    double mx = ShaderAttrDouble(attrs, @"\\bmax\\s*=\\s*(-?[0-9.]+)", NAN);
    p->hasMax = !isnan(mx);
    if (!p->hasMax)
      mx = defMax; // nominal slider cap; the field stays unbounded
    if (p->isProgress) {
      // 0..100% is what progress MEANS, so it's a bounded field rather than an
      // open one with a nominal cap. min=/max= aren't honoured here on purpose.
      mn = 0.0;
      mx = 100.0;
      p->hasMax = 1;
    }
    double df = ShaderAttrDouble(attrs, @"\\bdefault\\s*=\\s*(-?[0-9.]+)", mn);
    if (mx < mn)
      mx = mn;
    if (df < mn)
      df = mn;
    if (df > mx)
      df = mx;
    p->fmin = mn;
    p->fmax = mx;
    p->fdefault = df;
  }
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
          @"\\t]*#(float|percent|progress|seed|point|int|angle|bool|choice|"
          @"multi)\\b([^"
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
    p.isProgress = [kind isEqualToString:@"progress"];
    // Everything about progress except its ramp default is a percent field
    // (0..100 lane shown as %, pool gets value / 100), so reuse that path.
    p.isPercent = [kind isEqualToString:@"percent"] || p.isProgress;
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
            : ShaderPrettifyUniformName(nm);
    strncpy(p.label, label.UTF8String ?: "", sizeof(p.label) - 1);
    p.poolOffset = pool;
    ShaderScalarParseOSC(attrs, &p);
    ShaderScalarParseDefaults(attrs, &p);
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

#endif // __METAL_VERSION__
