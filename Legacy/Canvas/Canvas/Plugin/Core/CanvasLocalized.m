/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLocalized.h"

@interface CanvasLocalizationAnchor : NSObject
@end

@implementation CanvasLocalizationAnchor
@end

NSBundle *CanvasLocalizationBundle(void) {
  return [NSBundle bundleForClass:[CanvasLocalizationAnchor class]];
}
