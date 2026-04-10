/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation RoundedPlugin (Parameters)

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

  if (![self addCropParametersWithAPI:paramAPI
                              groupID:kParamCropGroup
                           expandedID:kParamCropExpanded
                                topID:kParamCropTop
                             bottomID:kParamCropBottom
                               leftID:kParamCropLeft
                              rightID:kParamCropRight
                                error:error]) {
    return NO;
  }

  if (![self addAnimationParametersWithAPI:paramAPI error:error]) {
    return NO;
  }

  UInt32 animParams[] = {
      kParamInRadius, kParamInCrop,    kParamHoldRadius,
      kParamHoldCrop, kParamOutRadius, kParamOutCrop,
  };
  NSString *animNames[] = {
      @"In Radius", @"In Crop",    @"Hold Radius",
      @"Hold Crop", @"Out Radius", @"Out Crop",
  };
  for (int i = 0; i < 6; i++) {
    if (![paramAPI addToggleButtonWithName:animNames[i]
                               parameterID:animParams[i]
                              defaultValue:YES
                            parameterFlags:kFxParameterFlag_HIDDEN])
      return NO;
  }

  return YES;
}

@end
#pragma clang diagnostic pop
