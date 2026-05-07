/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "../Math/KKTimingStage.h"
#import "../Views/KKCustomGroupHeaderView.h"
#import "KKConstants.h"
#import "KKDataBlob.h"
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

static const FxParameterFlags kCustomUI = kFxParameterFlag_NOT_ANIMATABLE |
                                          kFxParameterFlag_CUSTOM_UI |
                                          kFxParameterFlag_USE_FULL_VIEW_WIDTH;

static const FxParameterFlags kCustomUIDisabled =
    kFxParameterFlag_NOT_ANIMATABLE | kFxParameterFlag_CUSTOM_UI |
    kFxParameterFlag_USE_FULL_VIEW_WIDTH | kFxParameterFlag_DISABLED;

static const FxParameterFlags kHiddenNotAnim =
    kFxParameterFlag_HIDDEN | kFxParameterFlag_NOT_ANIMATABLE;

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKPlugin (TimingParams)

- (BOOL)addMultiStageParametersWithAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                                 error:(NSError **)error {
  if (!KKAddParam([paramAPI
                      addCustomParameterWithName:@""
                                     parameterID:kKKParamAnimationSeparator
                                    defaultValue:@(kKKParamAnimationSeparator)
                                  parameterFlags:kCustomUI],
                  error, @"Unable to add Timing group"))
    return NO;

  if (!KKAddParam([paramAPI
                      addCustomParameterWithName:@""
                                     parameterID:kKKParamTimingCurvePreview
                                    defaultValue:@(kKKParamTimingCurvePreview)
                                  parameterFlags:kCustomUIDisabled],
                  error, @"Unable to add Curve Preview"))
    return NO;

  if (!KKAddParam([paramAPI addToggleButtonWithName:@""
                                        parameterID:kKKParamTimingExpanded
                                       defaultValue:YES
                                     parameterFlags:kHiddenNotAnim],
                  error, @"Unable to add Timing expanded toggle"))
    return NO;

  if (!KKAddParam([paramAPI addToggleButtonWithName:@""
                                        parameterID:kKKParamTimingLoopEnabled
                                       defaultValue:NO
                                     parameterFlags:kHiddenNotAnim],
                  error, @"Unable to add timing loop toggle"))
    return NO;

  // Custom parameter (KKDataBlob wrapping the lanes-JSON UTF-8 bytes).
  // String params can't be undone in FCP — `setStringParameterValue:` has
  // no `atTime:` variant and FCP filters those writes off its undo stack.
  // Custom params route through `setCustomParameterValue:atTime:`, the
  // same pipeline animatable scalars use, which IS undoable.
  // NOT_ANIMATABLE deliberately omitted — that flag would re-exclude the
  // param from the undo path.
  if (!KKAddParam([paramAPI
                      addCustomParameterWithName:@""
                                     parameterID:kKKParamMultiStageData
                                    defaultValue:[KKDataBlob blobWithData:nil]
                                  parameterFlags:kFxParameterFlag_HIDDEN],
                  error, @"Unable to add multi-stage data"))
    return NO;

  if (!KKAddParam([paramAPI
                      addIntSliderWithName:@""
                               parameterID:kKKParamMultiStageSelectedProperty
                              defaultValue:0
                              parameterMin:0
                              parameterMax:64
                                 sliderMin:0
                                 sliderMax:64
                                     delta:1
                            parameterFlags:kHiddenNotAnim],
                  error, @"Unable to add multi-stage selected property"))
    return NO;

  if (!KKAddParam([paramAPI addIntSliderWithName:@""
                                     parameterID:kKKParamMultiStageSelectedStage
                                    defaultValue:0
                                    parameterMin:0
                                    parameterMax:64
                                       sliderMin:0
                                       sliderMax:64
                                           delta:1
                                  parameterFlags:kHiddenNotAnim],
                  error, @"Unable to add multi-stage selected stage"))
    return NO;

  if (!KKAddParam([paramAPI addStringParameterWithName:@""
                                           parameterID:kKKParamInstanceID
                                          defaultValue:@""
                                        parameterFlags:kHiddenNotAnim],
                  error, @"Unable to add instance ID"))
    return NO;

  return YES;
}

