/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// `// #speed` / `// #seed` / `// #grain`: the opt-in built-in controls. Unlike
// every other directive these annotate NO uniform - they drive the shared
// MirageCommonUniforms (the iTime multiplier, the time offset, the grain
// epilogue) that the wrapper gives every shader, so there is nothing for the
// author to declare. A shader that doesn't ask for them gets neither the lanes
// nor their effect: speed 1, offset 0, grain 0.
#pragma once

#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>
#import <string.h>

#import "MirageDirectiveCommon.h"

/// One opt-in built-in control.
typedef struct MirageBuiltinProp {
  int present;
  char label[80];       // display label (`label=`), empty = the lane's own
  char group[80];       // `group=`, empty = the default group
  char groupSymbol[40]; // the group's SF Symbol, empty = the default
  int hasDefault;
  double fdefault;
  int hasSize;  // `#grain size=` only: seeds the Grain Size lane
  double fsize; // (grain owns two lanes, so it takes two defaults)
} MirageBuiltinProp;

typedef struct MirageBuiltins {
  MirageBuiltinProp speed, seed, grain;
} MirageBuiltins;

/// Which built-ins a source opts into, and how each is labelled/grouped.
static inline MirageBuiltins MirageParseBuiltins(NSString *source) {
  MirageBuiltins b;
  memset(&b, 0, sizeof(b));
  if (!source.length)
    return b;
  NSRegularExpression *dirRe = [NSRegularExpression
      regularExpressionWithPattern:
          @"(?m)^[ \\t]*//[ \\t]*#(speed|seed|grain)(?![-\\w])([^\\n]*)$"
                           options:0
                             error:nil];
  NSArray<NSTextCheckingResult *> *dirs =
      [dirRe matchesInString:source
                     options:0
                       range:NSMakeRange(0, source.length)];
  for (NSTextCheckingResult *m in dirs) {
    NSString *kw = [source substringWithRange:[m rangeAtIndex:1]];
    NSString *attrs = [source substringWithRange:[m rangeAtIndex:2]];
    MirageBuiltinProp *p = [kw isEqualToString:@"speed"]   ? &b.speed
                           : [kw isEqualToString:@"grain"] ? &b.grain
                                                           : &b.seed;
    if (p->present)
      continue; // a repeated directive is the same control, so first wins
    p->present = 1;
    MirageParseGroupAttr(attrs, p->group, sizeof(p->group), p->groupSymbol,
                         sizeof(p->groupSymbol));
    NSString *label = MirageAttrString(attrs, @"label");
    if (label.length)
      strncpy(p->label, label.UTF8String ?: "", sizeof(p->label) - 1);
    double def =
        MirageAttrDouble(attrs, @"\\bdefault\\s*=\\s*(-?[0-9.]+)", NAN);
    p->hasDefault = !isnan(def);
    p->fdefault = p->hasDefault ? def : 0.0;
    double size = MirageAttrDouble(attrs, @"\\bsize\\s*=\\s*(-?[0-9.]+)", NAN);
    p->hasSize = !isnan(size);
    p->fsize = p->hasSize ? size : 0.0;
  }
  return b;
}

#endif // __METAL_VERSION__
