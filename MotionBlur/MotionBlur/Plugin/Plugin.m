/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Plugin.h"
#import "Constants.h"
#import <AppKit/NSView.h>
#include <CoreMedia/CMTime.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceObjC.h>
#import <KeyframelessKit/KKLog.h>
#import <QuartzCore/QuartzCore.h>

@implementation Plugin {
  KKLog *_log;
  CMTime _frameDuration;
}

- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)newApiManager {
  _log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless"];
  [_log info:@"MotionBlurPlugin: loading"];
  self = [super initWithAPIManager:newApiManager];
  return self;
}

- (BOOL)properties:(NSDictionary *_Nonnull *)properties
             error:(NSError *_Nullable *)error {
  *properties = @{
    kFxPropertyKey_MayRemapTime : @NO,
    kFxPropertyKey_PixelTransformSupport : @(kFxPixelTransform_ScaleTranslate),
    kFxPropertyKey_VariesWhenParamsAreStatic : @NO,
  };
  return YES;
}

- (BOOL)addParametersWithError:(NSError **)error {
  id<FxParameterCreationAPI_v5> paramAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterCreationAPI_v5)];
  if (!paramAPI) {
    if (error) {
      *error =
          [NSError errorWithDomain:FxPlugErrorDomain
                              code:kFxError_APIUnavailable
                          userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"Unable to obtain FxParameterCreationAPI_v5"
                          }];
    }
    return NO;
  }

  if (![paramAPI addFloatSliderWithName:@"Strength"
                            parameterID:1
                           defaultValue:50.0
                           parameterMin:0.0
                           parameterMax:100.0
                              sliderMin:0.0
                              sliderMax:100.0
                                  delta:1.0
                         parameterFlags:kFxParameterFlag_DEFAULT]) {
    if (error) {
      *error = [NSError
          errorWithDomain:FxPlugErrorDomain
                     code:kFxError_InvalidParameter
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"Unable to add Strength slider"
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
  // Timing API doesn't seem to work directly from `scheduleInputs`
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  [timingAPI frameDuration:&_frameDuration];

  *pluginState = [NSData data];
  return YES;
}

- (BOOL)scheduleInputs:(NSArray<FxImageTileRequest *> **)inputImageRequests
       withPluginState:(NSData *)pluginState
                atTime:(CMTime)renderTime
                 error:(NSError **)error {
  CMTime previousFrame = CMTimeSubtract(renderTime, _frameDuration);
  if (CMTimeCompare(previousFrame, kCMTimeZero) < 0) {
    previousFrame = renderTime;
  }

  FxImageTileRequest *currentReq = [[FxImageTileRequest alloc]
      initWithSource:kFxImageTileRequestSourceEffectClip
                time:renderTime
      includeFilters:YES
         parameterID:0];

  FxImageTileRequest *prevReq = [[FxImageTileRequest alloc]
      initWithSource:kFxImageTileRequestSourceEffectClip
                time:previousFrame
      includeFilters:YES
         parameterID:0];

  *inputImageRequests = @[ currentReq, prevReq ];
  return YES;
}

- (BOOL)destinationImageRect:(FxRect *)destinationImageRect
                sourceImages:(NSArray<FxImageTile *> *)sourceImages
            destinationImage:(nonnull FxImageTile *)destinationImage
                 pluginState:(NSData *)pluginState
                      atTime:(CMTime)renderTime
                       error:(NSError *_Nullable *)outError {
  if (sourceImages.count < 1) {
    return NO;
  }
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
  if (!destinationImage.ioSurface || sourceImages.count < 2) {
    if (outError) {
      *outError =
          [NSError errorWithDomain:FxPlugErrorDomain
                              code:kFxError_InvalidParameter
                          userInfo:@{
                            NSLocalizedDescriptionKey : @"Missing source images"
                          }];
    }
    return NO;
  }

  id<MTLRenderPipelineState> pipelineState =
      [self pipelineStateForPluginID:kPluginID
                    destinationImage:destinationImage
                        vertexShader:@"vertexShader"
                      fragmentShader:@"fragmentShader"
                           blendMode:KKBlendModePremultipliedAlpha];
  if (!pipelineState)
    return NO;

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
                                                      atIndex:0];
                                       [encoder
                                           setFragmentTexture:inputTextures[1]
                                                      atIndex:1];
                                       [encoder
                                           drawPrimitives:
                                               MTLPrimitiveTypeTriangleStrip
                                              vertexStart:0
                                              vertexCount:4];
                                     }];
}

@end
