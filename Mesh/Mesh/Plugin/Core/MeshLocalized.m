/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MeshLocalized.h"

@interface MeshLocalizationAnchor : NSObject
@end

@implementation MeshLocalizationAnchor
@end

NSBundle *MeshLocalizationBundle(void) {
  return [NSBundle bundleForClass:[MeshLocalizationAnchor class]];
}
