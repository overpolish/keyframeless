/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wprotocol"

@implementation GlowPlugin {
  KKLog *_log;
}

- (nullable instancetype)initWithAPIManager:(id<PROAPIAccessing>)newApiManager;
{
  _log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless"];
  self = [super initWithAPIManager:newApiManager];
  return self;
}

- (BOOL)properties:(NSDictionary *_Nonnull *)properties
             error:(NSError *_Nullable *)error {
  *properties = @{
    kFxPropertyKey_MayRemapTime : @NO,
    kFxPropertyKey_PixelTransformSupport : @(kFxPixelTransform_ScaleTranslate),
    kFxPropertyKey_VariesWhenParamsAreStatic : @YES,
    kFxPropertyKey_ChangesOutputSize : @YES,
    kFxPropertyKey_NeedsFullBuffer : @YES
  };

  return YES;
}

- (BOOL)parameterChanged:(UInt32)parameterID
                  atTime:(CMTime)time
                   error:(NSError **)error {
  [self multiStageHandleParameterChanged:parameterID atTime:time];
  switch (parameterID) {
  case kKKParamColorMode:
  case kParamGradientType:
  case kParamForceShow:
  case kKKParamTimingExpanded:
  case kKKParamTimingSelectedSection:
  case kKKParamAnimateIn:
  case kKKParamAnimateOut:
  case kKKParamHoldEffect:
  case kParamInColor:
  case kParamHoldColor:
  case kParamOutColor:
  case kParamNoiseExpanded:
  case kParamOffsetExpanded:
  case kKKParamColorExpanded:
    [self updateParameterVisibilityAtTime:time];
    break;
  case kParamPreset:
    [self applyPresetAtTime:time];
    break;
  default:
    [self handleLinkedParameterChanged:parameterID atTime:time];
    break;
  }
  return YES;
}

@end
#pragma clang diagnostic pop
