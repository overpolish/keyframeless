/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "OSC.h"
#import "Constants.h"
#import <FxPlug/FxPlugSDK.h>

#define CLAMP(x, lo, hi) MAX((lo), MIN((hi), (x)))

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

@implementation RoundedOSC {
  CGPoint _dragStartPosition;
  double _dragStartRadius;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager {
  self = [super initWithAPIManager:apiManager];
  if (self) {
    self.clearsOnDraw = NO;

    KKCropOSC *crop = [[KKCropOSC alloc] initWithAPIManager:apiManager];
    crop.cropTopParam = kParamCropTop;
    crop.cropBottomParam = kParamCropBottom;
    crop.cropLeftParam = kParamCropLeft;
    crop.cropRightParam = kParamCropRight;
    self.cropOSC = crop;
  }
  return self;
}

- (CGPoint)oscPositionAtTime:(CMTime)time {
  CGPoint topRight = {0, 0}, bottomLeft = {0, 0};
  if (![self.cropOSC getTopRight:&topRight
                      bottomLeft:&bottomLeft
                 fullImageCanvas:NULL
                          atTime:time])
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
    [paramGetAPI getFloatValue:&paramRadius
                 fromParameter:kParamRadius
                        atTime:time];
    padding = paddingForRadius(paramRadius, minDim);
  }

  float offsetX =
      isFlippedX ? -(self.oscSize + padding) : (self.oscSize + padding);
  float offsetY =
      isFlippedY ? -(self.oscSize + padding) : (self.oscSize + padding);

  return CGPointMake(topRight.x - offsetX, topRight.y - offsetY);
}

- (void)drawOSCWithWidth:(NSInteger)width
                  height:(NSInteger)height
              activePart:(NSInteger)activePart
        destinationImage:(FxImageTile *)destinationImage
                  atTime:(CMTime)time {
  [KKPlugin multiStageFlushPendingLanes];

  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  if (timingAPI) {
    CMTime effectStart = kCMTimeZero, effectDuration = kCMTimeZero;
    [timingAPI startTimeForEffect:&effectStart];
    [timingAPI durationTimeForEffect:&effectDuration];
    double durSec = CMTimeGetSeconds(effectDuration);
    if (durSec > 0) {
      double startSec = CMTimeGetSeconds(effectStart);
      double nowSec = CMTimeGetSeconds(time);
      double frac = (nowSec - startSec) / durSec;
      [KKPlugin multiStageUpdatePlayhead:frac duration:durSec];
    }
  }

  [self encodeRenderCommandsForDestinationImage:destinationImage
                                 canvasPosition:CGPointZero
                               clearDestination:YES
                                       commands:^(id<MTLRenderCommandEncoder> e,
                                                  CGPoint p, simd_uint2 v){
                                       }];

  [self.cropOSC drawWithDestinationImage:destinationImage atTime:time];

  CGPoint radiusPos = [self oscPositionAtTime:time];
  [self drawAtCanvasPosition:radiusPos
                   isHovered:(activePart == kOSCRadiusPart)
                    isActive:self.isDragging && (activePart == kOSCRadiusPart)
            destinationImage:destinationImage
                      atTime:time];
}

- (void)hitTestOSCAtMousePositionX:(double)positionX
                    mousePositionY:(double)positionY
                        activePart:(NSInteger *)activePart
                            atTime:(CMTime)time {
  *activePart = 0;

  NSInteger cropPart = [self.cropOSC hitTestAtMousePositionX:positionX
                                                   positionY:positionY
                                                      atTime:time];
  if (cropPart != KKCropPartNone) {
    *activePart = cropPart;
  }

  if ([self hitTestAtMousePositionX:positionX
                          positionY:positionY
                             atTime:time]) {
    *activePart = kOSCRadiusPart;
  }
}

- (void)mouseDownAtPositionX:(double)positionX
                   positionY:(double)positionY
                  activePart:(NSInteger)activePart
                   modifiers:(NSUInteger)modifiers
                 forceUpdate:(BOOL *)forceUpdate
                      atTime:(CMTime)time {
  if (activePart == KKCropPartRect ||
      (activePart >= KKCropPartPointBase &&
       activePart < KKCropPartPointBase + KKCropPointCount)) {
    [self.cropOSC mouseDownForPart:activePart
                         positionX:positionX
                         positionY:positionY
                            atTime:time];
    *forceUpdate = YES;
    return;
  }

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
    [paramGetAPI getFloatValue:&_dragStartRadius
                 fromParameter:kParamRadius
                        atTime:time];
  }
}

- (void)mouseDraggedAtPositionX:(double)positionX
                      positionY:(double)positionY
                     activePart:(NSInteger)activePart
                      modifiers:(NSUInteger)modifiers
                    forceUpdate:(BOOL *)forceUpdate
                         atTime:(CMTime)time {
  if (activePart == KKCropPartRect ||
      (activePart >= KKCropPartPointBase &&
       activePart < KKCropPartPointBase + KKCropPointCount)) {
    [self.cropOSC mouseDraggedForPart:activePart
                            positionX:positionX
                            positionY:positionY
                          forceUpdate:forceUpdate
                               atTime:time];
    return;
  }

  if (activePart == 0)
    return;

  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!paramSetAPI)
    return;

  CGPoint topRight = {0, 0}, bottomLeft = {0, 0};
  if (![self.cropOSC getTopRight:&topRight
                      bottomLeft:&bottomLeft
                 fullImageCanvas:NULL
                          atTime:time])
    return;

  float canvasImageWidth = topRight.x - bottomLeft.x;
  float canvasImageHeight = topRight.y - bottomLeft.y;
  float minDim = fminf(fabsf(canvasImageWidth), fabsf(canvasImageHeight));
  BOOL isFlippedX = canvasImageWidth < 0;
  BOOL isFlippedY = canvasImageHeight < 0;

  double dx = positionX - topRight.x;
  double dy = positionY - topRight.y;
  double signX = isFlippedX ? -1.0 : 1.0;
  double signY = isFlippedY ? -1.0 : 1.0;

  double mouseDist = (-dx * signX + -dy * signY) * 0.5 - self.oscSize;

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
  [paramSetAPI setFloatValue:newRadius toParameter:kParamRadius atTime:time];
  *forceUpdate = YES;
}

- (void)mouseUpAtPositionX:(double)positionX
                 positionY:(double)positionY
                activePart:(NSInteger)activePart
                 modifiers:(NSUInteger)modifiers
               forceUpdate:(BOOL *)forceUpdate
                    atTime:(CMTime)time {
  [self.cropOSC mouseUp];
  [super mouseUpAtPositionX:positionX
                  positionY:positionY
                 activePart:activePart
                  modifiers:modifiers
                forceUpdate:forceUpdate
                     atTime:time];
}

@end
