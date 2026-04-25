/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import "ShaderTypes.h"
#import <KeyframelessKit/KeyframelessKit.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation MagicMovePlugin (Animation)

- (MagicMovePointValues)readPointValuesAtTime:(CMTime)time
                                      withAPI:
                                          (id<FxParameterRetrievalAPI_v6>)api {
  MagicMovePointValues v = {
      .x = 0.5, .y = 0.5, .scaleX = 1, .scaleY = 1, .opacity = 1};
  [api getXValue:&v.x YValue:&v.y fromParameter:kParamPoint atTime:time];
  [api getFloatValue:&v.rotation fromParameter:kParamRotation atTime:time];
  [api getFloatValue:&v.rotationX fromParameter:kParamRotationX atTime:time];
  [api getFloatValue:&v.rotationY fromParameter:kParamRotationY atTime:time];
  [api getFloatValue:&v.scaleX fromParameter:kParamScale atTime:time];
  [api getFloatValue:&v.scaleY fromParameter:kParamScaleY atTime:time];
  [api getFloatValue:&v.opacity fromParameter:kParamOpacity atTime:time];
  return v;
}

- (BOOL)pluginState:(NSData **)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error {
  [self updateParameterVisibilityAtTime:renderTime];

  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (paramGetAPI == nil) {
    if (error != NULL) {
      *error =
          [NSError errorWithDomain:FxPlugErrorDomain
                              code:kFxError_ThirdPartyDeveloperStart + 20
                          userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"Unable to retrieve FxParameterRetrievalAPI_v6"
                          }];
    }
    return NO;
  }

  double anchorX = 0.5, anchorY = 0.5;
  [paramGetAPI getXValue:&anchorX
                  YValue:&anchorY
           fromParameter:kParamAnchorPoint
                  atTime:renderTime];

  MagicMovePointValues v = [self readPointValuesAtTime:renderTime
                                               withAPI:paramGetAPI];

  NSDictionary<NSString *, NSArray<NSNumber *> *> *multiStage =
      [self multiStageValuesAtTime:renderTime];

  NSArray<NSNumber *> *msPosition = multiStage[@"Position"];
  NSArray<NSNumber *> *msScale = multiStage[@"Scale"];
  NSArray<NSNumber *> *msRotZ = multiStage[@"Rotation Z"];
  NSArray<NSNumber *> *msRotX = multiStage[@"Rotation X"];
  NSArray<NSNumber *> *msRotY = multiStage[@"Rotation Y"];
  NSArray<NSNumber *> *msOpacity = multiStage[@"Opacity"];

  double posX = msPosition.count >= 1 ? msPosition[0].doubleValue : v.x;
  double posY = msPosition.count >= 2 ? msPosition[1].doubleValue : v.y;
  BOOL rotateWithMotion = NO;
  if (msPosition.count >= 3) {
    rotateWithMotion = msPosition[2].doubleValue >= 0.5;
  } else {
    [paramGetAPI getBoolValue:&rotateWithMotion
                fromParameter:kParamRotateWithMotion
                       atTime:renderTime];
  }
  double scaleX = msScale.count >= 1 ? msScale[0].doubleValue : v.scaleX;
  double scaleY = msScale.count >= 2 ? msScale[1].doubleValue : v.scaleY;
  double rotZ = msRotZ.count >= 1 ? msRotZ[0].doubleValue : v.rotation;
  double rotX = msRotX.count >= 1 ? msRotX[0].doubleValue : v.rotationX;
  double rotY = msRotY.count >= 1 ? msRotY[0].doubleValue : v.rotationY;
  double opacity = msOpacity.count >= 1 ? msOpacity[0].doubleValue : v.opacity;

  if (rotateWithMotion) {
    double window = 1.0 / 12.0;
    CMTime tPrev =
        CMTimeSubtract(renderTime, CMTimeMakeWithSeconds(window, 600));
    NSDictionary<NSString *, NSArray<NSNumber *> *> *prev =
        [self multiStageValuesAtTime:tPrev];
    NSArray<NSNumber *> *prevPos = prev[@"Position"];
    double prevX = prevPos.count >= 1 ? prevPos[0].doubleValue : posX;
    double vx = (posX - prevX) / window;
    rotZ -= vx * 5.0 * (M_PI / 180.0);
  }

  MagicMoveParams params;
  params.translate = (simd_float2){(float)(posX - 0.5), (float)(posY - 0.5)};
  params.anchorOffset =
      (simd_float2){(float)(anchorX - 0.5), (float)(anchorY - 0.5)};
  params.rotation = (float)rotZ;
  params.rotationX = (float)rotX;
  params.rotationY = (float)rotY;
  params.scaleX = (float)scaleX;
  params.scaleY = (float)scaleY;
  params.opacity = (float)opacity;

  *pluginState = [NSData dataWithBytes:&params length:sizeof(params)];
  return (*pluginState != nil);
}

@end
#pragma clang diagnostic pop
