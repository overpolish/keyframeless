/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

typedef NS_ENUM(NSInteger, MirageTemplateType) {
  MirageTemplateTypeInvalid = -1,
  MirageTemplateTypeGenerator = 0,
  MirageTemplateTypeFilter,
  MirageTemplateTypeLayout,
  MirageTemplateTypeTransition,
  MirageTemplateTypeColorTransform,
};

typedef NS_ENUM(NSInteger, MirageTemplateDirectiveError) {
  MirageTemplateDirectiveErrorNone = 0,
  MirageTemplateDirectiveErrorMissing,
  MirageTemplateDirectiveErrorMultiple,
  MirageTemplateDirectiveErrorValue,
};

static inline NSString *MirageTemplateTypeID(MirageTemplateType type) {
  switch (type) {
  case MirageTemplateTypeFilter:
    return @"filter";
  case MirageTemplateTypeLayout:
    return @"layout";
  case MirageTemplateTypeTransition:
    return @"transition";
  case MirageTemplateTypeColorTransform:
    return @"color-transform";
  case MirageTemplateTypeGenerator:
    return @"generator";
  default:
    return nil;
  }
}

static inline MirageTemplateType
MirageTemplateTypeForSource(NSString *source,
                            MirageTemplateDirectiveError *outError) {
  if (outError)
    *outError = MirageTemplateDirectiveErrorNone;
  if (!source.length) {
    if (outError)
      *outError = MirageTemplateDirectiveErrorMissing;
    return MirageTemplateTypeInvalid;
  }

  // Substring fast-reject, then a once-compiled pattern: the rack strip asks
  // this once per ENTRY on every refresh, and compiling the expression cost
  // more than the whole rest of the parse.
  if ([source rangeOfString:@"#template"].location == NSNotFound) {
    if (outError)
      *outError = MirageTemplateDirectiveErrorMissing;
    return MirageTemplateTypeInvalid;
  }
  static NSRegularExpression *expression;
  static dispatch_once_t onceTemplate;
  dispatch_once(&onceTemplate, ^{
    expression = [[NSRegularExpression alloc]
        initWithPattern:@"(?m)^[ \\t]*//[ \\t]*#template(?![-\\w:])(.*)$"
                options:0
                  error:nil];
  });
  NSArray<NSTextCheckingResult *> *matches =
      [expression matchesInString:source
                          options:0
                            range:NSMakeRange(0, source.length)];
  if (matches.count == 0) {
    if (outError)
      *outError = MirageTemplateDirectiveErrorMissing;
    return MirageTemplateTypeInvalid;
  }
  if (matches.count != 1) {
    if (outError)
      *outError = MirageTemplateDirectiveErrorMultiple;
    return MirageTemplateTypeInvalid;
  }

  NSString *value =
      [source substringWithRange:[matches.firstObject rangeAtIndex:1]];
  value = [[value
      stringByTrimmingCharactersInSet:NSCharacterSet
                                          .whitespaceAndNewlineCharacterSet]
      lowercaseString];
  if ([value isEqualToString:@"generator"])
    return MirageTemplateTypeGenerator;
  if ([value isEqualToString:@"filter"])
    return MirageTemplateTypeFilter;
  if ([value isEqualToString:@"layout"])
    return MirageTemplateTypeLayout;
  if ([value isEqualToString:@"transition"])
    return MirageTemplateTypeTransition;
  if ([value isEqualToString:@"color-transform"])
    return MirageTemplateTypeColorTransform;

  if (outError)
    *outError = MirageTemplateDirectiveErrorValue;
  return MirageTemplateTypeInvalid;
}
