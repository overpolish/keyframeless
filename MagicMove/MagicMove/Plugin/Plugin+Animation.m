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

  MagicMoveParams params;
  params.translate = (simd_float2){(float)(v.x - 0.5), (float)(v.y - 0.5)};
  params.anchorOffset =
      (simd_float2){(float)(anchorX - 0.5), (float)(anchorY - 0.5)};
  params.rotation = (float)v.rotation;
  params.rotationX = (float)v.rotationX;
  params.rotationY = (float)v.rotationY;
  params.scaleX = (float)v.scaleX;
  params.scaleY = (float)v.scaleY;
  params.opacity = (float)v.opacity;

  *pluginState = [NSData dataWithBytes:&params length:sizeof(params)];
  return (*pluginState != nil);
}

@end
#pragma clang diagnostic pop
