/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPlugin+InspectorCallbacks.h"

#import "KKConstants.h"
#import "KKDataBlob.h"
#import "KKHostInfo.h"
#import "KKMotionBlur.h"
#import "KKPlugin.h"
#import "KKPluginHost.h"
#import "KKTimelineInspectorView.h"
#import "KKTimelineLanesView.h"
#import <FxPlug/FxPlugSDK.h>

@implementation KKInspectorPersistedState
@end

@implementation KKPlugin (InspectorCallbacks)

- (KKInspectorPersistedState *)
    kkReadInspectorPersistedStateWithGetAPI:
        (id<FxParameterRetrievalAPI_v6>)getAPI
                             uiStateParamID:(UInt32)uiStateParamID {
  KKInspectorPersistedState *st = [[KKInspectorPersistedState alloc] init];

  NSString *uiJson = KKReadCustomParamString(getAPI, uiStateParamID);
  NSDictionary *uiState =
      uiJson.length
          ? [NSJSONSerialization
                JSONObjectWithData:[uiJson
                                       dataUsingEncoding:NSUTF8StringEncoding]
                           options:0
                             error:nil]
                ?: @{}
          : @{};
  st.uiState = uiState;
  st.loopEnabled = [uiState[@"loopEnabled"] boolValue];
  st.maintainTimingEnabled = [uiState[@"maintainTiming"] boolValue];
  st.activeTab = [uiState[@"activeTab"] integerValue];
  // Default visible when the key is absent (existing clips never wrote it).
  st.oscMasterVisible = uiState[@"oscMasterVisible"]
                            ? [uiState[@"oscMasterVisible"] boolValue]
                            : YES;
  // Migration: legacy onionSkinEnabled BOOL -> renderMode enum (0=Off,
  // 1=Filmstrip, 2=Onion). Old true maps to Filmstrip.
  KKMiniViewerRenderMode renderMode = KKMiniViewerRenderModeOff;
  if (uiState[@"renderMode"])
    renderMode = (KKMiniViewerRenderMode)[uiState[@"renderMode"] integerValue];
  else if ([uiState[@"onionSkinEnabled"] boolValue])
    renderMode = KKMiniViewerRenderModeFilmstrip;
  st.renderMode = renderMode;

  NSString *mbJson = KKReadCustomParamString(getAPI, kKKParamMotionBlurData);
  NSDictionary *mbState =
      (mbJson.length
           ? [NSJSONSerialization
                 JSONObjectWithData:[mbJson
                                        dataUsingEncoding:NSUTF8StringEncoding]
                            options:0
                              error:nil]
           : nil)
          ?: @{};
  st.motionBlurEnabled = [mbState[@"enabled"] boolValue];
  st.motionBlurShutterAngle =
      mbState[@"shutterAngle"] ? [mbState[@"shutterAngle"] doubleValue] : 180.0;
  st.motionBlurSamples =
      mbState[@"samples"] ? [mbState[@"samples"] integerValue] : 16;
  // Technique (Fast=0 / Accurate=1). Migrate a legacy "mode"-only blob: the old
  // "Always" was the footage-smear case, which is Accurate.
  if (mbState[@"technique"])
    st.motionBlurTechnique = [mbState[@"technique"] integerValue];
  else if (mbState[@"mode"])
    st.motionBlurTechnique =
        ([mbState[@"mode"] integerValue] == KKMotionBlurModeAlways)
            ? KKMotionBlurTechniqueAccurate
            : KKMotionBlurTechniqueFast;
  else
    st.motionBlurTechnique = KKMotionBlurTechniqueFast;

  NSString *timelineJson =
      KKReadCustomParamString(getAPI, kKKParamTimelineData);
  st.timeline =
      (timelineJson.length ? [KKTimeline timelineFromJSON:timelineJson] : nil)
          ?: [KKTimeline timeline];
  return st;
}

