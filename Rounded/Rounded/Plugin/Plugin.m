/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Plugin.h"
#import "Constants.h"
#import "ShaderTypes.h"
#import <AppKit/AppKit.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceObjC.h>
#import <KeyframelessKit/KeyframelessKit.h>
#import <QuartzCore/QuartzCore.h>

typedef struct {
  double radius;
  double cropTop;
  double cropBottom;
  double cropLeft;
  double cropRight;
} RoundedPluginState;

@implementation RoundedPlugin {
  KKLog *_log;
}

- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)newApiManager;
{
  _log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless"];
  [_log info:@"RoundedPlugin: initWithAPIManager called - plugin is loading"];
  self = [super initWithAPIManager:newApiManager];
  if (self != nil) {
    [_log info:@"RoundedPlugin: Successfully initialized"];
  }
  return self;
}

- (BOOL)properties:(NSDictionary *_Nonnull *)properties
             error:(NSError *_Nullable *)error {
  *properties = @{
    kFxPropertyKey_MayRemapTime : @NO,
    kFxPropertyKey_PixelTransformSupport : @(kFxPixelTransform_ScaleTranslate),
    kFxPropertyKey_VariesWhenParamsAreStatic : @YES
  };

  return YES;
}

- (BOOL)addParametersWithError:(NSError **)error {
  id<FxParameterCreationAPI_v5> paramAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterCreationAPI_v5)];
  if (paramAPI == nil) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:FxPlugErrorDomain
                                   code:kFxError_APIUnavailable
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Unable to obtain an FxPlug API Object"
                               }];
    }

    return NO;
  }

  if (![self addUpdateBannerParameterWithAPI:paramAPI error:error]) {
    return NO;
  }

  if (![paramAPI addFloatSliderWithName:@"Radius"
                            parameterID:kParamRadius
                           defaultValue:20.0
                           parameterMin:0.0
                           parameterMax:100.0
                              sliderMin:0.0
                              sliderMax:100.0
                                  delta:1.0
                         parameterFlags:kFxParameterFlag_DEFAULT]) {
    if (error != NULL) {
      *error = [NSError
          errorWithDomain:FxPlugErrorDomain
                     code:kFxError_InvalidParameter
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"Unable to add radius slider"
                 }];
    }

    return NO;
  }

  if (![paramAPI
          addCustomParameterWithName:@""
                         parameterID:kParamCropGroup
                        defaultValue:@(kParamCropGroup)
                      parameterFlags:kFxParameterFlag_NOT_ANIMATABLE |
                                     kFxParameterFlag_CUSTOM_UI |
                                     kFxParameterFlag_USE_FULL_VIEW_WIDTH]) {
    return NO;
  }

  if (![paramAPI addToggleButtonWithName:@""
                             parameterID:kParamCropExpanded
                            defaultValue:NO
                          parameterFlags:kFxParameterFlag_HIDDEN |
                                         kFxParameterFlag_NOT_ANIMATABLE]) {
    return NO;
  }

  if (![paramAPI addPercentSliderWithName:@"Top"
                              parameterID:kParamCropTop
                             defaultValue:0.0
                             parameterMin:0.0
                             parameterMax:1.0
                                sliderMin:0.0
                                sliderMax:1.0
                                    delta:0.001
                           parameterFlags:kFxParameterFlag_HIDDEN]) {
    return NO;
  }

  if (![paramAPI addPercentSliderWithName:@"Bottom"
                              parameterID:kParamCropBottom
                             defaultValue:0.0
                             parameterMin:0.0
                             parameterMax:1.0
                                sliderMin:0.0
                                sliderMax:1.0
                                    delta:0.001
                           parameterFlags:kFxParameterFlag_HIDDEN]) {
    return NO;
  }

  if (![paramAPI addPercentSliderWithName:@"Left"
                              parameterID:kParamCropLeft
                             defaultValue:0.0
                             parameterMin:0.0
                             parameterMax:1.0
                                sliderMin:0.0
                                sliderMax:1.0
                                    delta:0.001
                           parameterFlags:kFxParameterFlag_HIDDEN]) {
    return NO;
  }

  if (![paramAPI addPercentSliderWithName:@"Right"
                              parameterID:kParamCropRight
                             defaultValue:0.0
                             parameterMin:0.0
                             parameterMax:1.0
                                sliderMin:0.0
                                sliderMax:1.0
                                    delta:0.001
                           parameterFlags:kFxParameterFlag_HIDDEN]) {
    return NO;
  }

  if (![self addAnimationParametersWithAPI:paramAPI error:error]) {
    return NO;
  }

  return YES;
}

- (BOOL)parameterChanged:(UInt32)parameterID
                  atTime:(CMTime)time
                   error:(NSError **)error {
  [self updateTimingParameterVisibility];
  [self updateCropParameterVisibility];
  return YES;
}

- (void)updateCropParameterVisibility {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!paramGetAPI || !paramSetAPI)
    return;

  BOOL expanded = NO;
  [paramGetAPI getBoolValue:&expanded
              fromParameter:kParamCropExpanded
                     atTime:kCMTimeZero];

  [paramSetAPI setParameterFlags:kFxParameterFlag_HIDDEN
                     toParameter:kParamCropExpanded];

  FxParameterFlags flags =
      expanded ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN;
  [paramSetAPI setParameterFlags:flags toParameter:kParamCropTop];
  [paramSetAPI setParameterFlags:flags toParameter:kParamCropBottom];
  [paramSetAPI setParameterFlags:flags toParameter:kParamCropLeft];
  [paramSetAPI setParameterFlags:flags toParameter:kParamCropRight];
}

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

  KKTimingResult *timing = [self timingAtTime:renderTime];
  double effectiveRadius = radius * timing.inPhase.factor *
                           timing.holdPhase.factor * timing.outPhase.factor;

  RoundedPluginState state;
  state.radius = effectiveRadius;
  state.cropTop = 0.0;
  state.cropBottom = 0.0;
  state.cropLeft = 0.0;
  state.cropRight = 0.0;
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

  *pluginState = [NSData dataWithBytes:&state length:sizeof(state)];
  return (*pluginState != nil);
}

- (BOOL)destinationImageRect:(FxRect *)destinationImageRect
                sourceImages:(NSArray<FxImageTile *> *)sourceImages
            destinationImage:(nonnull FxImageTile *)destinationImage
                 pluginState:(NSData *)pluginState
                      atTime:(CMTime)renderTime
                       error:(NSError *_Nullable *)outError {
  if (sourceImages.count < 1) {
    [_log error:@"No inputImages list"];
    return NO;
  }

  // In the case of a filter that only changed RGB values,
  // the output rect is the same as the input rect.
  *destinationImageRect = sourceImages[0].imagePixelBounds;

  return YES;
}

- (BOOL)sourceTileRect:(FxRect *)sourceTileRect
       sourceImageIndex:(NSUInteger)sourceImageIndex
           sourceImages:(NSArray<FxImageTile *> *)sourceImages
    destinationTileRect:(FxRect)destinationTileRect
       destinationImage:(FxImageTile *)destinationImage
            pluginState:(NSData *)pluginState
                 atTime:(CMTime)renderTime
                  error:(NSError *_Nullable *)outError {
  *sourceTileRect = destinationTileRect;
  return YES;
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

  // Crop bounding box from edge insets (percentage of image size)
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
