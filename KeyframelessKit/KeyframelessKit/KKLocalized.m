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

NSString *KKPlainLaneLabel(NSString *label) {
  // A lane label may be suffixed with U+001F (unit separator) + an owner id to
  // make it unique across owners in a merged multi-owner timeline (e.g. Canvas
  // per-layer lanes, where every layer has a "Scale" lane). Strip to the name
  // before the separator; identity (the full label) stays unique for the kit's
  // label-based lane lookups.
  if (label.length == 0)
    return label;
  NSRange sep = [label rangeOfString:@"\x1f"];
  return sep.location == NSNotFound ? label
                                    : [label substringToIndex:sep.location];
}

NSString *KKLocalizedParamName(NSString *englishName) {
  if (englishName.length == 0)
    return englishName;
  // Display only the name before the owner-id separator so the row still reads
  // "Scale".
  englishName = KKPlainLaneLabel(englishName);
  return [KKLocalizationBundle() localizedStringForKey:englishName
                                                 value:englishName
                                                 table:@"KKParamNames"];
}

NSString *KKTruncatedLayerName(NSString *name) {
  static const NSUInteger kMaxLayerNameChars = 15;
  if (name.length <= kMaxLayerNameChars)
    return name;
  return
      [[name substringToIndex:kMaxLayerNameChars] stringByAppendingString:@"…"];
}
