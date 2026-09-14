/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#ifndef __METAL_VERSION__

#import <Foundation/Foundation.h>

#import "MirageShaderModel.h"

typedef enum MirageDynamicMaxErrorKind {
  MirageDynamicMaxErrorPair = 0,
  MirageDynamicMaxErrorType = 1,
  MirageDynamicMaxErrorController = 2,
  MirageDynamicMaxErrorTooManyValues = 3,
  MirageDynamicMaxErrorValues = 4,
} MirageDynamicMaxErrorKind;

/// Validate `maxby=<uniform> maxvalues={...}` as a complete pair on a
/// single-value numeric control, with a controller that is another declared
/// scalar lane. `outKind` selects the author-facing error message.
static inline NSString *MirageFirstInvalidDynamicMax(NSString *source,
                                                     int *outKind) {
  if (!source.length)
    return nil;
  MirageShaderModel *m = [MirageShaderModel modelForSource:source];
  const MirageScalarProp *sp = m.scalarProps;
  int count = m.scalarCount;
  for (int i = 0; i < count; i++) {
    BOOL hasController = sp[i].maxByName[0] != '\0';
    BOOL hasValues = sp[i].maxByValueCount > 0;
    if (!hasController && !hasValues)
      continue;
    if (hasController != hasValues) {
      if (outKind)
        *outKind = MirageDynamicMaxErrorPair;
      return @(sp[i].name);
    }
    BOOL supported = sp[i].kind == MirageScalarKindFloat ||
                     sp[i].kind == MirageScalarKindPercent ||
                     sp[i].kind == MirageScalarKindInt;
    if (!supported) {
      if (outKind)
        *outKind = MirageDynamicMaxErrorType;
      return @(sp[i].name);
    }
    BOOL found = NO;
    for (int j = 0; j < count; j++)
      if (strcmp(sp[i].maxByName, sp[j].name) == 0) {
        found = YES;
        break;
      }
    if (!found) {
      if (outKind)
        *outKind = MirageDynamicMaxErrorController;
      return @(sp[i].maxByName);
    }
  }

  NSRegularExpression *re = [NSRegularExpression
      regularExpressionWithPattern:@"\\bmaxvalues\\s*=\\s*\\{([^}]*)\\}"
                           options:0
                             error:nil];
  for (NSTextCheckingResult *match in
       [re matchesInString:source
                   options:0
                     range:NSMakeRange(0, source.length)]) {
    NSString *body = [source substringWithRange:[match rangeAtIndex:1]];
    NSArray<NSString *> *parts = [body componentsSeparatedByString:@","];
    NSInteger values = 0;
    for (NSString *part in parts) {
      NSString *token =
          [part stringByTrimmingCharactersInSet:NSCharacterSet
                                                    .whitespaceCharacterSet];
      if (!token.length) {
        if (outKind)
          *outKind = MirageDynamicMaxErrorValues;
        return body;
      }
      NSScanner *scanner = [NSScanner scannerWithString:token];
      double value = 0.0;
      if (![scanner scanDouble:&value] || !scanner.atEnd || !isfinite(value)) {
        if (outKind)
          *outKind = MirageDynamicMaxErrorValues;
        return body;
      }
      values++;
    }
    if (values > KK_SHADER_MAX_DYNAMIC_MAX_VALUES) {
      if (outKind)
        *outKind = MirageDynamicMaxErrorTooManyValues;
      return body;
    }
  }
  return nil;
}

typedef enum MirageVisibilityErrorKind {
  MirageVisibilityErrorPair = 0,
  MirageVisibilityErrorController = 1,
  MirageVisibilityErrorTooManyValues = 2,
  MirageVisibilityErrorValues = 3,
} MirageVisibilityErrorKind;

static inline NSString *MirageFirstInvalidVisibility(NSString *source,
                                                     int *outKind) {
  if (!source.length)
    return nil;
  MirageShaderModel *m = [MirageShaderModel modelForSource:source];
  const MirageScalarProp *sp = m.scalarProps;
  int count = m.scalarCount;
  for (int i = 0; i < count; i++) {
    BOOL hasController = sp[i].visibleByName[0] != '\0';
    BOOL hasValues = sp[i].visibleByValueCount > 0;
    if (!hasController && !hasValues)
      continue;
    if (hasController != hasValues) {
      if (outKind)
        *outKind = MirageVisibilityErrorPair;
      return @(sp[i].name);
    }
    BOOL found = NO;
    for (int j = 0; j < count; j++)
      if (strcmp(sp[i].visibleByName, sp[j].name) == 0) {
        found = YES;
        break;
      }
    if (!found) {
      if (outKind)
        *outKind = MirageVisibilityErrorController;
      return @(sp[i].visibleByName);
    }
  }

  NSRegularExpression *re = [NSRegularExpression
      regularExpressionWithPattern:@"\\bvisiblevalues\\s*=\\s*\\{([^}]*)\\}"
                           options:0
                             error:nil];
  for (NSTextCheckingResult *match in
       [re matchesInString:source
                   options:0
                     range:NSMakeRange(0, source.length)]) {
    NSString *body = [source substringWithRange:[match rangeAtIndex:1]];
    NSArray<NSString *> *parts = [body componentsSeparatedByString:@","];
    NSInteger values = 0;
    for (NSString *part in parts) {
      NSString *token =
          [part stringByTrimmingCharactersInSet:NSCharacterSet
                                                    .whitespaceCharacterSet];
      NSScanner *scanner = [NSScanner scannerWithString:token];
      double value = 0.0;
      if (!token.length || ![scanner scanDouble:&value] || !scanner.atEnd ||
          !isfinite(value)) {
        if (outKind)
          *outKind = MirageVisibilityErrorValues;
        return body;
      }
      values++;
    }
    if (values > KK_SHADER_MAX_VISIBILITY_VALUES) {
      if (outKind)
        *outKind = MirageVisibilityErrorTooManyValues;
      return body;
    }
  }
  return nil;
}

#endif // __METAL_VERSION__
