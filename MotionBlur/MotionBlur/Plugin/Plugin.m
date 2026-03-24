/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Plugin.h"
#import "Constants.h"
#import "ShaderTypes.h"
#import <AppKit/NSView.h>
#import <CoreMedia/CMTime.h>
#import <Foundation/Foundation.h>
#import <IOSurface/IOSurfaceObjC.h>
#import <KeyframelessKit/KKKbd.h>
#import <KeyframelessKit/KKLog.h>
#import <QuartzCore/QuartzCore.h>

typedef struct {
  CMTime frameDuration;
  float strength; // 0..1
  int sampleCount;
} MotionBlurState;

@implementation MotionBlurPlugin {
  KKLog *_log;
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
    kFxPropertyKey_MayRemapTime : @YES,
    kFxPropertyKey_PixelTransformSupport : @(kFxPixelTransform_ScaleTranslate),
    kFxPropertyKey_VariesWhenParamsAreStatic : @YES,
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

  // Strength: 0 = no blur, 100 = full-frame blur. Mapped to shutter angle
  // internally (strength / 100 * 360°).
  if (![paramAPI addFloatSliderWithName:@"Strength"
                            parameterID:kParamStrength
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

  NSMutableAttributedString *infoText = [[NSMutableAttributedString alloc]
      initWithString:@"Use on a Adjustment Clip "];
  [infoText appendAttributedString:[KKKbd attributedStringWithKey:@"⌥ A"]];

  if (![self
          addInfoParameterWithAttributedText:infoText
                                        icon:[NSImage
                                                 imageWithSystemSymbolName:
                                                     @"info.circle"
                                                  accessibilityDescription:nil]
                                 parameterID:kParamInfoUsage
                                     withAPI:paramAPI
                                       error:error]) {
    return NO;
  }

  return [self addUpdateBannerParameterWithAPI:paramAPI error:error];
}

- (BOOL)pluginState:(NSData **)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error {
  MotionBlurState state = {};

  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  [timingAPI frameDuration:&state.frameDuration];

  double strength = 50.0;
  id<FxParameterRetrievalAPI_v6> paramAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  [paramAPI getFloatValue:&strength
            fromParameter:kParamStrength
                   atTime:renderTime];
  state.strength = (float)(strength / 100.0);

  // Use fewer samples during preview/scrubbing for real-time playback.
  switch (qualityLevel) {
  case kFxQuality_LOW:
    state.sampleCount = 4;
    break;
  case kFxQuality_MEDIUM:
    state.sampleCount = 8;
    break;
  default:
    state.sampleCount = MOTION_BLUR_SAMPLE_COUNT;
    break;
  }

  *pluginState = [NSData dataWithBytes:&state length:sizeof(state)];
  return YES;
}

- (BOOL)scheduleInputs:(NSArray<FxImageTileRequest *> **)inputImageRequests
       withPluginState:(NSData *)pluginState
                atTime:(CMTime)renderTime
                 error:(NSError **)error {
  MotionBlurState state = {};
  if (pluginState.length >= sizeof(state)) {
    [pluginState getBytes:&state length:sizeof(state)];
  }

  double shutterSeconds =
      CMTimeGetSeconds(state.frameDuration) * state.strength;

  int n = state.sampleCount > 0 ? state.sampleCount : MOTION_BLUR_SAMPLE_COUNT;
  NSMutableArray *requests = [NSMutableArray arrayWithCapacity:n];
  for (int i = 0; i < n; i++) {
    double fraction = (n > 1) ? (double)i / (double)(n - 1) : 0.0;
    double offsetSeconds = shutterSeconds * fraction;
    CMTime frameTime = CMTimeSubtract(
        renderTime, CMTimeMakeWithSeconds(offsetSeconds, renderTime.timescale));
    if (CMTimeCompare(frameTime, kCMTimeZero) < 0) {
      frameTime = kCMTimeZero;
    }

    FxImageTileRequest *req = [[FxImageTileRequest alloc]
        initWithSource:kFxImageTileRequestSourceEffectClip
                  time:frameTime
        includeFilters:YES
           parameterID:0];
    [requests addObject:req];
  }

  *inputImageRequests = requests;
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
  MotionBlurState state = {};
  if (pluginState.length >= sizeof(state)) {
    [pluginState getBytes:&state length:sizeof(state)];
  }
  int sampleCount =
      state.sampleCount > 0 ? state.sampleCount : MOTION_BLUR_SAMPLE_COUNT;
  int actualSamples = (int)MIN((NSUInteger)sampleCount, sourceImages.count);

  if (!destinationImage.ioSurface || actualSamples == 0) {
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
                                       for (NSUInteger i = 0;
                                            i < inputTextures.count; i++) {
                                         [encoder
                                             setFragmentTexture:inputTextures[i]
                                                        atIndex:i];
                                       }
                                       [encoder
                                           setFragmentBytes:&actualSamples
                                                     length:sizeof(
                                                                actualSamples)
                                                    atIndex:0];
                                       [encoder
                                           drawPrimitives:
                                               MTLPrimitiveTypeTriangleStrip
                                              vertexStart:0
                                              vertexCount:4];
                                     }];
}

@end
