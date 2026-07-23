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
  // Default is motion-blur ON (Fast technique, samples 6) - it's cheap on
  // Canvas and motion reads more naturally with blur; a fresh instance reads
  // this default everywhere (inspector + render), existing projects keep
  // their saved value.
  NSString *mbDefault =
      @"{\"enabled\":true,\"shutterAngle\":180,\"samples\":6,\"technique\":0}";
  id<FxParameterCreationAPI_v5> paramAPI =
      [self kkAddStandardParametersWithInspectorUI:kParamInspectorUI
                                           uiState:kParamUIState
                                       renderNudge:kParamRenderNudge
                             motionBlurDefaultJSON:mbDefault
                                             error:error];
  if (!paramAPI)
    return NO;

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

  return YES;
}

@end
#pragma clang diagnostic pop
