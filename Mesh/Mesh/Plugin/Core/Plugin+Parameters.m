/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation MeshPlugin (Parameters)

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

  if (![self addLogoBannerParameterWithAPI:paramAPI error:error]) {
    return NO;
  }

  FxParameterFlags inspectorFlags =
      kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_CUSTOM_UI |
      kFxParameterFlag_USE_FULL_VIEW_WIDTH | kFxParameterFlag_DISABLED;
  if (![paramAPI addCustomParameterWithName:@""
                                parameterID:kParamInspectorUI
                               defaultValue:@(kParamInspectorUI)
                             parameterFlags:inspectorFlags]) {
    return NO;
  }

  if (![paramAPI addCustomParameterWithName:@""
                                parameterID:kParamUIState
                               defaultValue:[KKDataBlob blobWithData:nil]
                             parameterFlags:kFxParameterFlag_HIDDEN]) {
    return NO;
  }

  if (![paramAPI addCustomParameterWithName:@""
                                parameterID:kKKParamTimelineData
                               defaultValue:[KKDataBlob blobWithData:nil]
                             parameterFlags:kFxParameterFlag_HIDDEN]) {
    return NO;
  }

  if (![paramAPI addCustomParameterWithName:@""
                                parameterID:kParamRenderNudge
                               defaultValue:[KKDataBlob blobWithData:nil]
                             parameterFlags:kFxParameterFlag_HIDDEN |
                                            kFxParameterFlag_NOT_ANIMATABLE]) {
    return NO;
  }

  // Motion blur state lives in this custom-UI blob (edited from the inspector
  // MB row, not native controls). Read at render time via
  // +[KKMotionBlur snapshotStateFromJSON:...].
  if (![paramAPI addCustomParameterWithName:@""
                                parameterID:kKKParamMotionBlurData
                               defaultValue:[KKDataBlob blobWithData:nil]
                             parameterFlags:kFxParameterFlag_HIDDEN |
                                            kFxParameterFlag_NOT_ANIMATABLE]) {
    return NO;
  }

  // Per-instance identity UUID: lets the OSC resolve this instance's
  // KKPluginInstanceState (OSC-visibility cache) from its own apiManager scope.
  if (![paramAPI addStringParameterWithName:@""
                                parameterID:kKKParamInstanceID
                               defaultValue:@""
                             parameterFlags:kFxParameterFlag_HIDDEN |
                                            kFxParameterFlag_NOT_ANIMATABLE]) {
    return NO;
  }

  return YES;
}

@end
#pragma clang diagnostic pop
