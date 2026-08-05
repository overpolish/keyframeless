/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKCodeTabInterchange.h"

NSString *KKCodeTabCanonicalName(NSString *name) {
  if (!name.length)
    return @"";
  NSMutableString *out = [NSMutableString stringWithCapacity:name.length];
  NSString *lower = name.lowercaseString;
  for (NSUInteger i = 0; i < lower.length; i++) {
    unichar c = [lower characterAtIndex:i];
    if ((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9'))
      [out appendFormat:@"%C", c];
  }
  return out;
}

NSString *KKCodeTabMarkerSpelling(NSString *name) {
  NSMutableString *out = [NSMutableString stringWithCapacity:name.length];
  NSString *lower = name.lowercaseString;
  BOOL pendingSeparator = NO;
  for (NSUInteger i = 0; i < lower.length; i++) {
    unichar c = [lower characterAtIndex:i];
    BOOL alnum = (c >= 'a' && c <= 'z') || (c >= '0' && c <= '9');
    if (!alnum) {
      pendingSeparator = out.length > 0; // never lead with a hyphen
      continue;
    }
    if (pendingSeparator) {
      [out appendString:@"-"];
      pendingSeparator = NO;
    }
    [out appendFormat:@"%C", c];
  }
  return out;
}

NSString *KKCodeTabMarkerName(NSString *line) {
  NSCharacterSet *ws = NSCharacterSet.whitespaceCharacterSet;
  NSString *t = [line
      stringByTrimmingCharactersInSet:NSCharacterSet
                                          .whitespaceAndNewlineCharacterSet];
  if (![t hasPrefix:@"//"])
    return nil;
  NSString *rest =
      [[t substringFromIndex:2] stringByTrimmingCharactersInSet:ws];
  if (![rest hasPrefix:@"#"])
    return nil;
  rest = [rest substringFromIndex:1];
  if (rest.length <= 3)
    return nil; // "#tab" alone names nothing
  if ([[rest substringToIndex:3] caseInsensitiveCompare:@"tab"] !=
      NSOrderedSame)
    return nil;
  // A separator is required, so `#table` / `#tabs` stay ordinary comments.
  if (![ws characterIsMember:[rest characterAtIndex:3]])
    return nil;
  NSString *name =
      [[rest substringFromIndex:4] stringByTrimmingCharactersInSet:ws];
  return name.length ? name : nil;
}

// The known name whose identity matches `marker`, or nil.
static NSString *_Nullable KKCodeTabResolve(NSString *marker,
                                            NSArray<NSString *> *knownNames) {
  NSString *want = KKCodeTabCanonicalName(marker);
  if (!want.length)
    return nil;
  for (NSString *known in knownNames)
    if ([KKCodeTabCanonicalName(known) isEqualToString:want])
      return known;
  return nil;
}

NSDictionary<NSString *, NSString *> *
KKCodeSplitTabbedText(NSString *text, NSArray<NSString *> *knownNames) {
  if (!text.length || knownNames.count == 0)
    return nil;
  NSString *normalized = [[text stringByReplacingOccurrencesOfString:@"\r\n"
                                                          withString:@"\n"]
      stringByReplacingOccurrencesOfString:@"\r"
                                withString:@"\n"];
  NSArray<NSString *> *lines = [normalized componentsSeparatedByString:@"\n"];

  NSCharacterSet *trim = NSCharacterSet.whitespaceAndNewlineCharacterSet;
  NSMutableDictionary<NSString *, NSString *> *out =
      [NSMutableDictionary dictionary];
  NSMutableArray<NSString *> *block = [NSMutableArray array];
  // nil target = the leading block, which belongs to the first known tab
  // (Image) only if it turns out to hold anything. __block so the flush below
  // reads the CURRENT target, not the nil it captured.
  __block NSString *target = nil;
  BOOL sawMarker = NO;

  void (^flush)(void) = ^{
    NSString *body = [[block componentsJoinedByString:@"\n"]
        stringByTrimmingCharactersInSet:trim];
    if (target)
      out[target] = body;
    else if (body.length)
      out[knownNames.firstObject] = body;
    [block removeAllObjects];
  };

  for (NSString *line in lines) {
    NSString *marker = KKCodeTabMarkerName(line);
    if (!marker) {
      [block addObject:line];
      continue;
    }
    NSString *resolved = KKCodeTabResolve(marker, knownNames);
    if (!resolved)
      return nil; // an unknown tab makes the whole paste plain text
    flush();
    target = resolved;
    sawMarker = YES;
  }
  if (!sawMarker)
    return nil;
  flush();
  return out.count ? out : nil;
}
