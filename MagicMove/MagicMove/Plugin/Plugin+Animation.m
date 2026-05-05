/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import "ShaderTypes.h"
#import <KeyframelessKit/KeyframelessKit.h>

/// Reads `kKKParamMultiStageData` and returns a `propertyLabel → values`
/// dict evaluated at `frac`.
static NSDictionary<NSString *, NSArray<NSNumber *> *> *
KKEvaluateLanesByLabel(id<FxParameterRetrievalAPI_v6> getAPI, double frac) {
  NSString *json = nil;
  [getAPI getStringParameterValue:&json fromParameter:kKKParamMultiStageData];
  if (!json.length)
    return @{};
  NSArray<KKTimingLane *> *lanes = [KKTimingLane lanesFromJSON:json];
  NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *out =
      [NSMutableDictionary dictionaryWithCapacity:lanes.count];
  for (KKTimingLane *lane in lanes) {
    if (!lane.enabled || !lane.propertyLabel.length)
      continue;
    NSArray<NSNumber *> *vals = KKTimingLaneValueAtFraction(lane, frac);
    if (vals.count > 0)
      out[lane.propertyLabel] = vals;
  }
  return out;
}

static double KKEffectFractionForTime(id<FxTimingAPI_v4> timingAPI,
                                      CMTime time) {
  CMTime startT = kCMTimeZero, durT = kCMTimeZero;
  [timingAPI startTimeForEffect:&startT];
  [timingAPI durationTimeForEffect:&durT];
  double durSec = CMTimeGetSeconds(durT);
  if (durSec <= 0)
    return 0.0;
  return MAX(0.0, MIN(1.0, (CMTimeGetSeconds(time) - CMTimeGetSeconds(startT)) /
                               durSec));
}

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

  MagicMoveParams params;
  if (![self magicMoveParams:&params atTime:renderTime error:error])
    return NO;

  id<FxParameterRetrievalAPI_v6> paramAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  KKMotionBlurState mbState =
      [KKMotionBlur snapshotStateWithParameterAPI:paramAPI
                                        timingAPI:timingAPI
                                           atTime:renderTime];

  // Skip the blur path during Hold portions when the user opted in —
  // single-pass render is dramatically cheaper.
  if (mbState.enabled && mbState.transitionsOnly &&
      ![self multiStageAnyLaneInTransitionAtTime:renderTime]) {
    mbState.enabled = false;
  }

  // Layout: [KKMotionBlurState | N × MagicMoveParams]. When blur is off,
  // N=1 and `params` (computed at renderTime) is the only entry — used
  // both as the fallback render input and as sample 0 if blur turns on
  // mid-frame. When blur is on, sample 0 is at renderTime and samples
  // 1..N-1 are evaluated backwards in time across the shutter window.
  NSMutableData *data = [NSMutableData data];
  [data appendBytes:&mbState length:sizeof(mbState)];
  [data appendBytes:&params length:sizeof(params)];

  if (mbState.enabled) {
    NSArray<NSValue *> *times = [KKMotionBlur sampleTimesForState:mbState
                                                       renderTime:renderTime];
    for (NSUInteger i = 1; i < times.count; i++) {
      CMTime t = kCMTimeZero;
      [times[i] getValue:&t];
      MagicMoveParams p;
      if (![self magicMoveParams:&p atTime:t error:error])
        return NO;
      [data appendBytes:&p length:sizeof(p)];
    }
  }

  *pluginState = data;
  return (*pluginState != nil);
}

