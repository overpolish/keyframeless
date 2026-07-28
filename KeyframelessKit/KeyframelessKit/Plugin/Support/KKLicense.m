/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLicense.h"

NSString *const KKLicenseProductMirage = @"mirage";
NSString *const KKLicenseProductCanvas = @"canvas";
NSString *const KKLicenseProductSteno = @"steno";

BOOL KKLicenseIsActivated(NSString *productID) {
  if (productID.length == 0)
    return NO;
  // The suite is re-created per call on purpose: Foundation caches suite
  // domains via cfprefsd, so this stays cheap while still observing an
  // activation written from another process (the inspector ViewBridge).
  NSUserDefaults *suite = [[NSUserDefaults alloc]
      initWithSuiteName:@"group.com.keyframeless"];
  NSDictionary *record = [suite
      dictionaryForKey:[NSString
                           stringWithFormat:@"com.keyframeless.license.%@",
                                            productID]];
  NSString *key = record[@"key"];
  return [key isKindOfClass:[NSString class]] && key.length > 0;
}
