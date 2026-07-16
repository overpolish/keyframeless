/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The on-screen-control layer for scalar directives: whether a declaration
// opts into an OSC and what shape it takes, plus reading those attributes
// off the directive. Pure functions of a parsed ShaderScalarProp.
#pragma once

#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>
#import <ctype.h>
#import <math.h>
#import <string.h>

#import "ShaderScalarProps.h"
#import "ShaderTypes.h"

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

/// A multi-axis rotation OSC (`osc={z}` / `osc={y,x}` / `osc={z,x,y}`): a
/// KKRotationOSC ring gizmo editing one euler angle (degrees) per listed axis.
/// The listed order maps axis N -> value component N. A single-axis rotate on a
/// `#angle` float; a 2-/3-axis rotate on a vec2/vec3 `#multi`.
static inline BOOL ShaderScalarOSCIsRotate(const ShaderScalarProp *p) {
  return strcmp(p->oscKind, "rotate") == 0;
}

/// The value-component count a rotate OSC expects: 1 for a `#angle` float, else
/// the `#multi` field count.
static inline int ShaderScalarRotateArity(const ShaderScalarProp *p) {
  return p->isMulti ? p->fieldCount : 1;
}

/// The active-axis bitmask (bit 0=X, 1=Y, 2=Z, matching KKRotationAxisX/Y/Z) a
/// rotate OSC drives, from its ordered `osc={..}` set. 0 when none are listed;
/// callers building a gizmo default a 0 mask to Z.
static inline int ShaderScalarRotationAxisMask(const ShaderScalarProp *p) {
  int mask = 0;
  for (int k = 0; k < p->oscAxisCount; k++) {
    char a = p->oscAxes[k];
    if (a == 'x')
      mask |= (1 << 0);
    else if (a == 'y')
      mask |= (1 << 1);
    else if (a == 'z')
      mask |= (1 << 2);
  }
  return mask;
}

/// The GLSL swizzle mapping a rotate OSC's CANONICAL-order lane components
/// (packed X<Y<Z into the pool vec4's .xyz) onto the shader vec's braced order
/// (shader component N = the axis listed Nth). E.g. `osc={y,x}` -> "yx",
/// `osc={z,x,y}` -> "zxy", a single axis -> "x". The transpiler folds this into
/// the `#define` so `uRot.x` is the first-listed axis's angle.
static inline NSString *
ShaderRotateCanonicalSwizzle(const ShaderScalarProp *p) {
  const char *canon = "xyz";
  NSMutableString *sw = [NSMutableString string];
  for (int i = 0; i < p->oscAxisCount; i++) {
    char axis = p->oscAxes[i];
    int pos = 0; // count of present axes that sort before `axis` in X<Y<Z
    for (int a = 0; a < 3; a++) {
      if (canon[a] == axis)
        break;
      for (int k = 0; k < p->oscAxisCount; k++)
        if (p->oscAxes[k] == canon[a]) {
          pos++;
          break;
        }
    }
    [sw appendFormat:@"%c", canon[pos]];
  }
  return sw.length ? sw : @"x";
}

