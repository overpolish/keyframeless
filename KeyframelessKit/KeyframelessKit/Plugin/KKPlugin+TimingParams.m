/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKConstants.h"
#import "KKCustomGroupHeaderView.h"
#import "KKDataBlob.h"
#import "KKPlugin_Private.h"
#import "KKTimeline.h"
#import <FxPlug/FxPlugSDK.h>

static BOOL KKAddParam(BOOL ok, NSError **err, NSString *desc) {
  if (ok)
    return YES;
  if (err)
    *err = [NSError errorWithDomain:@"com.keyframeless.error"
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

- (nullable id<FxParameterCreationAPI_v5>)
    kkAddStandardParametersWithInspectorUI:(UInt32)inspectorUIID
                                   uiState:(UInt32)uiStateID
                               renderNudge:(UInt32)renderNudgeID
                     motionBlurDefaultJSON:(NSString *)mbDefaultJSON
                                     error:(NSError **)error {
  id<FxParameterCreationAPI_v5> paramAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterCreationAPI_v5)];
  if (!paramAPI) {
    if (error != NULL) {
      // The kit's own domain: FxPlugErrorDomain is a data symbol in
      // FxPlug.framework, which the kit doesn't link (plugin targets do).
      *error = [NSError errorWithDomain:@"com.keyframeless.error"
                                   code:kFxError_APIUnavailable
                               userInfo:@{
                                 NSLocalizedDescriptionKey :
                                     @"Unable to obtain an FxPlug API Object"
                               }];
    }
    return nil;
  }
  if (![self addLogoBannerParameterWithAPI:paramAPI error:error])
    return nil;
  if (!KKAddParam([paramAPI addCustomParameterWithName:@""
                                           parameterID:inspectorUIID
                                          defaultValue:@(inspectorUIID)
                                        parameterFlags:kCustomUIDisabled],
                  error, @"Unable to add inspector custom UI"))
    return nil;
  if (!KKAddParam(
          [paramAPI addCustomParameterWithName:@""
                                   parameterID:uiStateID
                                  defaultValue:[KKDataBlob blobWithData:nil]
                                parameterFlags:kFxParameterFlag_HIDDEN],
          error, @"Unable to add UI-state blob"))
    return nil;
  if (!KKAddParam(
          [paramAPI addCustomParameterWithName:@""
                                   parameterID:kKKParamTimelineData
                                  defaultValue:[KKDataBlob blobWithData:nil]
                                parameterFlags:kFxParameterFlag_HIDDEN],
          error, @"Unable to add timeline blob"))
    return nil;
  if (!KKAddParam([paramAPI addCustomParameterWithName:@""
                                           parameterID:renderNudgeID
                                          defaultValue:[KKDataBlob
                                                           blobWithData:nil]
                                        parameterFlags:kHiddenNotAnim],
                  error, @"Unable to add render nudge"))
    return nil;
  // The link watcher's nudge target. No parameter flag exempts a write from
  // undo (tested: plain, DONT_SAVE - which also added ~1s propagation lag -
  // and DISABLED all charge one entry per scoped write). Undo hygiene is
  // handled in KKLinkWatcher instead: it wraps each nudge burst in an
  // FxUndoAPI startUndoGroup/endUndoGroup so the entries coalesce. The blob
  // nudge above remains for user-initiated nudges that ride inside real edit
  // undo groups.
  if (!KKAddParam(
          [paramAPI addStringParameterWithName:@""
                                   parameterID:kKKParamRenderNudgeString
                                  defaultValue:@""
                                parameterFlags:kHiddenNotAnim],
          error, @"Unable to add watcher render nudge"))
    return nil;
  // Motion blur state lives in this blob (edited from the inspector MB row,
  // not native controls). Read at render time via
  // +[KKMotionBlur snapshotStateFromJSON:...]. MUST be registered or flipping
  // the toggle crashes FCP's parameter transaction.
  KKDataBlob *mbBlob = mbDefaultJSON.length
                           ? [KKDataBlob blobWithString:mbDefaultJSON]
                           : [KKDataBlob blobWithData:nil];
  if (!KKAddParam([paramAPI addCustomParameterWithName:@""
                                           parameterID:kKKParamMotionBlurData
                                          defaultValue:mbBlob
                                        parameterFlags:kHiddenNotAnim],
                  error, @"Unable to add motion-blur blob"))
    return nil;
  // Per-instance identity UUID (a STRING param - the effect AND the viewer
  // OSC read it to resolve the same KKPluginInstanceState). MUST exist before
  // KKInstanceStateEnsureForAPI writes it (createView); an unregistered write
  // crashes FCP's parameter transaction.
  if (!KKAddParam([paramAPI addStringParameterWithName:@""
                                           parameterID:kKKParamInstanceID
                                          defaultValue:@""
                                        parameterFlags:kHiddenNotAnim],
                  error, @"Unable to add instance ID"))
    return nil;
  return paramAPI;
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

  // Hidden - driven by the checkbox in the group header view. KKDataBlob-
  // backed so it lives in the same undoable custom-param pipeline as other
  // plugin-internal state. "1"/"0".
  if (!KKAddParam(
          [paramAPI addCustomParameterWithName:@""
                                   parameterID:kKKParamMotionBlurEnabled
                                  defaultValue:[KKDataBlob blobWithString:@"0"]
                                parameterFlags:kHiddenNotAnim],
          error, @"Unable to add Motion Blur enabled toggle"))
    return NO;

  // UI-only: header chevron state. KKDataBlob-backed so it lives in the
  // same undoable custom-param pipeline as other plugin state. "1"/"0".
  if (!KKAddParam(
          [paramAPI addCustomParameterWithName:@""
                                   parameterID:kKKParamMotionBlurExpanded
                                  defaultValue:[KKDataBlob blobWithString:@"0"]
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

- (void)updateMotionBlurParameterVisibility {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> paramSetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!paramGetAPI || !paramSetAPI)
    return;

  BOOL expanded =
      KKReadCustomParamBool(paramGetAPI, kKKParamMotionBlurExpanded);
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

  BOOL persistedExpanded =
      KKReadCustomParamBool(paramGetAPI, kKKParamMotionBlurExpanded);
  BOOL persistedEnabled =
      KKReadCustomParamBool(paramGetAPI, kKKParamMotionBlurEnabled);
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