- (void)kkWireStandardInspectorCallbacksForView:(KKTimelineInspectorView *)view
                                 uiStateParamID:(UInt32)uiStateParamID
                             renderNudgeParamID:(UInt32)renderNudgeParamID
                                  dragUndoLabel:(NSString *)dragUndoLabel
                             detachedWindowSize:(CGSize)detachedWindowSize {
  __weak typeof(self) weak = self;
  __weak KKTimelineInspectorView *weakView = view;

  // Namespace the Presets row to this plugin so its saved/built-in presets
  // never bleed across plugins (their lane sets differ).
  view.presetPluginKey = [self presetPluginKey];

  view.onLoopToggled = ^(BOOL enabled) {
    __strong typeof(weak) strong = weak;
    if (!strong)
      return;
    [strong patchUIStateKey:@"loopEnabled"
                      value:@(enabled)
                    paramID:uiStateParamID];
  };
  view.onMaintainTimingToggled = ^(BOOL enabled) {
    __strong typeof(weak) strong = weak;
    if (!strong)
      return;
    [strong patchMaintainTimingEnabled:enabled paramID:uiStateParamID];
  };
  view.onTabChanged = ^(NSInteger tab) {
    __strong typeof(weak) strong = weak;
    if (!strong)
      return;
    [strong patchUIStateKey:@"activeTab" value:@(tab) paramID:uiStateParamID];
  };
  view.onRenderModeChanged = ^(KKMiniViewerRenderMode mode) {
    __strong typeof(weak) strong = weak;
    if (!strong)
      return;
    [strong patchUIStateKey:@"renderMode"
                      value:@((NSInteger)mode)
                    paramID:uiStateParamID];
  };
  view.onMotionBlurChanged = ^(BOOL enabled, double shutterAngle,
                               NSInteger samples,
                               KKMotionBlurTechnique technique) {
    __strong typeof(weak) strong = weak;
    if (!strong)
      return;
    id<FxCustomParameterActionAPI_v4> act = [strong.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    if (!act)
      return;
    [act startAction:strong];
    id<FxParameterSettingAPI_v5> setAPI =
        [strong.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    NSDictionary *mb = @{
      @"enabled" : @(enabled),
      @"shutterAngle" : @(shutterAngle),
      @"samples" : @(samples),
      @"technique" : @((NSInteger)technique)
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:mb
                                                   options:0
                                                     error:nil];
    NSString *json = [[NSString alloc] initWithData:data
                                           encoding:NSUTF8StringEncoding];
    if (json)
      KKWriteCustomParamString(setAPI, json, kKKParamMotionBlurData);
    [act endAction:strong];
  };
  view.onTimelineMutated = ^(KKTimeline *updated) {
    __strong typeof(weak) strong = weak;
    if (!strong)
      return;
    id<FxCustomParameterActionAPI_v4> act = [strong.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    if (!act)
      return;
    [act startAction:strong];
    id<FxParameterSettingAPI_v5> setAPI =
        [strong.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    NSString *json = [KKTimeline jsonFromTimeline:updated];
    if (json)
      KKWriteCustomParamString(setAPI, json, kKKParamTimelineData);
    // Writing the timeline blob alone doesn't re-render: FCP serves a cached
    // frame for a static playhead until a scratch param changes. Nudge so a
    // persisted change (e.g. a pasted shader source, which never touches a
    // value field) reaches the render immediately instead of waiting for the
    // next unrelated param write.
    KKWriteCustomParamString(setAPI, [[NSUUID UUID] UUIDString],
                             renderNudgeParamID);
    [act endAction:strong];
  };

  // Coalesce a continuous mini-viewer handle drag into one undo entry: the
  // per-tick onTimelineMutated writes nest inside this outer group. FxUndoAPI
  // resolves to nil outside an action scope, so begin/end run inside one.
  view.onDragBegin = ^{
    __strong typeof(weak) strong = weak;
    if (!strong)
      return;
    id<FxCustomParameterActionAPI_v4> act = [strong.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    if (!act)
      return;
    [act startAction:strong];
    strong.miniDragUndoStarted =
        KKBeginUndoGroup(strong.apiManager, dragUndoLabel);
    [act endAction:strong];
  };
  view.onDragEnd = ^{
    __strong typeof(weak) strong = weak;
    if (!strong)
      return;
    id<FxCustomParameterActionAPI_v4> act = [strong.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    if (act)
      [act startAction:strong];
    KKEndUndoGroup(strong.apiManager, strong.miniDragUndoStarted);
    if (act)
      [act endAction:strong];
    strong.miniDragUndoStarted = NO;
  };

  // Boundary popover just wrote its request file. FCP only re-runs
  // scheduleInputs: on a render, and serves a cached frame for a static
  // playhead. Writing a fresh random value to a hidden scratch param makes FCP
  // treat it as a real change -> re-render -> scheduleInputs picks up the file.
  view.onBoundaryPreviewNeedsRender = ^{
    __strong typeof(weak) strong = weak;
    if (!strong)
      return;
    id<FxCustomParameterActionAPI_v4> act = [strong.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    if (!act)
      return;
    [act startAction:strong];
    id<FxParameterSettingAPI_v5> setAPI =
        [strong.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    NSString *nonce = [[NSUUID UUID] UUIDString];
    KKWriteCustomParamString(setAPI, nonce, renderNudgeParamID);
    [act endAction:strong];
  };

  // Scrub: drag the Basic playhead -> move the host playhead. FxTimingAPI
  // resolves inside this action scope (nil in the render tick).
  view.onScrub = ^(double frac) {
    __strong typeof(weak) strong = weak;
    if (!strong)
      return;
    id<FxCustomParameterActionAPI_v4> act = [strong.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    if (!act)
      return;
    [act startAction:strong];
    id<FxTimingAPI_v4> timing =
        [strong.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
    id<FxCommandAPI_v2> cmd =
        [strong.apiManager apiForProtocol:@protocol(FxCommandAPI_v2)];
    CMTime es = kCMTimeZero, ed = kCMTimeZero;
    [timing startTimeForEffect:&es];
    [timing durationTimeForEffect:&ed];
    double dsec = CMTimeGetSeconds(ed);
    double base;
    if ([KKHostInfo isRunningInFinalCut]) {
      CMTime src = kCMTimeZero, tl = kCMTimeZero;
      [timing startTimeOfInputToFilter:&src];
      [timing timelineTime:&tl fromInputTime:src];
      base = CMTimeGetSeconds(tl);
    } else {
      base = CMTimeGetSeconds(es);
    }
    if (dsec > 0.0) {
      // FCP's movePlayheadToTime: floors a time sitting on a frame seam to the
      // previous frame, so snapping to a keypose lands one frame short and the
      // OSC's half-frame visibility window rejects it (handle vanishes). Nudge
      // half a frame in so it rounds onto the intended frame - same trick the
      // loop-back path uses.
      double frameDur = KKProcessFrameDurationSeconds();
      double target = base + frac * dsec + frameDur * 0.5;
      [cmd movePlayheadToTime:CMTimeMakeWithSeconds(target, 600) error:nil];
    }
    [act endAction:strong];
  };

  // Spacebar in the inspector -> play/pause (FCP eats it otherwise).
  view.onTogglePlayback = ^{
    __strong typeof(weak) strong = weak;
    if (!strong)
      return;
    id<FxCustomParameterActionAPI_v4> act = [strong.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    if (!act)
      return;
    [act startAction:strong];
    id<FxCommandAPI_v2> cmd =
        [strong.apiManager apiForProtocol:@protocol(FxCommandAPI_v2)];
    [cmd performCommand:kFxCommand_TogglePlayback error:nil];
    [act endAction:strong];
  };

  view.onToggleDetached = ^{
    __strong typeof(weak) strong = weak;
    __strong KKTimelineInspectorView *insp = weakView;
    if (!strong || !insp)
      return;
    if (insp.hasDetachedWindow) {
      [strong closeRemoteWindowIfSupported];
      return;
    }
    [strong presentRemoteWindowOfSize:detachedWindowSize
                      contentProvider:^NSView * {
                        return [insp beginDetachedCopy];
                      }];
  };
}

@end
