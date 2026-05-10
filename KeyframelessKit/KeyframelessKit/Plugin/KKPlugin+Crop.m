/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKDataBlob.h"
#import "KKPlugin+Crop.h"
#import <FxPlug/FxPlugSDK.h>

@implementation KKPlugin (Crop)

- (BOOL)addCropParametersWithAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                         groupID:(UInt32)groupID
                      expandedID:(UInt32)expandedID
                           topID:(UInt32)topID
                        bottomID:(UInt32)bottomID
                          leftID:(UInt32)leftID
                         rightID:(UInt32)rightID
                           error:(NSError **)error {
  if (![paramAPI
          addCustomParameterWithName:@""
                         parameterID:groupID
                        defaultValue:@(groupID)
                      parameterFlags:kFxParameterFlag_NOT_ANIMATABLE |
                                     kFxParameterFlag_CUSTOM_UI |
                                     kFxParameterFlag_USE_FULL_VIEW_WIDTH]) {
    return NO;
  }

  if (![paramAPI addCustomParameterWithName:@""
                                parameterID:expandedID
                               defaultValue:[KKDataBlob blobWithString:@"0"]
                             parameterFlags:kFxParameterFlag_HIDDEN |
                                            kFxParameterFlag_NOT_ANIMATABLE]) {
    return NO;
  }

  NSArray<NSNumber *> *sliderIDs =
      @[ @(topID), @(bottomID), @(leftID), @(rightID) ];
  NSArray<NSString *> *sliderNames = @[ @"Top", @"Bottom", @"Left", @"Right" ];

  for (NSUInteger i = 0; i < sliderIDs.count; i++) {
    if (![paramAPI addPercentSliderWithName:sliderNames[i]
                                parameterID:sliderIDs[i].unsignedIntValue
                               defaultValue:0.0
                               parameterMin:0.0
                               parameterMax:1.0
                                  sliderMin:0.0
                                  sliderMax:1.0
                                      delta:0.001
                             parameterFlags:kFxParameterFlag_HIDDEN]) {
      return NO;
    }
  }

  return YES;
}

@end
