/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Reading `// #float` / `#choice` / `#point` / ... declarations out of shader
// source into MirageScalarProps, and filling the render pool from them.
#pragma once

#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>
#import <ctype.h>
#import <math.h>
#import <string.h>

#import "MirageScalarOSC.h"
#import "MirageScalarProps.h"
#import "MirageSlots.h"
#import "MirageTypes.h"

// Parse a braced per-field list `key={a,b,c,d}` into out[4]/has[4]. Partial
// lists and empty slots are allowed: `{,,3,4}` sets only slots 2 and 3. A slot
// with no number leaves has[k]=0 (fall back to the scalar attr / unbounded).
// The attr being absent leaves every has[k]=0.
static inline void MirageParseBracedFields(NSString *attrs, NSString *key,
                                           double out[4], int has[4]) {
  for (int k = 0; k < 4; k++) {
    out[k] = 0.0;
    has[k] = 0;
  }
  NSString *pat =
      [NSString stringWithFormat:@"\\b%@\\s*=\\s*\\{([^}]*)\\}", key];
  NSTextCheckingResult *m =
      [[NSRegularExpression regularExpressionWithPattern:pat
                                                 options:0
                                                   error:nil]
          firstMatchInString:attrs
                     options:0
                       range:NSMakeRange(0, attrs.length)];
  if (!m || [m rangeAtIndex:1].location == NSNotFound)
    return;
  NSArray<NSString *> *parts = [[attrs substringWithRange:[m rangeAtIndex:1]]
      componentsSeparatedByString:@","];
  for (int k = 0; k < 4 && k < (int)parts.count; k++) {
    NSString *t = [parts[k]
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (t.length == 0)
      continue;
    NSScanner *sc = [NSScanner scannerWithString:t];
    double v = 0.0;
    if ([sc scanDouble:&v] && sc.atEnd) {
      out[k] = v;
      has[k] = 1;
    }
  }
}

// Parse the scalar reactive-cap pair:
//   maxby=uLayout maxvalues={4,6,9}
// The controller is a uniform identity (not its display label). Values are
// deliberately kept in authored lane units: the KKLane constants UI owns the
// reactive display clamp, while the shader can still defensively clamp its
// effective value without mutating stored/keyframed data.
static inline void MirageScalarParseDynamicMax(NSString *attrs,
                                               MirageScalarProp *p) {
  NSTextCheckingResult *controller = [[NSRegularExpression
      regularExpressionWithPattern:@"\\bmaxby\\s*=\\s*([A-Za-z_]\\w*)"
                           options:0
                             error:nil]
      firstMatchInString:attrs
                 options:0
                   range:NSMakeRange(0, attrs.length)];
  if (controller && [controller rangeAtIndex:1].location != NSNotFound) {
    NSString *name = [attrs substringWithRange:[controller rangeAtIndex:1]];
    strncpy(p->maxByName, name.UTF8String ?: "", sizeof(p->maxByName) - 1);
  }

  NSTextCheckingResult *values = [[NSRegularExpression
      regularExpressionWithPattern:@"\\bmaxvalues\\s*=\\s*\\{([^}]*)\\}"
                           options:0
                             error:nil]
      firstMatchInString:attrs
                 options:0
                   range:NSMakeRange(0, attrs.length)];
  if (!values || [values rangeAtIndex:1].location == NSNotFound)
    return;

  NSArray<NSString *> *parts =
      [[attrs substringWithRange:[values rangeAtIndex:1]]
          componentsSeparatedByString:@","];
  for (NSString *part in parts) {
    if (p->maxByValueCount >= KK_SHADER_MAX_DYNAMIC_MAX_VALUES)
      break;
    NSString *token = [part
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!token.length)
      continue;
    NSScanner *scanner = [NSScanner scannerWithString:token];
    double value = 0.0;
    if ([scanner scanDouble:&value] && scanner.atEnd)
      p->maxByValues[p->maxByValueCount++] = value;
  }
}

static inline void MirageScalarParseVisibility(NSString *attrs,
                                               MirageScalarProp *p) {
  NSTextCheckingResult *controller = [[NSRegularExpression
      regularExpressionWithPattern:@"\\bvisibleby\\s*=\\s*([A-Za-z_]\\w*)"
                           options:0
                             error:nil]
      firstMatchInString:attrs
                 options:0
                   range:NSMakeRange(0, attrs.length)];
  if (controller && [controller rangeAtIndex:1].location != NSNotFound) {
    NSString *name = [attrs substringWithRange:[controller rangeAtIndex:1]];
    strncpy(p->visibleByName, name.UTF8String ?: "",
            sizeof(p->visibleByName) - 1);
  }

  NSTextCheckingResult *values = [[NSRegularExpression
      regularExpressionWithPattern:@"\\bvisiblevalues\\s*=\\s*\\{([^}]*)\\}"
                           options:0
                             error:nil]
      firstMatchInString:attrs
                 options:0
                   range:NSMakeRange(0, attrs.length)];
  if (!values || [values rangeAtIndex:1].location == NSNotFound)
    return;

  NSArray<NSString *> *parts =
      [[attrs substringWithRange:[values rangeAtIndex:1]]
          componentsSeparatedByString:@","];
  for (NSString *part in parts) {
    if (p->visibleByValueCount >= KK_SHADER_MAX_VISIBILITY_VALUES)
      break;
    NSString *token = [part
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
    if (!token.length)
      continue;
    NSScanner *scanner = [NSScanner scannerWithString:token];
    double value = 0.0;
    if ([scanner scanDouble:&value] && scanner.atEnd)
      p->visibleByValues[p->visibleByValueCount++] = value;
  }
}

static inline void MirageScalarParseDefaults(NSString *attrs,
                                             MirageScalarProp *p) {
  switch (p->kind) {
  case MirageScalarKindChoice: {
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
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    for (NSString *part in [opts componentsSeparatedByString:@","]) {
      NSString *label =
          [part stringByTrimmingCharactersInSet:NSCharacterSet
                                                    .whitespaceCharacterSet];
      if (label.length)
        [labels addObject:label];
    }
    int cnt = (int)labels.count;
    p->choiceCount = cnt;
    // `dropdown`: a searchable list instead of pills. Opt-in rather than a
    // count threshold, because only the author knows whether their options are
    // worth showing all at once - and a set that silently changed shape at the
    // 6th option would be worse than either.
    p->choiceDropdown = MirageAttrHasBareFlag(attrs, @"dropdown") ? 1 : 0;
    p->choiceMultiple = MirageAttrHasBareFlag(attrs, @"multiple") ? 1 : 0;

    int def = 0;
    if (p->choiceMultiple) {
      NSTextCheckingResult *dm = [[NSRegularExpression
          regularExpressionWithPattern:@"\\bdefault\\s*=\\s*\"([^\"]*)\""
                               options:0
                                 error:nil]
          firstMatchInString:attrs
                     options:0
                       range:NSMakeRange(0, attrs.length)];
      if (dm && [dm rangeAtIndex:1].location != NSNotFound) {
        NSArray<NSString *> *selected =
            [[attrs substringWithRange:[dm rangeAtIndex:1]]
                componentsSeparatedByString:@","];
        for (NSString *pick in selected) {
          NSString *wanted = [pick
              stringByTrimmingCharactersInSet:NSCharacterSet
                                                  .whitespaceCharacterSet];
          for (NSInteger i = 0; i < (NSInteger)labels.count &&
                                i < KK_SHADER_MAX_MULTIPLE_CHOICE_OPTIONS;
               i++) {
            NSString *candidate = labels[i];
            if ([candidate isEqualToString:wanted]) {
              def |= 1 << i;
              break;
            }
          }
        }
      } else {
        def = MirageAttrInt(attrs, @"\\bdefault\\s*=\\s*(\\d+)", 0);
        int validMask = cnt <= 0 ? 0
                                 : (cnt >= KK_SHADER_MAX_MULTIPLE_CHOICE_OPTIONS
                                        ? 0x00FFFFFF
                                        : ((1 << cnt) - 1));
        def &= validMask;
      }
    } else {
      def = MirageAttrInt(attrs, @"\\bdefault\\s*=\\s*(\\d+)", 0);
      if (def < 0)
        def = 0;
      if (cnt > 0 && def >= cnt)
        def = cnt - 1;
    }
    p->cdefault = def;
    break;
  }
  case MirageScalarKindRandom: {
    // A random seed: any integer, non-animatable, dice-rerolled. Passes
    // straight to the float uniform (no normalization).
    p->fmin = 0.0;
    p->fmax = 1000000.0;
    p->fdefault = MirageAttrInt(attrs, @"\\bdefault\\s*=\\s*(\\d+)", 0);
    break;
  }
  case MirageScalarKindBool: {
    p->fdefault = MirageAttrInt(attrs, @"\\bdefault\\s*=\\s*(\\d+)", 0) ? 1 : 0;
    break;
  }
  case MirageScalarKindAngle: {
    // Rotation knob, degrees; unconstrained (accumulates past 360).
    p->fdefault = MirageAttrDouble(attrs, @"\\bdefault\\s*=\\s*(-?[0-9.]+)", 0);
    break;
  }
  case MirageScalarKindPoint: {
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
    break;
  }
  case MirageScalarKindMulti: {
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
    // Hard-capped at 4: every per-field array on the prop (mmin / mmax / mdef
    // / fieldUnit) is [4] and the widest uniform is a vec4, so a longer
    // `fields={}` would have the lane builder read past the end of all of
    // them. Validation reports it; this keeps the parse in bounds either way.
    p->fieldCount = cnt > 0 ? cnt : (arity > 0 ? arity : 2);
    if (p->fieldCount > 4)
      p->fieldCount = 4;
    p->aspectLinked =
        ([[NSRegularExpression regularExpressionWithPattern:@"\\blockaspect\\b"
                                                    options:0
                                                      error:nil]
             firstMatchInString:attrs
                        options:0
                          range:NSMakeRange(0, attrs.length)] != nil)
            ? 1
            : 0;
    double mn = MirageAttrDouble(attrs, @"\\bmin\\s*=\\s*(-?[0-9.]+)", NAN);
    double mx = MirageAttrDouble(attrs, @"\\bmax\\s*=\\s*(-?[0-9.]+)", NAN);
    p->hasMin = !isnan(mn);
    p->hasMax = !isnan(mx);
    if (!p->hasMin)
      mn = 0.0; // nominal slider floor; the field is unbounded below
    if (!p->hasMax)
      mx = p->isPercent ? 100.0 : 1.0; // percent implies 0..100; else nominal
    if (mx < mn)
      mx = mn;
    p->fmin = mn;
    p->fmax = mx;
    // Per-field `min={...}` / `max={...}` override the scalar min=/max= per
    // component; an empty slot keeps the scalar value (or stays unbounded).
    double pfMin[4], pfMax[4];
    int pfHasMin[4], pfHasMax[4];
    MirageParseBracedFields(attrs, @"min", pfMin, pfHasMin);
    MirageParseBracedFields(attrs, @"max", pfMax, pfHasMax);
    for (int k = 0; k < 4; k++) {
      p->mhasMin[k] = pfHasMin[k] || p->hasMin;
      p->mmin[k] = pfHasMin[k] ? pfMin[k] : mn;
      p->mhasMax[k] = pfHasMax[k] || p->hasMax;
      p->mmax[k] = pfHasMax[k] ? pfMax[k] : mx;
    }
    // Per-field units `units={%,px,...}`. Empty / absent slot = raw. "%" -> the
    // lane shows a percent, the shader divides by 100; "px" -> media pixels.
    for (int k = 0; k < 4; k++)
      p->fieldUnit[k] = 0;
    NSTextCheckingResult *um = [[NSRegularExpression
        regularExpressionWithPattern:@"\\bunits\\s*=\\s*\\{([^}]*)\\}"
                             options:0
                               error:nil]
        firstMatchInString:attrs
                   options:0
                     range:NSMakeRange(0, attrs.length)];
    if (um && [um rangeAtIndex:1].location != NSNotFound) {
      NSArray<NSString *> *us = [[attrs substringWithRange:[um rangeAtIndex:1]]
          componentsSeparatedByString:@","];
      for (int k = 0; k < 4 && k < (int)us.count; k++) {
        NSString *t =
            [[us[k] stringByTrimmingCharactersInSet:NSCharacterSet
                                                        .whitespaceCharacterSet]
                lowercaseString];
        if ([t isEqualToString:@"%"] || [t isEqualToString:@"percent"])
          p->fieldUnit[k] = '%';
        else if ([t isEqualToString:@"px"])
          p->fieldUnit[k] = 'p';
      }
    }
    double smn =
        MirageAttrDouble(attrs, @"\\bslidermin\\s*=\\s*(-?[0-9.]+)", NAN);
    double smx =
        MirageAttrDouble(attrs, @"\\bslidermax\\s*=\\s*(-?[0-9.]+)", NAN);
    p->sliderLo = isnan(smn) ? mn : smn;
    p->sliderHi = isnan(smx) ? mx : smx;
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
    break;
  }
  case MirageScalarKindFloat:
  case MirageScalarKindPercent:
  case MirageScalarKindProgress:
  case MirageScalarKindInt: {
    double defMax = p->isPercent ? 100.0 : (p->isInt ? 10.0 : 1.0);
    double mn = MirageAttrDouble(attrs, @"\\bmin\\s*=\\s*(-?[0-9.]+)", NAN);
    double mx = MirageAttrDouble(attrs, @"\\bmax\\s*=\\s*(-?[0-9.]+)", NAN);
    p->hasMin = !isnan(mn);
    p->hasMax = !isnan(mx);
    if (!p->hasMin)
      mn = 0.0; // nominal slider floor; the field stays unbounded below
    if (!p->hasMax)
      mx = defMax; // nominal slider cap; the field stays unbounded above
    if (p->isProgress) {
      // 0..100% is what progress MEANS, so it's a bounded field rather than an
      // open one with a nominal cap. min=/max= aren't honoured here on purpose.
      mn = 0.0;
      mx = 100.0;
      p->hasMin = 1;
      p->hasMax = 1;
    }
    double df = MirageAttrDouble(attrs, @"\\bdefault\\s*=\\s*(-?[0-9.]+)", mn);
    if (mx < mn)
      mx = mn;
    if (p->hasMin && df < mn)
      df = mn; // only clamp to a bound that was actually set (else the
    if (p->hasMax && df > mx)
      df = mx; // nominal slider range would wrongly cap an unbounded default)
    p->fmin = mn;
    p->fmax = mx;
    p->fdefault = df;
    // `slidermin=`/`slidermax=` override the slider span (its visible ends)
    // without touching the hard field bounds. Default to the bound / nominal.
    // Progress is a fixed 0..100 ramp, so it ignores these like it does
    // min/max.
    double smn =
        MirageAttrDouble(attrs, @"\\bslidermin\\s*=\\s*(-?[0-9.]+)", NAN);
    double smx =
        MirageAttrDouble(attrs, @"\\bslidermax\\s*=\\s*(-?[0-9.]+)", NAN);
    p->sliderLo = (p->isProgress || isnan(smn)) ? mn : smn;
    p->sliderHi = (p->isProgress || isnan(smx)) ? mx : smx;
    break;
  }
  }
}

/// Parse every `// #float` / `// #choice` directive + its `uniform float|int
/// <name>;` (before the next directive), in source order. Pool offsets start at
/// `startOffset` (the colour pool count). Returns the count; `outUsed` = vec4s
/// used (one per prop).
static inline int MirageParseScalarProps(NSString *source,
                                         MirageScalarProp *props, int maxProps,
                                         int startOffset, int *outUsed,
                                         int *outTruncated) {
  int n = 0, pool = startOffset;
  if (outTruncated)
    *outTruncated = 0;
  if (outUsed)
    *outUsed = 0;
  if (!source.length || maxProps <= 0)
    return 0;
  NSRegularExpression *dirRe = [NSRegularExpression
      regularExpressionWithPattern:
          [NSString stringWithFormat:
                        @"(?m)^[ \\t]*//[ \\t]*#(%@)(?![-\\w])([^\\n]*)$",
                        MirageScalarKindAlternation()]
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
  NSDictionary<NSString *, NSValue *> *slotBindings =
      MirageSlotBindingsByUniform(source);
  for (int di = 0; di < (int)dirs.count; di++) {
    // Out of room: say so rather than quietly returning a short control set.
    if (n >= maxProps || pool + 1 > KK_SHADER_COLOR_POOL) {
      if (outTruncated)
        *outTruncated = 1;
      break;
    }
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
    const MirageScalarKindSpec *spec = MirageScalarKindForKeyword(kind);
    if (!spec)
      continue;
    MirageScalarProp p;
    memset(&p, 0, sizeof(p));
    p.kind = spec->kind;
    p.isChoice = spec->isChoice;
    p.isProgress = spec->isProgress;
    p.isPercent = spec->isPercent;
    p.isSeed = spec->isSeed;
    p.isPoint = spec->isPoint;
    p.isBool = spec->isBool;
    p.isInt = spec->isInt;
    p.isAngle = spec->isAngle;
    p.isMulti = spec->isMulti;
    if (p.isMulti) {
      // `#multi` can carry a numeric sub-type: `percent` (0..100 lane shown as
      // %, pool gets value / 100 like a single #percent) or `int` (whole-number
      // fields). Scan with quoted strings blanked so a word inside label="..."
      // can't trip the keyword (`int` in particular is short).
      NSString *bare =
          [[NSRegularExpression regularExpressionWithPattern:@"\"[^\"]*\""
                                                     options:0
                                                       error:nil]
              stringByReplacingMatchesInString:attrs
                                       options:0
                                         range:NSMakeRange(0, attrs.length)
                                  withTemplate:@""];
      p.isPercent =
          ([[NSRegularExpression regularExpressionWithPattern:@"\\bpercent\\b"
                                                      options:0
                                                        error:nil]
               firstMatchInString:bare
                          options:0
                            range:NSMakeRange(0, bare.length)] != nil);
      p.isInt = ([[NSRegularExpression regularExpressionWithPattern:@"\\bint\\b"
                                                            options:0
                                                              error:nil]
                     firstMatchInString:bare
                                options:0
                                  range:NSMakeRange(0, bare.length)] != nil);
    }
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
            : MiragePrettifyUniformName(nm);
    strncpy(p.label, label.UTF8String ?: "", sizeof(p.label) - 1);
    MirageParseGroupAttr(attrs, p.group, sizeof(p.group), p.groupSymbol,
                         sizeof(p.groupSymbol));
    if (!p.isMulti) {
      // Single-value `units="px"` / `units={px}`. `#multi` parses its own
      // per-field list further down; this is the one-component spelling.
      NSString *u = MirageAttrString(attrs, @"units");
      if (!u.length) {
        NSTextCheckingResult *bm = [[NSRegularExpression
            regularExpressionWithPattern:@"\\bunits\\s*=\\s*\\{([^}]*)\\}"
                                 options:0
                                   error:nil]
            firstMatchInString:attrs
                       options:0
                         range:NSMakeRange(0, attrs.length)];
        if (bm && [bm rangeAtIndex:1].location != NSNotFound)
          u = [attrs substringWithRange:[bm rangeAtIndex:1]];
      }
      u = [[u
          stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
          lowercaseString];
      if ([u isEqualToString:@"px"])
        p.fieldUnit[0] = 'p';
      else if ([u isEqualToString:@"%"] || [u isEqualToString:@"percent"])
        p.fieldUnit[0] = '%';
    }
    MirageSlotBinding slot = MirageSlotBindingValue(slotBindings[nm]);
    if (slot.maxCount > 0) {
      p.slotMax = slot.maxCount;
      p.slotGroupIndex = slot.groupIndex;
      strncpy(p.slotGroup, slot.groupName, sizeof(p.slotGroup) - 1);
    }
    // A repeatable control costs its group's CEILING: the block layout is
    // compiled once, so every instance the user may add needs a home in it
    // already. Out of room is the same answer as above - say so.
    int span = p.slotMax > 0 ? p.slotMax : 1;
    if (pool + span > KK_SHADER_COLOR_POOL) {
      if (outTruncated)
        *outTruncated = 1;
      break;
    }
    p.poolOffset = pool;
    MirageScalarParseOSC(attrs, &p);
    MirageScalarParseDefaults(attrs, &p);
    MirageScalarParseDynamicMax(attrs, &p);
    MirageScalarParseVisibility(attrs, &p);
    props[n++] = p;
    pool += span;
  }
  if (outUsed)
    *outUsed = pool - startOffset;
  return n;
}

#endif // __METAL_VERSION__
