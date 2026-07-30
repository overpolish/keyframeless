/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>

#import "MirageShaderModel.h"

typedef enum MirageColorOptionsErrorKind {
  MirageColorOptionsErrorArray = 0,
  MirageColorOptionsErrorController = 1,
  MirageColorOptionsErrorMultiple = 2,
  MirageColorOptionsErrorCount = 3,
} MirageColorOptionsErrorKind;

/// Validate `#color optionsby=<uniform>`: an array slot maps one-to-one onto
/// each option of the named multiple-choice control.
static inline NSString *MirageFirstInvalidColorOptions(NSString *source,
                                                       int *outKind) {
  if (!source.length)
    return nil;
  MirageShaderModel *m = [MirageShaderModel modelForSource:source];
  const MirageColorProp *cp = m.colorProps;
  const MirageScalarProp *sp = m.scalarProps;
  for (int i = 0; i < m.colorCount; i++) {
    if (!cp[i].optionsByName[0])
      continue;
    if (!cp[i].isArray) {
      if (outKind)
        *outKind = MirageColorOptionsErrorArray;
      return @(cp[i].name);
    }
    const MirageScalarProp *controller = NULL;
    for (int j = 0; j < m.scalarCount; j++)
      if (strcmp(cp[i].optionsByName, sp[j].name) == 0) {
        controller = &sp[j];
        break;
      }
    if (!controller) {
      if (outKind)
        *outKind = MirageColorOptionsErrorController;
      return @(cp[i].optionsByName);
    }
    if (!controller->isChoice || !controller->choiceMultiple) {
      if (outKind)
        *outKind = MirageColorOptionsErrorMultiple;
      return @(cp[i].optionsByName);
    }
    if (cp[i].count != controller->choiceCount) {
      if (outKind)
        *outKind = MirageColorOptionsErrorCount;
      return @(cp[i].name);
    }
  }
  return nil;
}

typedef enum MirageMultipleChoiceErrorKind {
  MirageMultipleChoiceErrorType = 0,
  MirageMultipleChoiceErrorDropdown = 1,
  MirageMultipleChoiceErrorOptions = 2,
  MirageMultipleChoiceErrorTooManyOptions = 3,
  MirageMultipleChoiceErrorDefault = 4,
} MirageMultipleChoiceErrorKind;

/// Validate the bitmask form:
///   #choice ... options="A,B,C" dropdown multiple default="A,C"
/// Quoted strings are removed before looking for the bare `multiple` flag, so
/// labels such as "Multiple Exposure" do not opt in accidentally.
static inline NSString *
MirageFirstInvalidMultipleChoice(NSString *source,
                                 MirageMultipleChoiceErrorKind *outKind) {
  if (!source.length)
    return nil;
  NSRegularExpression *re = [NSRegularExpression
      regularExpressionWithPattern:
          [NSString stringWithFormat:
                        @"(?m)^[ \\t]*//[ \\t]*#(%@)(?![-\\w])([^\\n]*)$",
                        MirageScalarKindAlternation()]
                           options:0
                             error:nil];
  for (NSTextCheckingResult *m in
       [re matchesInString:source
                   options:0
                     range:NSMakeRange(0, source.length)]) {
    NSString *kind = [source substringWithRange:[m rangeAtIndex:1]];
    NSString *attrs = [source substringWithRange:[m rangeAtIndex:2]];
    BOOL multiple = MirageAttrHasBareFlag(attrs, @"multiple");
    if (!multiple)
      continue;
    if (![kind isEqualToString:@"choice"]) {
      if (outKind)
        *outKind = MirageMultipleChoiceErrorType;
      return kind;
    }
    BOOL dropdown = MirageAttrHasBareFlag(attrs, @"dropdown");
    if (!dropdown) {
      if (outKind)
        *outKind = MirageMultipleChoiceErrorDropdown;
      return @"choice";
    }

    NSString *options = MirageAttrString(attrs, @"options");
    NSMutableArray<NSString *> *labels = [NSMutableArray array];
    for (NSString *part in [options componentsSeparatedByString:@","]) {
      NSString *label =
          [part stringByTrimmingCharactersInSet:NSCharacterSet
                                                    .whitespaceCharacterSet];
      if (label.length)
        [labels addObject:label];
    }
    if (!labels.count) {
      if (outKind)
        *outKind = MirageMultipleChoiceErrorOptions;
      return @"choice";
    }
    if (labels.count > KK_SHADER_MAX_MULTIPLE_CHOICE_OPTIONS) {
      if (outKind)
        *outKind = MirageMultipleChoiceErrorTooManyOptions;
      return @"choice";
    }

    NSTextCheckingResult *dm = [[NSRegularExpression
        regularExpressionWithPattern:@"\\bdefault\\s*=\\s*\"([^\"]*)\""
                             options:0
                               error:nil]
        firstMatchInString:attrs
                   options:0
                     range:NSMakeRange(0, attrs.length)];
    if (!dm || [dm rangeAtIndex:1].location == NSNotFound)
      continue; // no quoted default: absent/numeric bitmask is valid
    NSString *defaults = [attrs substringWithRange:[dm rangeAtIndex:1]];
    for (NSString *part in [defaults componentsSeparatedByString:@","]) {
      NSString *pick =
          [part stringByTrimmingCharactersInSet:NSCharacterSet
                                                    .whitespaceCharacterSet];
      if (pick.length && ![labels containsObject:pick]) {
        if (outKind)
          *outKind = MirageMultipleChoiceErrorDefault;
        return pick;
      }
    }
  }
  return nil;
}

#endif // __METAL_VERSION__
