/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKColor.h"
#import <stdlib.h>

@implementation KKColorResult {
  simd_float3 _lutStorage[KK_GRADIENT_LUT_SIZE];
}

+ (instancetype)resultWithMode:(KKColorMode)mode
                    solidColor:(simd_float3)solidColor {
  KKColorResult *r = [[KKColorResult alloc] init];
  r->_mode = mode;
  r->_solidColor = solidColor;
  return r;
}

+ (instancetype)resultWithGradientLUT:(simd_float3 *)lut {
  KKColorResult *r = [[KKColorResult alloc] init];
  r->_mode = KKColorModeGradient;
  r->_solidColor = (simd_float3){1, 1, 1};
  memcpy(r->_lutStorage, lut, sizeof(r->_lutStorage));
  return r;
}

- (const simd_float3 *)gradientLUT {
  return _lutStorage;
}

@end
