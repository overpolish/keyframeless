/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKOSCVisibilityDefaults.h"

static NSString *const kOSCHiddenField = @"oscHidden";

NSSet<NSString *> *KKOSCVisibilityDefaultsRead(NSString *scope) {
  id raw = KKScopedDefaultRead(kOSCHiddenField, scope);
  if (![raw isKindOfClass:[NSArray class]])
    return nil;
  NSMutableSet<NSString *> *hidden = [NSMutableSet set];
  for (id key in (NSArray *)raw)
    if ([key isKindOfClass:[NSString class]])
      [hidden addObject:key];
  return hidden;
}

void KKOSCVisibilityDefaultsWrite(NSSet<NSString *> *hiddenKeys,
                                  NSString *scope) {
  // Sorted so the stored plist is stable and diffable; an empty set is a real
  // default ("everything visible"), not an absence, so it is written as an
  // empty array rather than cleared.
  NSArray<NSString *> *keys =
      [hiddenKeys.allObjects sortedArrayUsingSelector:@selector(compare:)];
  KKScopedDefaultWrite(keys ?: @[], kOSCHiddenField, scope);
}
