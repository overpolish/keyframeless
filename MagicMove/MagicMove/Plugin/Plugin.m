/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Plugin.h"
#import "Constants.h"
#import "ShaderTypes.h"
#import <AppKit/NSView.h>
#import <Foundation/Foundation.h>
#include <FxPlug/FxTypes.h>
#import <IOSurface/IOSurfaceObjC.h>
#import <KeyframelessKit/KeyframelessKit.h>
#import <QuartzCore/QuartzCore.h>

static double mmSmoothstep(double x) { return x * x * (3.0 - 2.0 * x); }
static double mmEaseOutCubic(double x) { return 1.0 - pow(1.0 - x, 3.0); }
static double mmEaseOutSpring(double x) {
  const double c1 = 1.0, c3 = c1 + 1.0;
  return 1.0 + c3 * pow(x - 1.0, 3.0) + c1 * pow(x - 1.0, 2.0);
}

static double mmApplyCurveIn(double raw, int curve) {
  switch (curve) {
  case 0:
    return raw;
  case 1:
    return mmSmoothstep(raw);
  case 3:
    return mmEaseOutSpring(raw);
  default:
    return mmEaseOutCubic(raw);
  }
}

static double mmApplyCurveOut(double raw, int curve) {
  switch (curve) {
  case 0:
    return raw;
  case 1:
    return mmSmoothstep(raw);
  case 3:
    return mmEaseOutSpring(raw);
  default:
    return mmSmoothstep(raw);
  }
}

@implementation MagicMovePlugin {
  KKLog *_log;
}

- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)newApiManager;
{
  _log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless"];
  [_log info:@"MagicMovePlugin: initWithAPIManager called - plugin is loading"];
  self = [super initWithAPIManager:newApiManager];
  if (self != nil) {
    [_log info:@"MagicMovePlugin: Successfully initialized"];
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

- (BOOL)addPointGroupWithName:(NSString *)name
                      groupID:(UInt32)groupID
                      pointID:(UInt32)pointID
                   rotationID:(UInt32)rotationID
                      scaleID:(UInt32)scaleID
                     defaultX:(double)defaultX
                     defaultY:(double)defaultY
                      withAPI:(id<FxParameterCreationAPI_v5>)paramAPI {
  if (![paramAPI startParameterSubGroup:name
                            parameterID:groupID
                         parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI addPointParameterWithName:@"Position"
                               parameterID:pointID
                                  defaultX:defaultX
                                  defaultY:defaultY
                            parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI addAngleSliderWithName:@"Rotation"
                            parameterID:rotationID
                         defaultDegrees:0.0
                    parameterMinDegrees:-FLT_MAX
                    parameterMaxDegrees:FLT_MAX
                         parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI addPercentSliderWithName:@"Scale"
                              parameterID:scaleID
                             defaultValue:1.0
                             parameterMin:0.0
                             parameterMax:10.0
                                sliderMin:0.0
                                sliderMax:5.0
                                    delta:0.01
                           parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI endParameterSubGroup])
    return NO;

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

  if (![self addUpdateBannerParameterWithAPI:paramAPI error:error])
    return NO;

  if (![self addInfoParameterWithText:
                 @"Create a Compound Clip before applying to avoid clipping"
                                 icon:[NSImage imageWithSystemSymbolName:
                                                   @"exclamationmark.triangle"
                                                accessibilityDescription:nil]
                          parameterID:kParamInfoCompound
                              withAPI:paramAPI
                                error:error])
    return NO;

  if (![self addPointGroupWithName:@"Point A"
                           groupID:kParamGroupPointA
                           pointID:kParamPointA
                        rotationID:kParamRotationA
                           scaleID:kParamScaleA
                          defaultX:0.5
                          defaultY:0.5
                           withAPI:paramAPI])
    return NO;

  if (![self addPointGroupWithName:@"Point B"
                           groupID:kParamGroupPointB
                           pointID:kParamPointB
                        rotationID:kParamRotationB
                           scaleID:kParamScaleB
                          defaultX:0.5
                          defaultY:0.5
                           withAPI:paramAPI])
    return NO;

  if (![paramAPI addToggleButtonWithName:@"Rotate with Motion"
                             parameterID:kParamRotateWithMotion
                            defaultValue:NO
                          parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI startParameterSubGroup:@"Drift"
                            parameterID:kParamGroupDrift
                         parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI addToggleButtonWithName:@"Enable"
                             parameterID:kParamDrift
                            defaultValue:NO
                          parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI addPointParameterWithName:@"Position"
                               parameterID:kParamDriftPoint
                                  defaultX:0.5
                                  defaultY:0.5
                            parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI addAngleSliderWithName:@"Rotation"
                            parameterID:kParamDriftRotation
                         defaultDegrees:0.0
                    parameterMinDegrees:-FLT_MAX
                    parameterMaxDegrees:FLT_MAX
                         parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI addPercentSliderWithName:@"Scale"
                              parameterID:kParamDriftScale
                             defaultValue:1.0
                             parameterMin:0.0
                             parameterMax:10.0
                                sliderMin:0.0
                                sliderMax:5.0
                                    delta:0.01
                           parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI endParameterSubGroup])
    return NO;

  if (![paramAPI startParameterSubGroup:@"Exit"
                            parameterID:kParamGroupExit
                         parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI addToggleButtonWithName:@"Enable"
                             parameterID:kParamExit
                            defaultValue:NO
                          parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI addPointParameterWithName:@"Position"
                               parameterID:kParamExitPoint
                                  defaultX:0.5
                                  defaultY:0.5
                            parameterFlags:kFxParameterFlag_DEFAULT |
                                           kFxParameterFlag_HIDDEN])
    return NO;

  if (![paramAPI addAngleSliderWithName:@"Rotation"
                            parameterID:kParamExitRotation
                         defaultDegrees:0.0
                    parameterMinDegrees:-FLT_MAX
                    parameterMaxDegrees:FLT_MAX
                         parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI addPercentSliderWithName:@"Scale"
                              parameterID:kParamExitScale
                             defaultValue:1.0
                             parameterMin:0.0
                             parameterMax:10.0
                                sliderMin:0.0
                                sliderMax:5.0
                                    delta:0.01
                           parameterFlags:kFxParameterFlag_DEFAULT])
    return NO;

  if (![paramAPI endParameterSubGroup])
    return NO;

  if (![self addAnimationParametersWithAPI:paramAPI error:error])
    return NO;

  return YES;
}

- (void)updateParameterVisibilityAtTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!paramGetAPI || !paramSetAPI)
    return;

  BOOL animIn = NO, animOut = NO, driftOn = NO, exitOn = NO;
  [paramGetAPI getBoolValue:&animIn
              fromParameter:kKKParamAnimateIn
                     atTime:time];
  [paramGetAPI getBoolValue:&animOut
              fromParameter:kKKParamAnimateOut
                     atTime:time];
  [paramGetAPI getBoolValue:&driftOn fromParameter:kParamDrift atTime:time];
  [paramGetAPI getBoolValue:&exitOn fromParameter:kParamExit atTime:time];

  BOOL showA = animIn || (animOut && !exitOn);
  BOOL showExit = exitOn && animOut;

  FxParameterFlags flagA =
      showA ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN;
  FxParameterFlags flagDrift =
      driftOn ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN;
  FxParameterFlags flagExit =
      showExit ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN;

  // Point A group
  [paramSetAPI setParameterFlags:flagA toParameter:kParamGroupPointA];

  // Drift sub-parameters (keep Enable toggle visible)
  [paramSetAPI setParameterFlags:flagDrift toParameter:kParamDriftPoint];
  [paramSetAPI setParameterFlags:flagDrift toParameter:kParamDriftRotation];
  [paramSetAPI setParameterFlags:flagDrift toParameter:kParamDriftScale];

  // Exit sub-parameters (keep Enable toggle visible)
  [paramSetAPI setParameterFlags:flagExit toParameter:kParamExitPoint];
  [paramSetAPI setParameterFlags:flagExit toParameter:kParamExitRotation];
  [paramSetAPI setParameterFlags:flagExit toParameter:kParamExitScale];
}

