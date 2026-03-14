/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Plugin.h"
#import "Constants.h"
#import "ShaderTypes.h"
#import <AppKit/NSView.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceObjC.h>
#import <KeyframelessKit/KeyframelessKit.h>
#import <QuartzCore/QuartzCore.h>

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

  if (![paramAPI addFloatSliderWithName:@"Radius"
                            parameterID:1
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

  if (![paramAPI addToggleButtonWithName:@"Animate In"
                             parameterID:2
                            defaultValue:NO
                          parameterFlags:kFxParameterFlag_DEFAULT]) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:FxPlugErrorDomain
                                   code:kFxError_InvalidParameter
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Unable to add animate in toggle"
                               }];
    }

    return NO;
  }

  if (![paramAPI addToggleButtonWithName:@"Animate Out"
                             parameterID:3
                            defaultValue:NO
                          parameterFlags:kFxParameterFlag_DEFAULT]) {
    if (error != NULL) {
      *error = [NSError errorWithDomain:FxPlugErrorDomain
                                   code:kFxError_InvalidParameter
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Unable to add animate out toggle"
                               }];
    }

    return NO;
  }

  if (![paramAPI addFloatSliderWithName:@"Duration"
                            parameterID:4
                           defaultValue:0.5
                           parameterMin:0.1
                           parameterMax:2.0
                              sliderMin:0.1
                              sliderMax:2.0
                                  delta:0.1
                         parameterFlags:kFxParameterFlag_DEFAULT]) {
    if (error != NULL) {
      *error = [NSError
          errorWithDomain:FxPlugErrorDomain
                     code:kFxError_InvalidParameter
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"Unable to add duration slider"
                 }];
    }

    return NO;
  }

  return YES;
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
  [paramGetAPI getFloatValue:&radius fromParameter:1 atTime:renderTime];

  BOOL animateIn = NO;
  BOOL animateOut = NO;
  [paramGetAPI getBoolValue:&animateIn fromParameter:2 atTime:renderTime];
  [paramGetAPI getBoolValue:&animateOut fromParameter:3 atTime:renderTime];

  double animDurationParam = 0.5;
  [paramGetAPI getFloatValue:&animDurationParam
               fromParameter:4
                      atTime:renderTime];

  double effectiveRadius = radius;

  if (animateIn || animateOut) {
    id<FxTimingAPI_v4> timingAPI =
        [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
    if (timingAPI) {
      CMTime effectStart = kCMTimeZero;
      [timingAPI startTimeForEffect:&effectStart];

      CMTime effectDuration = kCMTimeZero;
      [timingAPI durationTimeForEffect:&effectDuration];

      double animDuration = animDurationParam;
      double effectStartSecs = CMTimeGetSeconds(effectStart);
      double effectDurationSecs = CMTimeGetSeconds(effectDuration);
      double renderTimeSecs = CMTimeGetSeconds(renderTime);

      double t = 1.0;

      if (animateIn) {
        double timeFromStart = renderTimeSecs - effectStartSecs;
        double inFactor = timeFromStart / animDuration;
        inFactor = MAX(0.0, MIN(1.0, inFactor));
        // ease-out cubic: fast expand, gentle settle
        inFactor = 1.0 - pow(1.0 - inFactor, 3.0);
        t *= inFactor;
      }

      if (animateOut) {
        double effectEndSecs = effectStartSecs + effectDurationSecs;
        double timeToEnd = effectEndSecs - renderTimeSecs;
        double outFactor = timeToEnd / animDuration;
        outFactor = MAX(0.0, MIN(1.0, outFactor));
        // ease-in cubic: holds full radius, then snaps away
        outFactor = pow(outFactor, 3.0);
        t *= outFactor;
      }

      effectiveRadius = radius * t;
    }
  }

  *pluginState = [NSData dataWithBytes:&effectiveRadius
                                length:sizeof(effectiveRadius)];
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

  double radius = 0.0;
  [pluginState getBytes:&radius length:sizeof(radius)];

  id<MTLRenderPipelineState> pipelineState =
      [self pipelineStateForPluginID:kPluginID
                    destinationImage:destinationImage
                        vertexShader:@"vertexShader"
                      fragmentShader:@"fragmentShader"
                           blendMode:KKBlendModePremultipliedAlpha];

  if (!pipelineState)
    return NO;

  float fragmentRadius = (float)radius;
  simd_float2 imageSize = {(float)(destinationImage.imagePixelBounds.right -
                                   destinationImage.imagePixelBounds.left),
                           (float)(destinationImage.imagePixelBounds.top -
                                   destinationImage.imagePixelBounds.bottom)};
  simd_float2 tileOffset = {
      roundf((float)(destinationImage.tilePixelBounds.left -
                     destinationImage.imagePixelBounds.left)),
      roundf((float)(destinationImage.tilePixelBounds.bottom -
                     destinationImage.imagePixelBounds.bottom))};

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
                                           drawPrimitives:
                                               MTLPrimitiveTypeTriangleStrip
                                              vertexStart:0
                                              vertexCount:4];
                                     }];
}

@end
