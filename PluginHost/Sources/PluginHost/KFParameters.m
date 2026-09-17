/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFParameters.h"

BOOL KFAddHiddenToggle(id<FxParameterCreationAPI_v5> api, NSString *name, UInt32 parameterID,
                       BOOL defaultValue) {
  return [api addToggleButtonWithName:name parameterID:parameterID defaultValue:defaultValue
                       parameterFlags:(kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_HIDDEN)];
}
BOOL KFAddHostRefreshToken(id<FxParameterCreationAPI_v5> api, NSString *name, UInt32 parameterID) {
  return [api addCustomParameterWithName:name parameterID:parameterID defaultValue:@""
                          parameterFlags:(kFxParameterFlag_HIDDEN | kFxParameterFlag_NOT_ANIMATABLE)];
}
BOOL KFAddCacheToken(id<FxParameterCreationAPI_v5> api, NSString *name, UInt32 parameterID) {
  return [api addStringParameterWithName:name parameterID:parameterID defaultValue:@""
                          parameterFlags:(kFxParameterFlag_HIDDEN | kFxParameterFlag_NOT_ANIMATABLE |
                                          kFxParameterFlag_DONT_SAVE)];
}
BOOL KFAddCustomUIParameter(id<FxParameterCreationAPI_v5> api, UInt32 parameterID, id defaultValue) {
  return [api addCustomParameterWithName:@"" parameterID:parameterID defaultValue:defaultValue
                          parameterFlags:(kFxParameterFlag_CUSTOM_UI | kFxParameterFlag_USE_FULL_VIEW_WIDTH)];
}
BOOL KFAddCustomUIPanel(id<FxParameterCreationAPI_v5> api, UInt32 parameterID) {
  return [api addCustomParameterWithName:@"" parameterID:parameterID defaultValue:@0
                          parameterFlags:(kFxParameterFlag_CUSTOM_UI | kFxParameterFlag_USE_FULL_VIEW_WIDTH |
                                          kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_DONT_SAVE)];
}