- (BOOL)magicMoveParams:(MagicMoveParams *)outParams
                 atTime:(CMTime)renderTime
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

  double anchorX = 0.5, anchorY = 0.5;
  [paramGetAPI getXValue:&anchorX
                  YValue:&anchorY
           fromParameter:kParamAnchorPoint
                  atTime:renderTime];

  MagicMovePointValues v = [self readPointValuesAtTime:renderTime
                                               withAPI:paramGetAPI];

  id<FxTimingAPI_v4> mmTimingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  double frac = KKEffectFractionForTime(mmTimingAPI, renderTime);
  NSDictionary<NSString *, NSArray<NSNumber *> *> *multiStage =
      KKEvaluateLanesByLabel(paramGetAPI, frac);

  NSArray<NSNumber *> *msPosition = multiStage[@"Position"];
  NSArray<NSNumber *> *msScale = multiStage[@"Scale"];
  NSArray<NSNumber *> *msRotZ = multiStage[@"Rot Z"];
  NSArray<NSNumber *> *msRotX = multiStage[@"Rot X"];
  NSArray<NSNumber *> *msRotY = multiStage[@"Rot Y"];
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

  NSArray<KKTimingSegment *> *posSegs = nil;
  double localT = 0.0;
  KKTimingSegment *activePos = [self multiStageActiveSegmentForLabel:@"Position"
                                                              atTime:renderTime
                                                            segments:&posSegs
                                                              localT:&localT];
  if (activePos) {
    NSUInteger idx = [posSegs indexOfObjectIdenticalTo:activePos];
    NSArray<NSNumber *> *fromVals = KKTimingBoundaryBefore(idx, posSegs);
    NSArray<NSNumber *> *toVals = KKTimingBoundaryAfter(idx, posSegs);
    double fromX = fromVals.count >= 1 ? fromVals[0].doubleValue : posX;
    double fromY = fromVals.count >= 2 ? fromVals[1].doubleValue : posY;
    double toX = toVals.count >= 1 ? toVals[0].doubleValue : posX;
    double toY = toVals.count >= 2 ? toVals[1].doubleValue : posY;
    BOOL isAnimateOut = (idx == posSegs.count - 1);
    simd_float2 p;
    if (KKEvaluateBezierPathPosition(activePos, isAnimateOut, localT,
                                     (simd_float2){(float)fromX, (float)fromY},
                                     (simd_float2){(float)toX, (float)toY},
                                     &p)) {
      posX = p.x;
      posY = p.y;
    }
  }
  double scaleX = msScale.count >= 1 ? msScale[0].doubleValue : v.scaleX;
  double scaleY = msScale.count >= 2 ? msScale[1].doubleValue : v.scaleY;
  double rotZ = msRotZ.count >= 1 ? msRotZ[0].doubleValue : v.rotation;
  double rotX = msRotX.count >= 1 ? msRotX[0].doubleValue : v.rotationX;
  double rotY = msRotY.count >= 1 ? msRotY[0].doubleValue : v.rotationY;
  double opacity = msOpacity.count >= 1 ? msOpacity[0].doubleValue : v.opacity;

  if (rotateWithMotion) {
    double window = KKRotateWithMotionWindowSeconds;
    CMTime tPrev =
        CMTimeSubtract(renderTime, CMTimeMakeWithSeconds(window, 600));
    double prevFrac = KKEffectFractionForTime(mmTimingAPI, tPrev);
    NSDictionary<NSString *, NSArray<NSNumber *> *> *prev =
        KKEvaluateLanesByLabel(paramGetAPI, prevFrac);
    NSArray<NSNumber *> *prevPos = prev[@"Position"];
    double prevX = prevPos.count >= 1 ? prevPos[0].doubleValue : posX;
    double vx = (posX - prevX) / window;
    rotZ -= KKRotateWithMotionDeltaRadians(vx);
  }

  outParams->translate =
      (simd_float2){(float)(posX - 0.5), (float)(posY - 0.5)};
  outParams->anchorOffset =
      (simd_float2){(float)(anchorX - 0.5), (float)(anchorY - 0.5)};
  outParams->rotation = (float)rotZ;
  outParams->rotationX = (float)rotX;
  outParams->rotationY = (float)rotY;
  outParams->scaleX = (float)scaleX;
  outParams->scaleY = (float)scaleY;
  outParams->opacity = (float)opacity;
  return YES;
}

@end
#pragma clang diagnostic pop
