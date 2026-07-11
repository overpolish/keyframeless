/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "ShaderLocalized.h"

@interface ShaderLocalizationAnchor : NSObject
@end

@implementation ShaderLocalizationAnchor
@end

NSBundle *ShaderLocalizationBundle(void) {
  return [NSBundle bundleForClass:[ShaderLocalizationAnchor class]];
}
