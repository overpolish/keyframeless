/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation MiragePlugin (Parameters)

- (BOOL)addParametersWithError:(NSError **)error {
  id<FxParameterCreationAPI_v5> paramAPI =
      [self kkAddStandardParametersWithInspectorUI:kParamInspectorUI
                                           uiState:kParamUIState
                                       renderNudge:kParamRenderNudge
                             motionBlurDefaultJSON:nil
                                             error:error];
  if (!paramAPI)
    return NO;

  // Second texture source, bound to iChannel1 when filled (a Motion
  // transition template feeds it "Drop Zone Transition B").
  if (![paramAPI addImageReferenceWithName:@"To"
                               parameterID:kParamToImage
                            parameterFlags:kFxParameterFlag_DEFAULT]) {
    return NO;
  }

  // Sonar tickets. A string param rather than a blob because a ticket must NOT
  // be undoable - see Plugin+AudioTickets.m for why that is the point rather
  // than a compromise.
  if (![paramAPI addStringParameterWithName:@""
                                parameterID:kParamAudioTickets
                               defaultValue:@""
                             parameterFlags:kFxParameterFlag_HIDDEN |
                                            kFxParameterFlag_NOT_ANIMATABLE]) {
    return NO;
  }

  return YES;
}

@end
#pragma clang diagnostic pop
