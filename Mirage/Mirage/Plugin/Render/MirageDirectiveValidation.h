/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Whole-source directive validation: the checks whose answer depends on every
// directive at once (duplicate identities, OSC opt-ins that don't fit their
// uniform), surfaced as compile errors in the editor.
#pragma once

#ifndef __METAL_VERSION__

#import <AppKit/AppKit.h> // NSImage, to resolve a `group=` icon name
#import <Foundation/Foundation.h>
#import <ctype.h>
#import <math.h>
#import <string.h>

#import "MirageTypes.h"

// Validation reads every directive kind back, so it sits on the parsed model
// rather than beside the parsers.
#import "MirageAudioDirectiveValidation.h"
#import "MirageChoiceDirectiveValidation.h"
#import "MirageDependencyDirectiveValidation.h"
#import "MirageScalarOSC.h"
#import "MirageShaderModel.h"

/// The first uniform NAME declared by more than one directive, or nil when all
/// are unique. Two same-named uniforms produce two identically-named block
/// members (`<name>_kk`) and a cryptic glslang "duplicate member name" - catch
/// it here for a clear editor error instead.
static inline NSString *MirageFirstDuplicateUniform(NSString *source) {
  if (!source.length)
    return nil;
  NSMutableSet<NSString *> *seen = [NSMutableSet set];
  MirageShaderModel *m = [MirageShaderModel modelForSource:source];
  const MirageColorProp *cp = m.colorProps;
  for (int i = 0; i < m.colorCount; i++) {
    NSString *nm = @(cp[i].name);
    if ([seen containsObject:nm])
      return nm;
    [seen addObject:nm];
  }
  const MirageScalarProp *sp = m.scalarProps;
  for (int i = 0; i < m.scalarCount; i++) {
    NSString *nm = @(sp[i].name);
    if ([seen containsObject:nm])
      return nm;
    [seen addObject:nm];
  }
  const MirageGradientProp *gp = m.gradientProps;
  for (int i = 0; i < m.gradientCount; i++) {
    NSString *nm = @(gp[i].name);
    if ([seen containsObject:nm])
      return nm;
    [seen addObject:nm];
  }
  return nil;
}

/// The first directive keyword (`color` / `audio` / `gradient`) that carries a
/// `group=` it isn't allowed to, or nil when none does. These three land in
/// dedicated groups of their own, so honouring a group would either be ignored
/// silently or split a colour set away from its swatches. This is a
/// source-level scan rather than a model check because their parsers never read
/// `group=` at all, so there is nothing on the parsed prop to inspect.
static inline NSString *MirageFirstMisplacedGroup(NSString *source) {
  if (!source.length)
    return nil;
  NSRegularExpression *re = [NSRegularExpression
      regularExpressionWithPattern:
          @"(?m)^[ \\t]*//[ \\t]*#(color|audio|gradient)(?![-\\w])([^\\n]*)$"
                           options:0
                             error:nil];
  NSRegularExpression *groupRe =
      [NSRegularExpression regularExpressionWithPattern:@"\\bgroup\\s*="
                                                options:0
                                                  error:nil];
  __block NSString *found = nil;
  [re enumerateMatchesInString:source
                       options:0
                         range:NSMakeRange(0, source.length)
                    usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f,
                                 BOOL *stop) {
                      NSString *attrs =
                          [source substringWithRange:[m rangeAtIndex:2]];
                      if (!attrs.length)
                        return;
                      if ([groupRe firstMatchInString:attrs
                                              options:0
                                                range:NSMakeRange(
                                                          0, attrs.length)]) {
                        found = [source substringWithRange:[m rangeAtIndex:1]];
                        *stop = YES;
                      }
                    }];
  return found;
}

/// The first `group=` icon naming an SF Symbol this Mac doesn't have, or nil
/// when every one resolves. Worth catching: an unknown name isn't an error
/// anywhere downstream, it just draws the blank placeholder, so `sparkle` typed
/// for `sparkles` silently produces a group with no icon and nothing to explain
/// it. Any installed symbol is accepted - the completion list is discovery, not
/// a whitelist.
static inline NSString *MirageUnknownGroupSymbol(NSString *source) {
  if (!source.length)
    return nil;
  MirageShaderModel *m = [MirageShaderModel modelForSource:source];
  NSMutableArray<NSString *> *symbols = [NSMutableArray array];
  const MirageScalarProp *sp = m.scalarProps;
  for (int i = 0; i < m.scalarCount; i++)
    if (sp[i].groupSymbol[0])
      [symbols addObject:@(sp[i].groupSymbol)];
  MirageBuiltins b = m.builtins; // a local: `builtins` returns by value
  const MirageBuiltinProp *bp[] = {&b.speed, &b.seed, &b.grain};
  for (int i = 0; i < 3; i++)
    if (bp[i]->present && bp[i]->groupSymbol[0])
      [symbols addObject:@(bp[i]->groupSymbol)];
  for (NSString *s in symbols)
    if (![NSImage imageWithSystemSymbolName:s accessibilityDescription:nil])
      return s;
  return nil;
}

/// The first `#multi` declaring more than 4 fields, or nil. A vec4 is the
/// widest uniform there is, so a 5th field has nowhere to live - and silently
/// dropping it would leave the author wondering why their control is short.
static inline NSString *MirageFirstOverlongMulti(NSString *source) {
  if (!source.length)
    return nil;
  NSRegularExpression *re = [NSRegularExpression
      regularExpressionWithPattern:
          @"(?m)^[ \\t]*//[ "
          @"\\t]*#multi(?![-\\w])[^\\n]*?\\bfields\\s*=\\s*\\{([^}]*)\\}"
                           options:0
                             error:nil];
  __block NSString *found = nil;
  [re enumerateMatchesInString:source
                       options:0
                         range:NSMakeRange(0, source.length)
                    usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags f,
                                 BOOL *stop) {
                      NSString *list =
                          [source substringWithRange:[m rangeAtIndex:1]];
                      NSInteger n = 0;
                      for (NSString *t in
                           [list componentsSeparatedByString:@","])
                        if ([t stringByTrimmingCharactersInSet:
                                    NSCharacterSet.whitespaceCharacterSet]
                                .length)
                          n++;
                      if (n > 4) {
                        found = list;
                        *stop = YES;
                      }
                    }];
  return found;
}

/// YES when the shader declares more controls than there is room for. Silent
/// truncation is the worst outcome here: the shader still compiles and renders,
/// and the missing controls just never appear.
static inline BOOL MirageHasTooManyControls(NSString *source) {
  if (!source.length)
    return NO;
  return [MirageShaderModel modelForSource:source].scalarTruncated;
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
  MirageShaderModel *m = [MirageShaderModel modelForSource:source];
  const MirageScalarProp *sp = m.scalarProps;
  int ns = m.scalarCount;
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
