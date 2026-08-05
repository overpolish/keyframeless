/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageLocalized.h"

@interface MirageLocalizationAnchor : NSObject
@end

@implementation MirageLocalizationAnchor
@end

NSBundle *MirageLocalizationBundle(void) {
  return [NSBundle bundleForClass:[MirageLocalizationAnchor class]];
}