- (BOOL)addAnimationParametersWithAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                                error:(NSError **)error {
  return [self addMultiStageParametersWithAPI:paramAPI error:error];
}

- (BOOL)addMotionBlurParametersWithAPI:(id<FxParameterCreationAPI_v5>)paramAPI
                                 error:(NSError **)error {

  if (!KKAddParam([paramAPI
                      addCustomParameterWithName:@""
                                     parameterID:kKKParamMotionBlurSeparator
                                    defaultValue:@(kKKParamMotionBlurSeparator)
                                  parameterFlags:kCustomUI],
                  error, @"Unable to add Motion Blur group"))
    return NO;

  // Hidden — driven by the checkbox in the group header view.
  if (!KKAddParam([paramAPI addToggleButtonWithName:@""
                                        parameterID:kKKParamMotionBlurEnabled
                                       defaultValue:NO
                                     parameterFlags:kHiddenNotAnim],
                  error, @"Unable to add Motion Blur enabled toggle"))
    return NO;

  // UI-only: header chevron state. Hidden, persisted, starts collapsed.
  if (!KKAddParam([paramAPI addToggleButtonWithName:@""
                                        parameterID:kKKParamMotionBlurExpanded
                                       defaultValue:NO
                                     parameterFlags:kHiddenNotAnim],
                  error, @"Unable to add Motion Blur expanded toggle"))
    return NO;

  // Length: 0–100% maps to 0–360° shutter angle. Default 50% = 180°.
  // Starts hidden (group collapsed by default); shown by
  // updateMotionBlurParameterVisibility when expanded.
  if (!KKAddParam([paramAPI addPercentSliderWithName:@"Length"
                                         parameterID:kKKParamMotionBlurShutter
                                        defaultValue:0.5
                                        parameterMin:0.0
                                        parameterMax:1.0
                                           sliderMin:0.0
                                           sliderMax:1.0
                                               delta:0.01
                                      parameterFlags:kFxParameterFlag_HIDDEN],
                  error, @"Unable to add Motion Blur Length slider"))
    return NO;

  // Quality: 0–100% maps exponentially to 2–128 samples. Default 50% ≈ 16.
  if (!KKAddParam([paramAPI addPercentSliderWithName:@"Quality"
                                         parameterID:kKKParamMotionBlurQuality
                                        defaultValue:0.5
                                        parameterMin:0.0
                                        parameterMax:1.0
                                           sliderMin:0.0
                                           sliderMax:1.0
                                               delta:0.01
                                      parameterFlags:kFxParameterFlag_HIDDEN],
                  error, @"Unable to add Motion Blur Quality slider"))
    return NO;

  if (!KKAddParam([paramAPI
                      addToggleButtonWithName:@"Transitions only?"
                                  parameterID:kKKParamMotionBlurTransitionsOnly
                                 defaultValue:NO
                               parameterFlags:kFxParameterFlag_HIDDEN |
                                              kFxParameterFlag_NOT_ANIMATABLE],
                  error, @"Unable to add Motion Blur transitions-only toggle"))
    return NO;

  return YES;
}

/// Mask of the parameter-flag bits we manage. FCP/Motion silently OR in
/// internal bits (observed: 0x20200) on top of whatever we wrote, so a raw
/// `cur != want` check never converges and we register a phantom undo
/// entry on every `parameterChanged:`. Compare only our own bits, and
/// preserve the host's bits when writing.
static const FxParameterFlags kKKMutableFlagMask =
    kFxParameterFlag_HIDDEN | kFxParameterFlag_DISABLED |
    kFxParameterFlag_NOT_ANIMATABLE |
    kFxParameterFlag_DONT_DISPLAY_IN_DASHBOARD | kFxParameterFlag_CUSTOM_UI |
    kFxParameterFlag_USE_FULL_VIEW_WIDTH;

