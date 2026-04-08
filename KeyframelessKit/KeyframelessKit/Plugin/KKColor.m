/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKColor.h"

@implementation KKColorResult

+ (instancetype)resultWithMode:(KKColorMode)mode
                    solidColor:(simd_float3)solidColor
                 gradientStops:(NSArray<KKGradientStop *> *)stops {
  KKColorResult *r = [[KKColorResult alloc] init];
  r->_mode = mode;
  r->_solidColor = solidColor;
  r->_gradientStops = [stops copy];
  return r;
}

@end
