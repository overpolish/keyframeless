/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC.h"
#import "Constants.h"
#import <FxPlug/FxPlugSDK.h>

#define CLAMP(x, lo, hi) MAX((lo), MIN((hi), (x)))

/// Computes canvas-space padding offset for a given radius value and image
/// size. Matches squicle/circle inset geometry used to position the OSC.
static float paddingForRadius(double radius, float minDim) {
  float t = radius / 100.0f;
  float power = 5.0f * (1.0f - t) + 2.0f * t;
  float cornerRadiusPixels = minDim * 0.5f * t;
  float circleInsetFactor = 1.0f - 1.0f / sqrtf(2.0f);
  float squircleInsetFactor = 1.0f - 1.0f / powf(2.0f, 1.0f / power);
  float insetFactor = squircleInsetFactor * (1.0f - t) + circleInsetFactor * t;
  float squircleCorrection = 1.0f - 0.22f * sinf(t * M_PI);
  return minDim * 0.05f + cornerRadiusPixels * insetFactor * squircleCorrection;
}

/// Fetches crop-adjusted corner geometry in canvas space.
/// The crop parameters define a sub-rectangle of the image; the returned
/// corners reflect that bounding box.
/// @returns NO if API is unavailable.
static BOOL getCornerPoints(id<PROAPIAccessing> apiManager, CGPoint *topRight,
                            CGPoint *bottomLeft, CMTime time) {
  id<FxOnScreenControlAPI_v4> oscAPI =
      [apiManager apiForProtocol:@protocol(FxOnScreenControlAPI_v4)];
  if (!oscAPI)
    return NO;

  // Get full image corners in canvas space
  CGPoint fullTR = {0, 0}, fullBL = {0, 0};
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:1.0
                          fromY:1.0
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&fullTR.x
                            toY:&fullTR.y];
  [oscAPI convertPointFromSpace:kFxDrawingCoordinates_OBJECT
                          fromX:0.0
                          fromY:0.0
                        toSpace:kFxDrawingCoordinates_CANVAS
                            toX:&fullBL.x
                            toY:&fullBL.y];

  // Read crop edge insets
  double cropTop = 0.0, cropBottom = 0.0, cropLeft = 0.0, cropRight = 0.0;
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (paramGetAPI) {
    [paramGetAPI getFloatValue:&cropTop
                 fromParameter:kParamCropTop
                        atTime:time];
    [paramGetAPI getFloatValue:&cropBottom
                 fromParameter:kParamCropBottom
                        atTime:time];
    [paramGetAPI getFloatValue:&cropLeft
                 fromParameter:kParamCropLeft
                        atTime:time];
    [paramGetAPI getFloatValue:&cropRight
                 fromParameter:kParamCropRight
                        atTime:time];
  }

  // Apply edge insets to canvas corners
  float canvasW = fullTR.x - fullBL.x;
  float canvasH = fullTR.y - fullBL.y;
  topRight->x = fullTR.x - cropRight * canvasW;
  topRight->y = fullTR.y - cropTop * canvasH;
  bottomLeft->x = fullBL.x + cropLeft * canvasW;
  bottomLeft->y = fullBL.y + cropBottom * canvasH;

  return YES;
}

@implementation RoundedOSC {
  CGPoint _dragStartPosition;
  double _dragStartRadius;
}

- (CGPoint)oscPositionAtTime:(CMTime)time {
  CGPoint topRight = {0, 0}, bottomLeft = {0, 0};
  if (!getCornerPoints(self.apiManager, &topRight, &bottomLeft, time))
    return CGPointZero;

  float canvasImageWidth = topRight.x - bottomLeft.x;
  float canvasImageHeight = topRight.y - bottomLeft.y;
  BOOL isFlippedX = canvasImageWidth < 0;
  BOOL isFlippedY = canvasImageHeight < 0;
  float minDim = fminf(fabsf(canvasImageWidth), fabsf(canvasImageHeight));

  float padding = 0.0f;
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (paramGetAPI) {
    double paramRadius = 0.0;
    [paramGetAPI getFloatValue:&paramRadius fromParameter:1 atTime:time];
    padding = paddingForRadius(paramRadius, minDim);
  }

  float offsetX =
      isFlippedX ? -(self.oscSize + padding) : (self.oscSize + padding);
  float offsetY =
      isFlippedY ? -(self.oscSize + padding) : (self.oscSize + padding);

  return CGPointMake(topRight.x - offsetX, topRight.y - offsetY);
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  [super mouseDownAtPositionX:positionX
                    positionY:positionY
                   activePart:activePart
                    modifiers:modifiers
                  forceUpdate:forceUpdate
                       atTime:time];

  if (activePart == 0)
    return;

  _dragStartPosition = CGPointMake(positionX, positionY);

  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (paramGetAPI) {
    [paramGetAPI getFloatValue:&_dragStartRadius fromParameter:1 atTime:time];
  }
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

  CGPoint topRight = {0, 0}, bottomLeft = {0, 0};
  if (!getCornerPoints(self.apiManager, &topRight, &bottomLeft, time))
    return;

  float canvasImageWidth = topRight.x - bottomLeft.x;
  float canvasImageHeight = topRight.y - bottomLeft.y;
  float minDim = fminf(fabsf(canvasImageWidth), fabsf(canvasImageHeight));
  BOOL isFlippedX = canvasImageWidth < 0;
  BOOL isFlippedY = canvasImageHeight < 0;

  // Use signed distance along the diagonal axis
  double dx = positionX - topRight.x;
  double dy = positionY - topRight.y;
  double signX = isFlippedX ? -1.0 : 1.0;
  double signY = isFlippedY ? -1.0 : 1.0;

  // Projected distance from corner to mouse along the OSC's diagonal axis,
  // minus oscSize since padding(t) is what we're solving for, not the full
  // offset.
  double mouseDist = (-dx * signX + -dy * signY) * 0.5 - self.oscSize;

  // Binary search for t such that padding(t) == mouseDist
  float lo = 0.0f, hi = 100.0f;
  for (int i = 0; i < 32; i++) {
    float mid = (lo + hi) * 0.5f;
    float padding = paddingForRadius(mid, minDim);

    if (padding < mouseDist)
      lo = mid;
    else
      hi = mid;
  }

  double newRadius = CLAMP((lo + hi) * 0.5, 0.0, 100.0);
  [paramSetAPI setFloatValue:newRadius toParameter:1 atTime:time];
  *forceUpdate = YES;
}

@end
