/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKRectBorderOSC.h"
#import <FxPlug/FxPlugSDK.h>

@implementation KKRectBorderOSC

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    _borderColor = (simd_float4){1.0f, 1.0f, 1.0f, 0.6f};
    _lineHalfWidth = 2.0f;
    _ghostAlpha = 1.0f;
  }
  return self;
}

- (void)drawWithTopRight:(CGPoint)topRight
              bottomLeft:(CGPoint)bottomLeft
        destinationImage:(FxImageTile *)destinationImage {
  CGPoint topLeft = {bottomLeft.x, topRight.y};
  CGPoint bottomRight = {topRight.x, bottomLeft.y};
  simd_float4 c = _borderColor;
  c.w *= _ghostAlpha;

  [self drawLineFrom:topLeft
                    to:topRight
                 color:c
             halfWidth:_lineHalfWidth
      destinationImage:destinationImage];
  [self drawLineFrom:topRight
                    to:bottomRight
                 color:c
             halfWidth:_lineHalfWidth
      destinationImage:destinationImage];
  [self drawLineFrom:bottomRight
                    to:bottomLeft
                 color:c
             halfWidth:_lineHalfWidth
      destinationImage:destinationImage];
  [self drawLineFrom:bottomLeft
                    to:topLeft
                 color:c
             halfWidth:_lineHalfWidth
      destinationImage:destinationImage];
}

@end