static void _setFlagsIfNeeded(id<FxParameterSettingAPI_v5> setAPI,
                              id<FxParameterRetrievalAPI_v6> getAPI,
                              FxParameterFlags flags, UInt32 paramID) {
  FxParameterFlags cur = 0;
  [getAPI getParameterFlags:&cur fromParameter:paramID];
  if ((cur & kKKMutableFlagMask) != (flags & kKKMutableFlagMask)) {
    FxParameterFlags merged =
        (cur & ~kKKMutableFlagMask) | (flags & kKKMutableFlagMask);
    [setAPI setParameterFlags:merged toParameter:paramID];
  }
}

- (void)updateTimingParameterVisibility {
  // setParameterFlags on params in the kKKParam range (9000s) crashes FCP
  // when called synchronously from `parameterChanged:` — the host action
  // wrapping the user's interaction (group toggle, OSC drag) ends with our
  // flag-writes in the bulk-change list and FCP's transaction processor
  // null-derefs walking the channel tree. Defer onto the main queue inside
  // a fresh action scope so the writes land outside FCP's host action.
  // See project_published_custom_ui_cascade.md.
  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    if (!actAPI)
      return;
    [actAPI startAction:strongSelf];
    id<FxParameterRetrievalAPI_v6> paramGetAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> paramSetAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    if (!paramGetAPI || !paramSetAPI) {
      [actAPI endAction:strongSelf];
      return;
    }

    BOOL expandedTiming = NO;
    [paramGetAPI getBoolValue:&expandedTiming
                fromParameter:kKKParamTimingExpanded
                       atTime:kCMTimeZero];
    BOOL effectiveExpanded = expandedTiming;
    if ([strongSelf forceShowAllParameters])
      effectiveExpanded = YES;
    _setFlagsIfNeeded(paramSetAPI, paramGetAPI,
                      effectiveExpanded ? kCustomUI : kFxParameterFlag_HIDDEN,
                      kKKParamTimingCurvePreview);
    [actAPI endAction:strongSelf];
    KKCustomGroupHeaderView *header = strongSelf.timingHeader;
    KKRunOnMain(^{
      if (header.isExpanded != expandedTiming)
        header.isExpanded = expandedTiming;
    });
  });
}

- (void)updateMotionBlurParameterVisibility {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!paramGetAPI || !paramSetAPI)
    return;

  BOOL expanded = NO;
  [paramGetAPI getBoolValue:&expanded
              fromParameter:kKKParamMotionBlurExpanded
                     atTime:kCMTimeZero];
  if ([self forceShowAllParameters])
    expanded = YES;

  FxParameterFlags flag =
      expanded ? kFxParameterFlag_DEFAULT : kFxParameterFlag_HIDDEN;
  FxParameterFlags toggleFlag =
      expanded ? kFxParameterFlag_NOT_ANIMATABLE
               : (kFxParameterFlag_HIDDEN | kFxParameterFlag_NOT_ANIMATABLE);
  _setFlagsIfNeeded(paramSetAPI, paramGetAPI, flag, kKKParamMotionBlurShutter);
  _setFlagsIfNeeded(paramSetAPI, paramGetAPI, flag, kKKParamMotionBlurQuality);
  _setFlagsIfNeeded(paramSetAPI, paramGetAPI, toggleFlag,
                    kKKParamMotionBlurTransitionsOnly);

  BOOL persistedExpanded = NO;
  [paramGetAPI getBoolValue:&persistedExpanded
              fromParameter:kKKParamMotionBlurExpanded
                     atTime:kCMTimeZero];
  BOOL persistedEnabled = NO;
  [paramGetAPI getBoolValue:&persistedEnabled
              fromParameter:kKKParamMotionBlurEnabled
                     atTime:kCMTimeZero];
  __weak typeof(self) weakSelf = self;
  KKRunOnMain(^{
    KKCustomGroupHeaderView *hdr = weakSelf.motionBlurHeader;
    if (hdr.isExpanded != persistedExpanded)
      hdr.isExpanded = persistedExpanded;
    if (hdr.isEnabled != persistedEnabled)
      hdr.isEnabled = persistedEnabled;
  });
}

@end
#pragma clang diagnostic pop
