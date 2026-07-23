/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "GlowLocalized.h"

@interface GlowLocalizationAnchor : NSObject
@end

@implementation GlowLocalizationAnchor
@end

NSBundle *GlowLocalizationBundle(void) {
  return [NSBundle bundleForClass:[GlowLocalizationAnchor class]];
}
