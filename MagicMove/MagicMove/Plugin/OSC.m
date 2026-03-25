/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC.h"
#import <FxPlug/FxPlugSDK.h>

#define CLAMP(x, lo, hi) MAX((lo), MIN((hi), (x)))

static BOOL getCenterAndMinDim(id<PROAPIAccessing> apiManager, CGPoint *center,
                               float *minDim) {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return NO;

  CGPoint topRight, bottomLeft;
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:1.0
                          fromY:1.0
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&topRight.x
                            toY:&topRight.y];
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:0.0
                          fromY:0.0
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&bottomLeft.x
                            toY:&bottomLeft.y];

  *center = CGPointMake((topRight.x + bottomLeft.x) / 2.0,
                        (topRight.y + bottomLeft.y) / 2.0);
  *minDim =
      fminf(fabsf(topRight.x - bottomLeft.x), fabsf(topRight.y - bottomLeft.y));
  return YES;
}

@implementation MagicMoveOSC

- (CGPoint)oscPositionAtTime:(CMTime)time {
  CGPoint center;
  float minDim;
  if (!getCenterAndMinDim(self.apiManager, &center, &minDim))
    return CGPointZero;
  return center;
}

- (void)mouseDraggedAtPositionX:(double)positionX
                      positionY:(double)positionY
                     activePart:(NSInteger)activePart
                      modifiers:(NSUInteger)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {
  if (activePart == 0)
    return;

  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!paramSetAPI)
    return;

  CGPoint center;
  float minDim;
  if (!getCenterAndMinDim(self.apiManager, &center, &minDim))
    return;

  double dx = positionX - center.x;
  double dy = positionY - center.y;
  double dist = sqrt(dx * dx + dy * dy);
  double newRadius = CLAMP(dist / (minDim * 0.5) * 100.0, 0.0, 100.0);

  [paramSetAPI setFloatValue:newRadius toParameter:1 atTime:time];
  *forceUpdate = YES;
}

@end
