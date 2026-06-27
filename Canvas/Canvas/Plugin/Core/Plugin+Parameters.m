/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <KeyframelessKit/KKDataBlob.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation CanvasPlugin (Parameters)

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

  // Custom (data-blob) param, not a string param: FxPlug tracks custom params
  // for undo/redo (string params aren't). HIDDEN only - matching the kit's
  // persistent blobs (timeline/motion-blur/gradient); adding NOT_ANIMATABLE
  // stops the custom value from round-tripping (writes read back empty).
  if (![paramAPI addCustomParameterWithName:@""
                                parameterID:kParamLayerData
                               defaultValue:[KKDataBlob blobWithData:nil]
                             parameterFlags:kFxParameterFlag_HIDDEN]) {
    return NO;
  }

  // Motion-blur settings blob (enabled / shutter / samples / technique), written
  // by the inspector toolbar's MB toggle via the shared inspector callbacks and
  // read back in -pluginState: to drive the render. HIDDEN + NOT_ANIMATABLE.
  // MUST be registered or flipping the toggle crashes FCP's parameter
  // transaction. Default is motion-blur ON (Fast technique, samples 6) - it's
  // cheap on Canvas and motion reads more naturally with blur; a fresh instance
  // reads this default everywhere (inspector + render), existing projects keep
  // their saved value.
  NSString *mbDefault =
      @"{\"enabled\":true,\"shutterAngle\":180,\"samples\":6,\"technique\":0}";
  if (![paramAPI addCustomParameterWithName:@""
                                parameterID:kKKParamMotionBlurData
                               defaultValue:[KKDataBlob blobWithString:mbDefault]
                             parameterFlags:kFxParameterFlag_HIDDEN |
                                            kFxParameterFlag_NOT_ANIMATABLE]) {
    return NO;
  }

  // Per-instance identity UUID (a STRING param - the effect AND the viewer OSC
  // read it to resolve the same KKPluginInstanceState, which carries the OSC
  // visibility). MUST exist before KKInstanceStateEnsureForAPI writes it
  // (createView); without registering it, that write crashes FCP's parameter
  // transaction. HIDDEN + NOT_ANIMATABLE, never user-edited.
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
