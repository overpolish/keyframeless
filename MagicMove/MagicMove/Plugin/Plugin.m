/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <KeyframelessKit/KeyframelessKit.h>

@interface MagicMovePlugin (AnimatableParamUpdate)
- (void)_mmHandleAnimatableParameterChange:(UInt32)parameterID
                                    atTime:(CMTime)time;
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wprotocol"
@implementation MagicMovePlugin

- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)newApiManager;
{
  KKLogInfo(@"MagicMovePlugin: initialized");
  self = [super initWithAPIManager:newApiManager];
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

- (BOOL)forceShowAllParameters {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!paramGetAPI)
    return NO;
  BOOL on = NO;
  [paramGetAPI getBoolValue:&on
              fromParameter:kParamForceShowAlerts
                     atTime:kCMTimeZero];
  return on;
}

- (BOOL)parameterChanged:(UInt32)parameterID
                  atTime:(CMTime)time
                   error:(NSError **)error {
  [self handleLinkedParameterChanged:parameterID atTime:time];
  [self updateTimingParameterVisibility];
  [self updateMotionBlurParameterVisibility];
  [self updateParameterVisibilityAtTime:time];
  [self _mmHandleAnimatableParameterChange:parameterID atTime:time];
  return YES;
}

@end

@implementation MagicMovePlugin (AnimatableParamUpdate)

/// paramID → (lane label, current values) translator. Routes a slider /
/// picker change into the corresponding lane's selected segment via
/// `multiStageUpdateSelectedSegmentForLabel:values:`.
- (void)_mmHandleAnimatableParameterChange:(UInt32)parameterID
                                    atTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!getAPI)
    return;

  NSString *label = nil;
  NSArray<NSNumber *> *values = nil;
  switch (parameterID) {
  case kParamPoint:
  case kParamRotateWithMotion: {
    label = @"Position";
    double x = 0, y = 0;
    [getAPI getXValue:&x YValue:&y fromParameter:kParamPoint atTime:time];
    BOOL rwm = NO;
    [getAPI getBoolValue:&rwm fromParameter:kParamRotateWithMotion atTime:time];
    values = @[ @(x), @(y), @(rwm ? 1.0 : 0.0) ];
    break;
  }
  case kParamScale:
  case kParamScaleY: {
    label = @"Scale";
    double sx = 1, sy = 1;
    [getAPI getFloatValue:&sx fromParameter:kParamScale atTime:time];
    [getAPI getFloatValue:&sy fromParameter:kParamScaleY atTime:time];
    values = @[ @(sx), @(sy) ];
    break;
  }
  case kParamRotation: {
    label = @"Rot Z";
    double v = 0;
    [getAPI getFloatValue:&v fromParameter:kParamRotation atTime:time];
    values = @[ @(v) ];
    break;
  }
  case kParamRotationX: {
    label = @"Rot X";
    double v = 0;
    [getAPI getFloatValue:&v fromParameter:kParamRotationX atTime:time];
    values = @[ @(v) ];
    break;
  }
  case kParamRotationY: {
    label = @"Rot Y";
    double v = 0;
    [getAPI getFloatValue:&v fromParameter:kParamRotationY atTime:time];
    values = @[ @(v) ];
    break;
  }
  case kParamOpacity: {
    label = @"Opacity";
    double v = 0;
    [getAPI getFloatValue:&v fromParameter:kParamOpacity atTime:time];
    values = @[ @(v) ];
    break;
  }
  default:
    return;
  }
  if (label.length && values.count)
    [self multiStageUpdateSelectedSegmentForLabel:label values:values];
}

@end
#pragma clang diagnostic pop
