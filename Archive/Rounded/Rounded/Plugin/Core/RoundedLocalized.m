/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "RoundedLocalized.h"

@interface RoundedLocalizationAnchor : NSObject
@end

@implementation RoundedLocalizationAnchor
@end

NSBundle *RoundedLocalizationBundle(void) {
  return [NSBundle bundleForClass:[RoundedLocalizationAnchor class]];
}