/// Reads a directive's `osc` opt-in and its placement attributes (`axis=`,
/// `center=`, `link=`) into `p`. No `osc` on the directive leaves every OSC
/// field zeroed, which is what marks the control as viewer-invisible.
static inline void ShaderScalarParseOSC(NSString *attrs, ShaderScalarProp *p) {
  // On-screen control opt-in: `osc` (bare) or `osc=<ring|scale>`. #point ->
  // position handle; #angle -> rotation ring (axis=x|y|z, default z); #float
  // -> ring or scale per the osc value.
  p->oscAxis = 'z';
  if ([[NSRegularExpression regularExpressionWithPattern:@"\\bosc\\b"
                                                 options:0
                                                   error:nil]
          firstMatchInString:attrs
                     options:0
                       range:NSMakeRange(0, attrs.length)]) {
    // A braced axis set (`osc={z,x,y}`) is a multi-axis rotate: the listed
    // order maps axis N -> value component N. Parse it before the plain
    // `osc=<word>` form (which can't match `{...}`).
    NSTextCheckingResult *bm = [[NSRegularExpression
        regularExpressionWithPattern:@"\\bosc\\s*=\\s*\\{([^}]*)\\}"
                             options:0
                               error:nil]
        firstMatchInString:attrs
                   options:0
                     range:NSMakeRange(0, attrs.length)];
    NSString *val = nil;
    if (bm && [bm rangeAtIndex:1].location != NSNotFound) {
      NSString *set = [attrs substringWithRange:[bm rangeAtIndex:1]];
      int ac = 0;
      for (NSUInteger i = 0; i < set.length && ac < 3; i++) {
        unichar c = (unichar)tolower([set characterAtIndex:i]);
        if (c == 'x' || c == 'y' || c == 'z')
          p->oscAxes[ac++] = (char)c;
      }
      p->oscAxes[ac] = 0;
      p->oscAxisCount = ac;
      val = @"rotate";
    } else {
      NSTextCheckingResult *ov = [[NSRegularExpression
          regularExpressionWithPattern:@"\\bosc\\s*=\\s*(\\w+)"
                               options:0
                                 error:nil]
          firstMatchInString:attrs
                     options:0
                       range:NSMakeRange(0, attrs.length)];
      val = (ov && [ov rangeAtIndex:1].location != NSNotFound)
                ? [attrs substringWithRange:[ov rangeAtIndex:1]]
                : nil;
    }
    NSString *kindStr =
        val ? val.lowercaseString
            : (p->isPoint ? @"point" : (p->isAngle ? @"rotate" : @""));
    strncpy(p->oscKind, kindStr.UTF8String ?: "", sizeof(p->oscKind) - 1);
    NSTextCheckingResult *am = [[NSRegularExpression
        regularExpressionWithPattern:@"\\baxis\\s*=\\s*([xyzXYZ])"
                             options:0
                               error:nil]
        firstMatchInString:attrs
                   options:0
                     range:NSMakeRange(0, attrs.length)];
    if (am && [am rangeAtIndex:1].location != NSNotFound)
      p->oscAxis = (char)tolower(
          [[attrs substringWithRange:[am rangeAtIndex:1]] characterAtIndex:0]);
    // A bare `#angle osc` / `osc=rotate` / `axis=` (no braced set) defaults
    // to a single-axis rotate on `oscAxis`.
    if (ShaderScalarOSCIsRotate(p) && p->oscAxisCount == 0) {
      p->oscAxes[0] = p->oscAxis;
      p->oscAxes[1] = 0;
      p->oscAxisCount = 1;
    }
    // A radial (ring / box) or rotate OSC is placed at `center=x,y` (object
    // space 0..1) unless it is `link=`ed to a #point. Default is the clip
    // centre. Rotate shares the same placement so several rotation gizmos can
    // sit at distinct points instead of stacking at the middle.
    if (ShaderScalarRadialOSC(p) || ShaderScalarOSCIsRotate(p)) {
      NSTextCheckingResult *cm = [[NSRegularExpression
          regularExpressionWithPattern:
              @"\\bcenter\\s*=\\s*\"?(-?[0-9.]+)\\s*,\\s*(-?[0-9.]+)\"?"
                               options:0
                                 error:nil]
          firstMatchInString:attrs
                     options:0
                       range:NSMakeRange(0, attrs.length)];
      if (cm && [cm rangeAtIndex:2].location != NSNotFound) {
        p->rcenterx =
            [attrs substringWithRange:[cm rangeAtIndex:1]].doubleValue;
        p->rcentery =
            [attrs substringWithRange:[cm rangeAtIndex:2]].doubleValue;
      }
      // `link=<uniform>`: the centre tracks that #point's live value instead
      // of the fixed `center=`.
      NSTextCheckingResult *lk = [[NSRegularExpression
          regularExpressionWithPattern:@"\\blink\\s*=\\s*(\\w+)"
                               options:0
                                 error:nil]
          firstMatchInString:attrs
                     options:0
                       range:NSMakeRange(0, attrs.length)];
      if (lk && [lk rangeAtIndex:1].location != NSNotFound)
        strncpy(p->linkName,
                [attrs substringWithRange:[lk rangeAtIndex:1]].UTF8String ?: "",
                sizeof(p->linkName) - 1);
    }
  }
}

/// Reads the value attributes each directive kind defines - `default=`, its
/// range, and the per-kind extras (`options=` for #choice, `fields=` /
/// `lockaspect` for #multi) - into `p`. One branch per kind, because what a
/// "default" even means differs: an index for #choice, a point for #point, a

#endif // __METAL_VERSION__
