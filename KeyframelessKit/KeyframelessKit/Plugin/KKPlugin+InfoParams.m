/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKConstants.h"
#import "KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>

static BOOL KKAddParam(BOOL ok, NSError **err, NSString *desc) {
  if (ok)
    return YES;
  if (err)
    *err = [NSError errorWithDomain:@"co.overpolish.keyframeless.error"
                               code:1
                           userInfo:@{NSLocalizedDescriptionKey : desc}];
  return NO;
}

static const FxParameterFlags kCustomUIDisabled =
    kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_CUSTOM_UI |
    kFxParameterFlag_USE_FULL_VIEW_WIDTH | kFxParameterFlag_DISABLED;

static BOOL KKAddCustomUIDisabledParam(id<FxParameterCreationAPI_v5> paramAPI,
                                       UInt32 parameterID, NSError **error,
                                       NSString *errDesc) {
  return KKAddParam([paramAPI addCustomParameterWithName:@""
                                             parameterID:parameterID
                                            defaultValue:@(parameterID)
                                          parameterFlags:kCustomUIDisabled],
                    error, errDesc);
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKPlugin (InfoParams)

- (BOOL)addInfoParameterWithText:(NSString *)text
                            icon:(nullable NSImage *)icon
                     parameterID:(UInt32)parameterID
                         withAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                           error:(NSError **)error {
  kkClassRegistry([self class], kKKInfoTexts)[@(parameterID)] = [text copy];
  if (icon)
    kkClassRegistry([self class], kKKInfoIcons)[@(parameterID)] = icon;

  if (!KKAddCustomUIDisabledParam(paramAPI, parameterID, error,
                                  @"Unable to add info parameter")) {
    kkClassRegistry([self class], kKKInfoTexts)[@(parameterID)] = nil;
    return NO;
  }
  return YES;
}

- (BOOL)addInfoParameterWithAttributedText:(NSAttributedString *)text
                                      icon:(nullable NSImage *)icon
                               parameterID:(UInt32)parameterID
                                   withAPI:
                                       (id<FxParameterCreationAPI_v5>)paramAPI
                                     error:(NSError **)error {
  kkClassRegistry([self class], kKKInfoAttrTexts)[@(parameterID)] = [text copy];
  if (icon)
    kkClassRegistry([self class], kKKInfoIcons)[@(parameterID)] = icon;

  if (!KKAddCustomUIDisabledParam(paramAPI, parameterID, error,
                                  @"Unable to add info parameter")) {
    kkClassRegistry([self class], kKKInfoAttrTexts)[@(parameterID)] = nil;
    return NO;
  }
  return YES;
}

- (BOOL)addSeparatorParameterWithText:(nullable NSString *)text
                                 icon:(nullable NSImage *)icon
                          parameterID:(UInt32)parameterID
                              withAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                                error:(NSError **)error {
  kkClassRegistry([self class], kKKSepTexts)[@(parameterID)] =
      [text copy] ?: @"";
  if (icon)
    kkClassRegistry([self class], kKKSepIcons)[@(parameterID)] = icon;

  if (!KKAddCustomUIDisabledParam(paramAPI, parameterID, error,
                                  @"Unable to add separator parameter")) {
    kkClassRegistry([self class], kKKSepTexts)[@(parameterID)] = nil;
    return NO;
  }
  return YES;
}

- (BOOL)addLogoBannerParameterWithAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                                error:(NSError **)error {
  return KKAddCustomUIDisabledParam(paramAPI, kKKParamLogoBanner, error,
                                    @"Unable to add logo banner parameter");
}

@end
#pragma clang diagnostic pop
