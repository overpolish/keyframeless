/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import "ShaderTypes.h"
#import <IOSurface/IOSurfaceObjC.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

typedef struct {
  double radius;
  double cropTop;
  double cropBottom;
  double cropLeft;
  double cropRight;
} RoundedPluginState;

@implementation RoundedPlugin (Render)

- (BOOL)pluginState:(NSData **)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error {
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
  double radius = 20.0;
  [paramGetAPI getFloatValue:&radius
               fromParameter:kParamRadius
                      atTime:renderTime];

  NSDictionary<NSString *, NSArray<NSNumber *> *> *multiStage =
      [self multiStageValuesAtTime:renderTime];

  double rF = 1.0, cF = 1.0;
  if (!multiStage) {
    KKTimingResult *timing = [self timingAtTime:renderTime];
    double inF = timing.inPhase.factor;
    double holdF = timing.holdPhase.factor;
    double outF = timing.outPhase.factor;

    BOOL inR = YES, inC = YES;
    [paramGetAPI getBoolValue:&inR
                fromParameter:kParamInRadius
                       atTime:renderTime];
    [paramGetAPI getBoolValue:&inC
                fromParameter:kParamInCrop
                       atTime:renderTime];
    BOOL holdR = YES, holdC = YES;
    [paramGetAPI getBoolValue:&holdR
                fromParameter:kParamHoldRadius
                       atTime:renderTime];
    [paramGetAPI getBoolValue:&holdC
                fromParameter:kParamHoldCrop
                       atTime:renderTime];
    BOOL outR = YES, outC = YES;
    [paramGetAPI getBoolValue:&outR
                fromParameter:kParamOutRadius
                       atTime:renderTime];
    [paramGetAPI getBoolValue:&outC
                fromParameter:kParamOutCrop
                       atTime:renderTime];

    rF = (inR ? inF : 1.0) * (holdR ? holdF : 1.0) * (outR ? outF : 1.0);
    cF = (inC ? inF : 1.0) * (holdC ? holdF : 1.0) * (outC ? outF : 1.0);
  }

  RoundedPluginState state;
  NSArray<NSNumber *> *msRadius = multiStage[@"Radius"];
  state.radius = msRadius.count > 0 ? msRadius[0].doubleValue : radius * rF;

  state.cropTop = 0.0;
  state.cropBottom = 0.0;
  state.cropLeft = 0.0;
  state.cropRight = 0.0;
  NSArray<NSNumber *> *msCrop = multiStage[@"Crop"];
  if (msCrop.count >= 4) {
    state.cropTop = msCrop[0].doubleValue;
    state.cropBottom = msCrop[1].doubleValue;
    state.cropLeft = msCrop[2].doubleValue;
    state.cropRight = msCrop[3].doubleValue;
  } else {
    [paramGetAPI getFloatValue:&state.cropTop
                 fromParameter:kParamCropTop
                        atTime:renderTime];
    [paramGetAPI getFloatValue:&state.cropBottom
                 fromParameter:kParamCropBottom
                        atTime:renderTime];
    [paramGetAPI getFloatValue:&state.cropLeft
                 fromParameter:kParamCropLeft
                        atTime:renderTime];
    [paramGetAPI getFloatValue:&state.cropRight
                 fromParameter:kParamCropRight
                        atTime:renderTime];
    state.cropTop *= cF;
    state.cropBottom *= cF;
    state.cropLeft *= cF;
    state.cropRight *= cF;
  }

  *pluginState = [NSData dataWithBytes:&state length:sizeof(state)];
  return (*pluginState != nil);
}

- (BOOL)renderDestinationImage:(FxImageTile *)destinationImage
                  sourceImages:(NSArray<FxImageTile *> *)sourceImages
                   pluginState:(NSData *)pluginState
                        atTime:(CMTime)renderTime
                         error:(NSError *_Nullable *)outError {
  if (!pluginState || !sourceImages[0].ioSurface ||
      !destinationImage.ioSurface) {
    if (outError != NULL) {
      *outError =
          [NSError errorWithDomain:FxPlugErrorDomain
                              code:kFxError_InvalidParameter
                          userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"Invalid plugin state received from host"
                          }];
    }

    return NO;
  }

  RoundedPluginState state;
  [pluginState getBytes:&state length:sizeof(state)];

  id<MTLRenderPipelineState> pipelineState =
      [self pipelineStateForPluginID:kPluginID
                    destinationImage:destinationImage
                        vertexShader:@"vertexShader"
                      fragmentShader:@"fragmentShader"
                           blendMode:KKBlendModePremultipliedAlpha];

  if (!pipelineState)
    return NO;

  float fragmentRadius = (float)state.radius;
  simd_float2 imageSize = {(float)(destinationImage.imagePixelBounds.right -
                                   destinationImage.imagePixelBounds.left),
                           (float)(destinationImage.imagePixelBounds.top -
                                   destinationImage.imagePixelBounds.bottom)};

  simd_float2 tileOffset = {
      roundf((float)(destinationImage.tilePixelBounds.left -
                     destinationImage.imagePixelBounds.left)),
      roundf((float)(destinationImage.tilePixelBounds.bottom -
                     destinationImage.imagePixelBounds.bottom))};

  float cropL = (float)state.cropLeft * imageSize.x;
  float cropR = (float)state.cropRight * imageSize.x;
  float cropB = (float)state.cropBottom * imageSize.y;
  float cropT = (float)state.cropTop * imageSize.y;
  simd_float2 cropCenter = {(cropL - cropR) * 0.5f, (cropB - cropT) * 0.5f};
  simd_float2 cropSize = {imageSize.x - cropL - cropR,
                          imageSize.y - cropB - cropT};

  return [self
      encodeRenderCommandsForDestinationImage:destinationImage
                                 sourceImages:sourceImages
                                     commands:^(
                                         id<MTLRenderCommandEncoder> encoder,
                                         NSArray<id<MTLTexture>>
                                             *inputTextures) {
                                       [encoder setRenderPipelineState:
                                                    pipelineState];
                                       [encoder
                                           setFragmentTexture:inputTextures[0]
                                                      atIndex:
                                                          KKTextureIndex_InputImage];
                                       [encoder
                                           setFragmentBytes:&fragmentRadius
                                                     length:sizeof(
                                                                fragmentRadius)
                                                    atIndex:
                                                        FragmentIndex_Radius];
                                       [encoder
                                           setFragmentBytes:&imageSize
                                                     length:sizeof(imageSize)
                                                    atIndex:
                                                        FragmentIndex_ImageSize];
                                       [encoder
                                           setFragmentBytes:&tileOffset
                                                     length:sizeof(tileOffset)
                                                    atIndex:
                                                        FragmentIndex_TileOffset];
                                       [encoder
                                           setFragmentBytes:&cropCenter
                                                     length:sizeof(cropCenter)
                                                    atIndex:
                                                        FragmentIndex_CropCenter];
                                       [encoder
                                           setFragmentBytes:&cropSize
                                                     length:sizeof(cropSize)
                                                    atIndex:
                                                        FragmentIndex_CropSize];
                                       [encoder
                                           drawPrimitives:
                                               MTLPrimitiveTypeTriangleStrip
                                              vertexStart:0
                                              vertexCount:4];
                                     }];
}

@end
#pragma clang diagnostic pop
