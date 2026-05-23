/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLocalized.h"

@interface KKLocalizationAnchor : NSObject
@end

@implementation KKLocalizationAnchor
@end

NSBundle *KKLocalizationBundle(void) {
  return [NSBundle bundleForClass:[KKLocalizationAnchor class]];
}

NSString *KKLocalizedParamName(NSString *englishName) {
  if (englishName.length == 0)
    return englishName;
  return [KKLocalizationBundle() localizedStringForKey:englishName
                                                 value:englishName
                                                 table:@"KKParamNames"];
}
