/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MagicMoveLocalized.h"

@interface MagicMoveLocalizationAnchor : NSObject
@end

@implementation MagicMoveLocalizationAnchor
@end

NSBundle *MagicMoveLocalizationBundle(void) {
  return [NSBundle bundleForClass:[MagicMoveLocalizationAnchor class]];
}
