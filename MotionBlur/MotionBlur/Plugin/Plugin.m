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
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKMarkup.h>
#import <QuartzCore/QuartzCore.h>
#import <objc/message.h>

typedef struct {
  CMTime frameDuration;
  double shutterAngle; // 0..360 degrees
  int sampleCount;
} MotionBlurState;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wprotocol"

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

  if (![self addLogoBannerParameterWithAPI:paramAPI error:error]) {
    return NO;
  }

  NSAttributedString *infoText = [KKMarkup
      attributedStringFromMarkup:
          @"Use on an Adjustment Clip <kbd>⌥ A</kbd> or a Compound Clip "
          @"<kbd>⌥ G</kbd>"];
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

  // Length: 0-100% maps to 0-360 degree shutter angle.
  // Default 50% = 180 degrees (half frame duration).
  if (![paramAPI addPercentSliderWithName:@"Length"
                              parameterID:kParamLength
                             defaultValue:0.5
                             parameterMin:0.0
                             parameterMax:1.0
                                sliderMin:0.0
                                sliderMax:1.0
                                    delta:0.01
                           parameterFlags:kFxParameterFlag_DEFAULT]) {
    if (error) {
      *error = [NSError
          errorWithDomain:FxPlugErrorDomain
                     code:kFxError_InvalidParameter
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"Unable to add Length slider"
                 }];
    }
    return NO;
  }

  // Quality: 0-100% maps to 2-128 samples.
  // Default 50% = 65 samples.
  if (![paramAPI addPercentSliderWithName:@"Quality"
                              parameterID:kParamQuality
                             defaultValue:0.5
                             parameterMin:0.0
                             parameterMax:1.0
                                sliderMin:0.0
                                sliderMax:1.0
                                    delta:0.01
                           parameterFlags:kFxParameterFlag_DEFAULT]) {
    if (error) {
      *error = [NSError
          errorWithDomain:FxPlugErrorDomain
                     code:kFxError_InvalidParameter
                 userInfo:@{
                   NSLocalizedDescriptionKey : @"Unable to add Quality slider"
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
  MotionBlurState state = {};

  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  [timingAPI frameDuration:&state.frameDuration];

  id<FxParameterRetrievalAPI_v6> paramAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];

  double length = 0.5;
  [paramAPI getFloatValue:&length fromParameter:kParamLength atTime:renderTime];
  state.shutterAngle = length * 360.0;

  double quality = 0.5;
  [paramAPI getFloatValue:&quality
            fromParameter:kParamQuality
                   atTime:renderTime];
  // Exponential mapping: more control at low end where it matters.
  // 0%=2, 50%=16, 100%=128.
  state.sampleCount = MAX(2, (int)(2.0 * pow(64.0, quality)));

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

  double frameSec = CMTimeGetSeconds(state.frameDuration);
  double shutterSec = frameSec * (state.shutterAngle / 360.0);
  int n = state.sampleCount;

  NSMutableArray *requests = [NSMutableArray arrayWithCapacity:n];
  for (int i = 0; i < n; i++) {
    double t = (n > 1) ? (double)i / (double)(n - 1) : 0.0;
    double offsetSec = shutterSec * t;
    CMTime sampleTime = CMTimeSubtract(
        renderTime, CMTimeMakeWithSeconds(offsetSec, renderTime.timescale));
    if (CMTimeCompare(sampleTime, kCMTimeZero) < 0)
      sampleTime = kCMTimeZero;

    FxImageTileRequest *req = [[FxImageTileRequest alloc]
        initWithSource:kFxImageTileRequestSourceEffectClip
                  time:sampleTime
        includeFilters:YES
           parameterID:0];
    [requests addObject:req];
  }

  *inputImageRequests = requests;
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

  int actualSamples =
      (int)MIN((NSUInteger)state.sampleCount, sourceImages.count);
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

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kParamInfoUsage) {
    NSAttributedString *text = [KKMarkup
        attributedStringFromMarkup:
            @"Use on an Adjustment Clip <kbd>⌥ A</kbd> or a Compound Clip "
            @"<kbd>⌥ G</kbd>"];
    KKAlertView *alert = [[KKAlertView alloc] initWithAttributedText:text];
    alert.icon = [NSImage imageWithSystemSymbolName:@"info.circle"
                           accessibilityDescription:nil];
    return alert;
  }
  struct objc_super sup = {self, [KKPlugin class]};
  return ((NSView * (*)(struct objc_super *, SEL, UInt32)) objc_msgSendSuper)(
      &sup, @selector(createViewForParameterID:), parameterID);
}

@end
#pragma clang diagnostic pop
