/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import "ShaderTypes.h"
#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKEasing.h>
#import <KeyframelessKit/KeyframelessKit.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation MagicMovePlugin (Animation)

- (MagicMovePointValues)readPointValues:(MagicMovePointParamIDs)ids
                                 atTime:(CMTime)time
                                withAPI:(id<FxParameterRetrievalAPI_v6>)api {
  MagicMovePointValues v = {
      .x = 0.5, .y = 0.5, .scaleX = 1, .scaleY = 1, .opacity = 1};
  [api getXValue:&v.x YValue:&v.y fromParameter:ids.point atTime:time];
  [api getFloatValue:&v.rotation fromParameter:ids.rotation atTime:time];
  [api getFloatValue:&v.rotationX fromParameter:ids.rotationX atTime:time];
  [api getFloatValue:&v.rotationY fromParameter:ids.rotationY atTime:time];
  [api getFloatValue:&v.scaleX fromParameter:ids.scaleX atTime:time];
  [api getFloatValue:&v.scaleY fromParameter:ids.scaleY atTime:time];
  [api getFloatValue:&v.opacity fromParameter:ids.opacity atTime:time];
  return v;
}

- (KKBezierPath *)readPath:(UInt32)paramID
                   withAPI:(id<FxParameterRetrievalAPI_v6>)api {
  NSString *str = nil;
  [api getStringParameterValue:&str fromParameter:paramID];
  if (str.length > 0) {
    NSData *data = [[NSData alloc] initWithBase64EncodedString:str options:0];
    if (data)
      return [KKBezierPath pathWithData:data];
  }
  return [[KKBezierPath alloc] init];
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

  BOOL previewA = NO, previewB = NO, previewDrift = NO, previewExit = NO;
  [paramGetAPI getBoolValue:&previewA
              fromParameter:kParamPreviewA
                     atTime:renderTime];
  [paramGetAPI getBoolValue:&previewB
              fromParameter:kParamPreviewB
                     atTime:renderTime];
  [paramGetAPI getBoolValue:&previewDrift
              fromParameter:kParamPreviewDrift
                     atTime:renderTime];
  [paramGetAPI getBoolValue:&previewExit
              fromParameter:kParamPreviewExit
                     atTime:renderTime];

  MagicMovePointParamIDs previewIDs = {};
  BOOL hasPreview = NO;
  if (previewA) {
    previewIDs = kGroupA.params;
    hasPreview = YES;
  } else if (previewB) {
    previewIDs = kGroupB.params;
    hasPreview = YES;
  } else if (previewDrift) {
    previewIDs = kGroupDrift.params;
    hasPreview = YES;
  } else if (previewExit) {
    previewIDs = kGroupExit.params;
    hasPreview = YES;
  }

  if (hasPreview) {
    MagicMovePointValues v = [self readPointValues:previewIDs
                                            atTime:renderTime
                                           withAPI:paramGetAPI];

    MagicMoveParams params;
    params.translate = (simd_float2){(float)(v.x - 0.5), (float)(v.y - 0.5)};
    params.rotation = (float)v.rotation;
    params.rotationX = (float)v.rotationX;
    params.rotationY = (float)v.rotationY;
    params.scaleX = (float)v.scaleX;
    params.scaleY = (float)v.scaleY;
    params.opacity = (float)v.opacity;

    *pluginState = [NSData dataWithBytes:&params length:sizeof(params)];
    return (*pluginState != nil);
  }

  KKTimingResult *timing = [self timingAtTime:renderTime];

  MagicMovePointValues a = [self readPointValues:kGroupA.params
                                          atTime:renderTime
                                         withAPI:paramGetAPI];
  MagicMovePointValues b = [self readPointValues:kGroupB.params
                                          atTime:renderTime
                                         withAPI:paramGetAPI];

  BOOL driftEnabled = NO;
  [paramGetAPI getBoolValue:&driftEnabled
              fromParameter:kParamDrift
                     atTime:renderTime];

  MagicMovePointValues drift = {
      .x = 0.5, .y = 0.5, .scaleX = 1, .scaleY = 1, .opacity = 1};
  if (driftEnabled) {
    drift = [self readPointValues:kGroupDrift.params
                           atTime:renderTime
                          withAPI:paramGetAPI];
  }

  BOOL exitToggle = NO;
  [paramGetAPI getBoolValue:&exitToggle
              fromParameter:kParamExit
                     atTime:renderTime];
  BOOL exitEnabled = exitToggle && timing.outPhase.enabled;

  MagicMovePointValues exitV = {
      .x = 0.5, .y = 0.5, .scaleX = 1, .scaleY = 1, .opacity = 1};
  if (exitEnabled) {
    exitV = [self readPointValues:kGroupExit.params
                           atTime:renderTime
                          withAPI:paramGetAPI];
  }

  double targetX = b.x, targetY = b.y;
  double targetRot = b.rotation, targetRotX = b.rotationX,
         targetRotY = b.rotationY;
  double targetScaleX = b.scaleX, targetScaleY = b.scaleY,
         targetOpacity = b.opacity;

  id<FxTimingAPI_v4> timingAPI = nil;
  double startSec = 0, durSec = 0, nowSec = 0;
  if (driftEnabled) {
    timingAPI = [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
    CMTime effectStart = kCMTimeZero, effectDuration = kCMTimeZero;
    [timingAPI startTimeForEffect:&effectStart];
    [timingAPI durationTimeForEffect:&effectDuration];
    startSec = CMTimeGetSeconds(effectStart);
    durSec = CMTimeGetSeconds(effectDuration);
    nowSec = CMTimeGetSeconds(renderTime);
  }

  if (driftEnabled) {
    double driftDur = exitEnabled ? durSec - timing.outPhase.duration : durSec;
    double d = (driftDur > 0) ? (nowSec - startSec) / driftDur : 1.0;
    d = MAX(0.0, MIN(1.0, d));
    KKBezierPath *pathBDrift = [self readPath:kParamPathBDrift
                                      withAPI:paramGetAPI];
    simd_float2 driftPos =
        [pathBDrift positionAtT:(float)d
                          start:(simd_float2){(float)b.x, (float)b.y}
                            end:(simd_float2){(float)drift.x, (float)drift.y}];
    targetX = driftPos.x;
    targetY = driftPos.y;
    targetRot = (1 - d) * b.rotation + d * drift.rotation;
    targetRotX = (1 - d) * b.rotationX + d * drift.rotationX;
    targetRotY = (1 - d) * b.rotationY + d * drift.rotationY;
    targetScaleX = (1 - d) * b.scaleX + d * drift.scaleX;
    targetScaleY = (1 - d) * b.scaleY + d * drift.scaleY;
    targetOpacity = (1 - d) * b.opacity + d * drift.opacity;
  }

  double tIn = timing.inPhase.factor;
  double e = timing.outPhase.interpolate(1.0 - timing.outPhase.progress);

  KKBezierPath *pathAB = [self readPath:kParamPathAB withAPI:paramGetAPI];

  MagicMoveParams params;
  if (exitEnabled) {
    KKBezierPath *exitPath =
        [self readPath:(driftEnabled ? kParamPathDriftExit : kParamPathBExit)
               withAPI:paramGetAPI];
    simd_float2 effPos =
        [exitPath positionAtT:(float)e
                        start:(simd_float2){(float)targetX, (float)targetY}
                          end:(simd_float2){(float)exitV.x, (float)exitV.y}];
    double effX = effPos.x;
    double effY = effPos.y;
    double effRot = (1 - e) * targetRot + e * exitV.rotation;
    double effRotX = (1 - e) * targetRotX + e * exitV.rotationX;
    double effRotY = (1 - e) * targetRotY + e * exitV.rotationY;
    double effScaleX = (1 - e) * targetScaleX + e * exitV.scaleX;
    double effScaleY = (1 - e) * targetScaleY + e * exitV.scaleY;
    double effOpacity = (1 - e) * targetOpacity + e * exitV.opacity;

    simd_float2 startPos = {(float)a.x, (float)a.y};
    simd_float2 endPos = {(float)effX, (float)effY};
    simd_float2 pos = [pathAB positionAtT:(float)tIn start:startPos end:endPos];
    params.translate = (simd_float2){pos.x - 0.5f, pos.y - 0.5f};
    params.rotation = (float)((1 - tIn) * a.rotation + tIn * effRot);
    params.rotationX = (float)((1 - tIn) * a.rotationX + tIn * effRotX);
    params.rotationY = (float)((1 - tIn) * a.rotationY + tIn * effRotY);
    params.scaleX = (float)((1 - tIn) * a.scaleX + tIn * effScaleX);
    params.scaleY = (float)((1 - tIn) * a.scaleY + tIn * effScaleY);
    params.opacity = (float)((1 - tIn) * a.opacity + tIn * effOpacity);
  } else if (driftEnabled) {
    double tOut = timing.outPhase.interpolate(1.0 - timing.outPhase.progress);

    KKBezierPath *pathDriftA = [self readPath:kParamPathDriftA
                                      withAPI:paramGetAPI];
    simd_float2 outPos =
        [pathDriftA positionAtT:(float)tOut
                          start:(simd_float2){(float)targetX, (float)targetY}
                            end:(simd_float2){(float)a.x, (float)a.y}];
    double effX = outPos.x;
    double effY = outPos.y;
    double effRot = (1 - tOut) * targetRot + tOut * a.rotation;
    double effRotX = (1 - tOut) * targetRotX + tOut * a.rotationX;
    double effRotY = (1 - tOut) * targetRotY + tOut * a.rotationY;
    double effScaleX = (1 - tOut) * targetScaleX + tOut * a.scaleX;
    double effScaleY = (1 - tOut) * targetScaleY + tOut * a.scaleY;
    double effOpacity = (1 - tOut) * targetOpacity + tOut * a.opacity;

    simd_float2 startPos = {(float)a.x, (float)a.y};
    simd_float2 endPos = {(float)effX, (float)effY};
    simd_float2 pos = [pathAB positionAtT:(float)tIn start:startPos end:endPos];
    params.translate = (simd_float2){pos.x - 0.5f, pos.y - 0.5f};
    params.rotation = (float)((1 - tIn) * a.rotation + tIn * effRot);
    params.rotationX = (float)((1 - tIn) * a.rotationX + tIn * effRotX);
    params.rotationY = (float)((1 - tIn) * a.rotationY + tIn * effRotY);
    params.scaleX = (float)((1 - tIn) * a.scaleX + tIn * effScaleX);
    params.scaleY = (float)((1 - tIn) * a.scaleY + tIn * effScaleY);
    params.opacity = (float)((1 - tIn) * a.opacity + tIn * effOpacity);
  } else {
    double t = timing.inPhase.factor * timing.outPhase.factor;
    simd_float2 startPos = {(float)a.x, (float)a.y};
    simd_float2 endPos = {(float)targetX, (float)targetY};
    simd_float2 pos = [pathAB positionAtT:(float)t start:startPos end:endPos];
    params.translate = (simd_float2){pos.x - 0.5f, pos.y - 0.5f};
    params.rotation = (float)((1 - t) * a.rotation + t * targetRot);
    params.rotationX = (float)((1 - t) * a.rotationX + t * targetRotX);
    params.rotationY = (float)((1 - t) * a.rotationY + t * targetRotY);
    params.scaleX = (float)((1 - t) * a.scaleX + t * targetScaleX);
    params.scaleY = (float)((1 - t) * a.scaleY + t * targetScaleY);
    params.opacity = (float)((1 - t) * a.opacity + t * targetOpacity);
  }

  static const double kHoldTranslateAmount = 0.08;
  static const double kHoldRotationDegrees = 20.0;

  int holdSeed = 0;
  [paramGetAPI getIntValue:&holdSeed
             fromParameter:kKKParamHoldSeed
                    atTime:renderTime];

  BOOL holdPosX = YES, holdPosY = YES, holdSX = YES, holdSY = YES;
  BOOL holdRotZ = YES, holdRotX = NO, holdRotY = NO, holdOpacity = NO;
  [paramGetAPI getBoolValue:&holdPosX
              fromParameter:kParamHoldPositionX
                     atTime:renderTime];
  [paramGetAPI getBoolValue:&holdPosY
              fromParameter:kParamHoldPositionY
                     atTime:renderTime];
  [paramGetAPI getBoolValue:&holdSX
              fromParameter:kParamHoldScaleX
                     atTime:renderTime];
  [paramGetAPI getBoolValue:&holdSY
              fromParameter:kParamHoldScaleY
                     atTime:renderTime];
  [paramGetAPI getBoolValue:&holdRotZ
              fromParameter:kParamHoldRotationZ
                     atTime:renderTime];
  [paramGetAPI getBoolValue:&holdRotX
              fromParameter:kParamHoldRotationX
                     atTime:renderTime];
  [paramGetAPI getBoolValue:&holdRotY
              fromParameter:kParamHoldRotationY
                     atTime:renderTime];
  [paramGetAPI getBoolValue:&holdOpacity
              fromParameter:kParamHoldOpacity
                     atTime:renderTime];

  double holdF = timing.holdPhase.factor;
  double holdD = holdF - 1.0;
  double signTX = KKSeedSign(holdSeed, 0);
  double signTY = KKSeedSign(holdSeed, 1);
  double signRot = KKSeedSign(holdSeed, 2);
  double signSX = KKSeedSign(holdSeed, 3);
  double signSY = KKSeedSign(holdSeed, 4);
  if (holdPosX)
    params.translate.x += (float)(holdD * kHoldTranslateAmount * signTX);
  if (holdPosY)
    params.translate.y += (float)(holdD * kHoldTranslateAmount * signTY);
  if (holdRotZ) {
    params.rotation +=
        (float)(holdD * kHoldRotationDegrees * (M_PI / 180.0) * signRot);
  }
  if (holdRotX) {
    double signRX = KKSeedSign(holdSeed, 5);
    params.rotationX +=
        (float)(holdD * kHoldRotationDegrees * (M_PI / 180.0) * signRX);
  }
  if (holdRotY) {
    double signRY = KKSeedSign(holdSeed, 6);
    params.rotationY +=
        (float)(holdD * kHoldRotationDegrees * (M_PI / 180.0) * signRY);
  }
  if (holdSX) {
    params.scaleX *= (float)(1.0 + holdD * signSX);
  }
  if (holdSY) {
    params.scaleY *= (float)(1.0 + holdD * signSY);
  }
  if (holdOpacity) {
    params.opacity =
        (float)fmax(0.0, fmin(1.0, (double)params.opacity * holdF));
  }

  BOOL rwmIn = NO, rwmHold = NO, rwmOut = NO;
  [paramGetAPI getBoolValue:&rwmIn
              fromParameter:kParamRotateWithMotionIn
                     atTime:renderTime];
  [paramGetAPI getBoolValue:&rwmHold
              fromParameter:kParamRotateWithMotionHold
                     atTime:renderTime];
  [paramGetAPI getBoolValue:&rwmOut
              fromParameter:kParamRotateWithMotionOut
                     atTime:renderTime];

  BOOL applyRwm = (rwmIn && timing.inPhase.progress < 1.0) || rwmHold ||
                  (rwmOut && timing.outPhase.progress < 1.0);

  if (applyRwm) {
    double curX = (double)params.translate.x;
    double window = 1.0 / 12.0;
    CMTime tPrev =
        CMTimeSubtract(renderTime, CMTimeMakeWithSeconds(window, 600));
    KKTimingResult *prevTiming = [self timingAtTime:tPrev];
    double tgtX = b.x;
    if (driftEnabled) {
      double prevSec = CMTimeGetSeconds(tPrev);
      double driftDurP =
          exitEnabled ? durSec - timing.outPhase.duration : durSec;
      double dP = (driftDurP > 0) ? (prevSec - startSec) / driftDurP : 1.0;
      dP = MAX(0.0, MIN(1.0, dP));
      tgtX = (1 - dP) * b.x + dP * drift.x;
    }
    double prevX;
    if (exitEnabled) {
      double tPIn = prevTiming.inPhase.factor;
      double eP =
          prevTiming.outPhase.interpolate(1.0 - prevTiming.outPhase.progress);
      double effX = (1 - eP) * tgtX + eP * exitV.x;
      prevX = (1 - tPIn) * a.x + tPIn * effX - 0.5;
    } else {
      double tP = prevTiming.inPhase.factor * prevTiming.outPhase.factor;
      prevX = (1 - tP) * a.x + tP * tgtX - 0.5;
    }
    double vx = (curX - prevX) / window;
    params.rotation -= (float)(vx * 5.0 * (M_PI / 180.0));
  }

  *pluginState = [NSData dataWithBytes:&params length:sizeof(params)];
  return (*pluginState != nil);
}

@end
#pragma clang diagnostic pop
