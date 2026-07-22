/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Whole-source directive validation: the checks whose answer depends on every
// directive at once (duplicate identities, OSC opt-ins that don't fit their
// uniform), surfaced as compile errors in the editor.
#pragma once

#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>
#import <ctype.h>
#import <math.h>
#import <string.h>

#import "MirageTypes.h"

// Validation reads every directive kind back, so it sits on top of the parsers
// rather than beside them.
#import "MirageColorProps.h"
#import "MirageScalarOSC.h"
#import "MirageScalarParse.h"

/// The first control label used by more than one directive (colour or scalar),
/// or nil when all are unique. The label is the lane identity (values, OSC,
/// pool fill all key on it), so a duplicate is a compile error - the editor
/// surfaces this rather than silently merging two controls into one.
static inline NSString *MirageFirstDuplicateLabel(NSString *source) {
  if (!source.length)
    return nil;
  NSMutableSet<NSString *> *seen = [NSMutableSet set];
  MirageColorProp cp[KK_SHADER_MAX_COLOR_PROPS];
  int cpool = 0;
  int nc = MirageParseColorProps(source, cp, KK_SHADER_MAX_COLOR_PROPS, &cpool);
  for (int i = 0; i < nc; i++) {
    NSString *l = @(cp[i].label);
    if ([seen containsObject:l])
      return l;
    [seen addObject:l];
  }
  MirageScalarProp sp[KK_SHADER_MAX_SCALAR_PROPS];
  int used = 0;
  int ns =
      MirageParseScalarProps(source, sp, KK_SHADER_MAX_SCALAR_PROPS, 0, &used);
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
static inline NSString *MirageFirstDuplicateUniform(NSString *source) {
  if (!source.length)
    return nil;
  NSMutableSet<NSString *> *seen = [NSMutableSet set];
  MirageColorProp cp[KK_SHADER_MAX_COLOR_PROPS];
  int cpool = 0;
  int nc = MirageParseColorProps(source, cp, KK_SHADER_MAX_COLOR_PROPS, &cpool);
  for (int i = 0; i < nc; i++) {
    NSString *nm = @(cp[i].name);
    if ([seen containsObject:nm])
      return nm;
    [seen addObject:nm];
  }
  MirageScalarProp sp[KK_SHADER_MAX_SCALAR_PROPS];
  int used = 0;
  int ns =
      MirageParseScalarProps(source, sp, KK_SHADER_MAX_SCALAR_PROPS, 0, &used);
  for (int i = 0; i < ns; i++) {
    NSString *nm = @(sp[i].name);
    if ([seen containsObject:nm])
      return nm;
    [seen addObject:nm];
  }
  return nil;
}

/// The `osc` kinds a directive can carry, for validation-error messaging.
typedef enum MirageOSCErrorKind {
  MirageOSCErrorPoint = 0,  // osc=point on a non-vec2
  MirageOSCErrorRadial = 1, // osc=ring / osc=box on an unsupported type
  MirageOSCErrorRotate = 2, // osc={..} axis set mismatched to the value arity
} MirageOSCErrorKind;

/// The first directive whose `osc` kind is incompatible with its uniform type,
/// or nil when every OSC opt-in is valid. `osc=point` needs a `vec2`; a radial
/// `osc=ring`/`osc=box` needs a single numeric slider (`float`/`int`) or a
/// 2-field vec2 `#multi`; a rotate `osc={..}` needs one distinct x/y/z axis per
/// value component (a `#angle` float = 1 axis, a vec2/vec3 `#multi` = 2/3).
/// `outKind` (a MirageOSCErrorKind) tells the caller which message to show.
static inline NSString *MirageFirstInvalidOSC(NSString *source, int *outKind) {
  if (!source.length)
    return nil;
  MirageScalarProp sp[KK_SHADER_MAX_SCALAR_PROPS];
  int used = 0;
  int ns =
      MirageParseScalarProps(source, sp, KK_SHADER_MAX_SCALAR_PROPS, 0, &used);
  for (int i = 0; i < ns; i++) {
    if ((strcmp(sp[i].oscKind, "point") == 0 ||
         strcmp(sp[i].oscKind, "position") == 0) &&
        strcmp(sp[i].uniformType, "vec2") != 0) {
      if (outKind)
        *outKind = MirageOSCErrorPoint;
      return @(sp[i].name);
    }
    if (MirageScalarRadialOSC(&sp[i])) {
      BOOL scalarOK = strcmp(sp[i].uniformType, "float") == 0 ||
                      strcmp(sp[i].uniformType, "int") == 0;
      BOOL multiOK = sp[i].isMulti && strcmp(sp[i].uniformType, "vec2") == 0;
      if (!MirageScalarRingEligible(&sp[i]) || !(scalarOK || multiOK)) {
        if (outKind)
          *outKind = MirageOSCErrorRadial;
        return @(sp[i].name);
      }
    }
    if (MirageScalarOSCIsRotate(&sp[i])) {
      int arity = MirageScalarRotateArity(&sp[i]);
      // One distinct axis per component: #angle float = 1, vec2 = 2, vec3 = 3.
      BOOL typeOK =
          (sp[i].isAngle && strcmp(sp[i].uniformType, "float") == 0) ||
          (sp[i].isMulti && (strcmp(sp[i].uniformType, "vec2") == 0 ||
                             strcmp(sp[i].uniformType, "vec3") == 0));
      BOOL distinct =
          (sp[i].oscAxisCount == 1) ||
          (sp[i].oscAxisCount == 2 && sp[i].oscAxes[0] != sp[i].oscAxes[1]) ||
          (sp[i].oscAxisCount == 3 && sp[i].oscAxes[0] != sp[i].oscAxes[1] &&
           sp[i].oscAxes[0] != sp[i].oscAxes[2] &&
           sp[i].oscAxes[1] != sp[i].oscAxes[2]);
      if (!typeOK || sp[i].oscAxisCount != arity || !distinct) {
        if (outKind)
          *outKind = MirageOSCErrorRotate;
        return @(sp[i].name);
      }
    }
  }
  return nil;
}

#endif // __METAL_VERSION__