- (BOOL)parameterChanged:(UInt32)parameterID
                  atTime:(CMTime)time
                   error:(NSError **)error {
  [self updateParameterVisibilityAtTime:time];
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
  double t = [self animationFactorAtTime:renderTime];

  double posAx = 0.5, posAy = 0.5, posBx = 0.5, posBy = 0.5;
  [paramGetAPI getXValue:&posAx
                  YValue:&posAy
           fromParameter:kParamPointA
                  atTime:renderTime];
  [paramGetAPI getXValue:&posBx
                  YValue:&posBy
           fromParameter:kParamPointB
                  atTime:renderTime];

  double rotA = 0, rotB = 0, scaleA = 1, scaleB = 1;
  [paramGetAPI getFloatValue:&rotA
               fromParameter:kParamRotationA
                      atTime:renderTime];
  [paramGetAPI getFloatValue:&rotB
               fromParameter:kParamRotationB
                      atTime:renderTime];
  [paramGetAPI getFloatValue:&scaleA
               fromParameter:kParamScaleA
                      atTime:renderTime];
  [paramGetAPI getFloatValue:&scaleB
               fromParameter:kParamScaleB
                      atTime:renderTime];

  BOOL driftEnabled = NO;
  [paramGetAPI getBoolValue:&driftEnabled
              fromParameter:kParamDrift
                     atTime:renderTime];

  double driftX = 0.5, driftY = 0.5, driftRot = 0, driftScale = 1;
  if (driftEnabled) {
    [paramGetAPI getXValue:&driftX
                    YValue:&driftY
             fromParameter:kParamDriftPoint
                    atTime:renderTime];
    [paramGetAPI getFloatValue:&driftRot
                 fromParameter:kParamDriftRotation
                        atTime:renderTime];
    [paramGetAPI getFloatValue:&driftScale
                 fromParameter:kParamDriftScale
                        atTime:renderTime];
  }

  BOOL exitToggle = NO;
  [paramGetAPI getBoolValue:&exitToggle
              fromParameter:kParamExit
                     atTime:renderTime];
  BOOL animateOut = NO;
  [paramGetAPI getBoolValue:&animateOut
              fromParameter:kKKParamAnimateOut
                     atTime:renderTime];
  BOOL exitEnabled = exitToggle && animateOut;

  double exitX = 0.5, exitY = 0.5, exitRot = 0, exitScale = 1;
  if (exitEnabled) {
    [paramGetAPI getXValue:&exitX
                    YValue:&exitY
             fromParameter:kParamExitPoint
                    atTime:renderTime];
    [paramGetAPI getFloatValue:&exitRot
                 fromParameter:kParamExitRotation
                        atTime:renderTime];
    [paramGetAPI getFloatValue:&exitScale
                 fromParameter:kParamExitScale
                        atTime:renderTime];
  }

  double targetX = posBx, targetY = posBy;
  double targetRot = rotB, targetScale = scaleB;

  id<FxTimingAPI_v4> timingAPI = nil;
  double startSec = 0, durSec = 0, nowSec = 0;
  if (driftEnabled || exitEnabled) {
    timingAPI = [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
    CMTime effectStart = kCMTimeZero, effectDuration = kCMTimeZero;
    [timingAPI startTimeForEffect:&effectStart];
    [timingAPI durationTimeForEffect:&effectDuration];
    startSec = CMTimeGetSeconds(effectStart);
    durSec = CMTimeGetSeconds(effectDuration);
    nowSec = CMTimeGetSeconds(renderTime);
  }

  double animDur = 0.5;
  if (exitEnabled)
    [paramGetAPI getFloatValue:&animDur
                 fromParameter:kKKParamAnimationDuration
                        atTime:renderTime];

  if (driftEnabled) {
    double driftDur = exitEnabled ? durSec - animDur : durSec;
    double d = (driftDur > 0) ? (nowSec - startSec) / driftDur : 1.0;
    d = MAX(0.0, MIN(1.0, d));
    targetX = (1 - d) * posBx + d * driftX;
    targetY = (1 - d) * posBy + d * driftY;
    targetRot = (1 - d) * rotB + d * driftRot;
    targetScale = (1 - d) * scaleB + d * driftScale;
  }

  MagicMoveParams params;
  if (exitEnabled) {
    int curve = 2;
    [paramGetAPI getIntValue:&curve
               fromParameter:kKKParamAnimationInterpolation
                      atTime:renderTime];

    // Compute in-factor only (exit replaces animate-out for position)
    double tIn = 1.0;
    BOOL animateIn = NO;
    [paramGetAPI getBoolValue:&animateIn
                fromParameter:kKKParamAnimateIn
                       atTime:renderTime];
    if (animateIn) {
      double rawIn = MAX(0.0, MIN(1.0, (nowSec - startSec) / animDur));
      tIn = mmApplyCurveIn(rawIn, curve);
    }

    // Exit factor: 0 before out-window, 1 at effect end
    double effectEndSec = startSec + durSec;
    double rawE =
        MAX(0.0, MIN(1.0, (nowSec - (effectEndSec - animDur)) / animDur));
    double e = mmApplyCurveOut(rawE, curve);

    // Blend target toward exit, then apply in-factor from A
    double effX = (1 - e) * targetX + e * exitX;
    double effY = (1 - e) * targetY + e * exitY;
    double effRot = (1 - e) * targetRot + e * exitRot;
    double effScale = (1 - e) * targetScale + e * exitScale;

    params.translate =
        (simd_float2){(float)((1 - tIn) * posAx + tIn * effX - 0.5),
                      (float)((1 - tIn) * posAy + tIn * effY - 0.5)};
    params.rotation = (float)((1 - tIn) * rotA + tIn * effRot);
    params.scale = (float)((1 - tIn) * scaleA + tIn * effScale);
  } else {
    params.translate =
        (simd_float2){(float)((1 - t) * posAx + t * targetX - 0.5),
                      (float)((1 - t) * posAy + t * targetY - 0.5)};
    params.rotation = (float)((1 - t) * rotA + t * targetRot);
    params.scale = (float)((1 - t) * scaleA + t * targetScale);
  }

  BOOL rotateWithMotion = NO;
  [paramGetAPI getBoolValue:&rotateWithMotion
              fromParameter:kParamRotateWithMotion
                     atTime:renderTime];

  if (rotateWithMotion) {
    double curX = (double)params.translate.x;
    double window = 1.0 / 12.0;
    CMTime tPrev =
        CMTimeSubtract(renderTime, CMTimeMakeWithSeconds(window, 600));
    double prevSec = CMTimeGetSeconds(tPrev);
    double tgtX = posBx;
    if (driftEnabled) {
      double driftDurP = exitEnabled ? durSec - animDur : durSec;
      double dP = (driftDurP > 0) ? (prevSec - startSec) / driftDurP : 1.0;
      dP = MAX(0.0, MIN(1.0, dP));
      tgtX = (1 - dP) * posBx + dP * driftX;
    }
    double prevX;
    if (exitEnabled) {
      int curve = 2;
      [paramGetAPI getIntValue:&curve
                 fromParameter:kKKParamAnimationInterpolation
                        atTime:renderTime];
      double tPIn = 1.0;
      BOOL animateIn = NO;
      [paramGetAPI getBoolValue:&animateIn
                  fromParameter:kKKParamAnimateIn
                         atTime:renderTime];
      if (animateIn) {
        double rawIn = MAX(0.0, MIN(1.0, (prevSec - startSec) / animDur));
        tPIn = mmApplyCurveIn(rawIn, curve);
      }
      double effectEndSec = startSec + durSec;
      double rawE =
          MAX(0.0, MIN(1.0, (prevSec - (effectEndSec - animDur)) / animDur));
      double eP = mmApplyCurveOut(rawE, curve);
      double effX = (1 - eP) * tgtX + eP * exitX;
      prevX = (1 - tPIn) * posAx + tPIn * effX - 0.5;
    } else {
      double tP = [self animationFactorAtTime:tPrev];
      prevX = (1 - tP) * posAx + tP * tgtX - 0.5;
    }
    double vx = (curX - prevX) / window;
    params.rotation -= (float)(vx * 5.0 * (M_PI / 180.0));
  }

  *pluginState = [NSData dataWithBytes:&params length:sizeof(params)];
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

  MagicMoveParams params;
  [pluginState getBytes:&params length:sizeof(params)];

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
                                                      atIndex:
                                                          KKTextureIndex_InputImage];
                                       [encoder
                                           setFragmentBytes:&params
                                                     length:sizeof(params)
                                                    atIndex:
                                                        FragmentIndex_Params];
                                       [encoder
                                           drawPrimitives:
                                               MTLPrimitiveTypeTriangleStrip
                                              vertexStart:0
                                              vertexCount:4];
                                     }];
}

@end
