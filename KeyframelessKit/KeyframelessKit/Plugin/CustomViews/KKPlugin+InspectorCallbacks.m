/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPlugin+InspectorCallbacks.h"

#import "KKConstants.h"
#import "KKCurveDefaults.h"
#import "KKDataBlob.h"
#import "KKDragUndoSession.h"
#import "KKHostInfo.h"
#import "KKLog.h"
#import "KKMotionBlur.h"
#import "KKPlugin.h"
#import "KKPluginHost.h"
#import "KKPluginInstanceState.h"
#import "KKPresets.h"
#import "KKTimelineInspectorView.h"
#import "KKTimelineLanesView.h"
#import <FxPlug/FxPlugSDK.h>

@implementation KKInspectorPersistedState
@end

@implementation KKInspectorCreateContext
@end

@implementation KKPlugin (InspectorCallbacks)

- (nullable KKTimelineInspectorView *)
    kkCreateInspectorViewWithUIStateParamID:(UInt32)uiStateParamID
                         renderNudgeParamID:(UInt32)renderNudgeParamID
                              dragUndoLabel:(NSString *)dragUndoLabel
                         detachedWindowSize:(CGSize)detachedWindowSize
                             builtinPresets:(NSArray<KKPreset *> *)presets
                                    inScope:(void (^)(
                                                KKInspectorCreateContext *,
                                                id<FxParameterRetrievalAPI_v6>))
                                                inScope
                                  buildView:(KKTimelineInspectorView * (^)(
                                                KKInspectorCreateContext *))
                                                buildView {
  KKInspectorCreateContext *ctx = [KKInspectorCreateContext new];
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  ctx.persistedState =
      [self kkReadInspectorPersistedStateWithGetAPI:getAPI
                                     uiStateParamID:uiStateParamID];
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  if (timingAPI) {
    CMTime frameDur = kCMTimeZero, clipDur = kCMTimeZero;
    [timingAPI frameDuration:&frameDur];
    [timingAPI durationTimeForEffect:&clipDur];
    ctx.seedFrameDurSec = CMTimeGetSeconds(frameDur);
    ctx.seedClipDurSec = CMTimeGetSeconds(clipDur);
  }
  ctx.instanceState = KKInstanceStateEnsureForAPI(self.apiManager);
  if (inScope)
    inScope(ctx, getAPI);
  [actionAPI endAction:self];

  ctx.instanceUUID = KKInstanceUUIDForAPI(self.apiManager);
  KKTimelineInspectorView *view = buildView(ctx);
  if (!view)
    return nil;
  if (ctx.seedClipDurSec > 0)
    [view setClipDurationSeconds:ctx.seedClipDurSec];
  if (ctx.seedFrameDurSec > 0)
    [view setFrameDurationSeconds:ctx.seedFrameDurSec];
  KKInspectorPersistedState *st = ctx.persistedState;
  [view setMotionBlurEnabled:st.motionBlurEnabled];
  [view setMotionBlurShutterAngle:st.motionBlurShutterAngle
                          samples:st.motionBlurSamples];
  [view setMotionBlurTechnique:(KKMotionBlurTechnique)st.motionBlurTechnique];
  [self kkWireStandardInspectorCallbacksForView:view
                                 uiStateParamID:uiStateParamID
                             renderNudgeParamID:renderNudgeParamID
                                  dragUndoLabel:dragUndoLabel
                             detachedWindowSize:detachedWindowSize];
  if (presets.count)
    [[KKPresets shared] registerBuiltinPresets:presets
                                  forPluginKey:[self presetPluginKey]];
  self.inspectorView = view;
  return view;
}

- (void)kkHandleMotionBlurDataChangedPushingTechnique:(BOOL)pushTechnique {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSString *json = KKReadCustomParamString(getAPI, kKKParamMotionBlurData);
  [actionAPI endAction:self];
  NSDictionary *mb =
      (json.length
           ? [NSJSONSerialization
                 JSONObjectWithData:[json
                                        dataUsingEncoding:NSUTF8StringEncoding]
                            options:0
                              error:nil]
           : nil)
          ?: @{};
  BOOL mbEnabled = [mb[@"enabled"] boolValue];
  double mbShutterAngle =
      mb[@"shutterAngle"] ? [mb[@"shutterAngle"] doubleValue] : 180.0;
  NSInteger mbSamples = mb[@"samples"] ? [mb[@"samples"] integerValue] : 16;
  // Technique (Fast=0/Accurate=1); migrate a legacy "mode"-only blob.
  NSInteger mbTechnique =
      mb[@"technique"]
          ? [mb[@"technique"] integerValue]
          : (mb[@"mode"] && [mb[@"mode"] integerValue] == KKMotionBlurModeAlways
                 ? KKMotionBlurTechniqueAccurate
                 : KKMotionBlurTechniqueFast);
  dispatch_async(dispatch_get_main_queue(), ^{
    [self.inspectorView setMotionBlurEnabled:mbEnabled];
    [self.inspectorView setMotionBlurShutterAngle:mbShutterAngle
                                          samples:mbSamples];
    if (pushTechnique)
      [self.inspectorView
          setMotionBlurTechnique:(KKMotionBlurTechnique)mbTechnique];
  });
}

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
  // Same key scopes the curve popover's saved default. Re-asserted per wire, so
  // in a ViewBridge process shared across plugins the active scope always
  // belongs to the inspector whose popover is open.
  KKDefaultsSetActiveScope([self presetPluginKey]);

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
  view.onMotionBlurChanged =
      ^(BOOL enabled, double shutterAngle, NSInteger samples,
        KKMotionBlurTechnique technique) {
        __strong typeof(weak) strong = weak;
        if (!strong)
          return;
        [strong kkInParamAction:^(id<FxParameterRetrievalAPI_v6> getAPI,
                                  id<FxParameterSettingAPI_v5> setAPI,
                                  CMTime actionTime) {
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
        }];
      };
  view.onTimelineMutated = ^(KKTimeline *updated) {
    __strong typeof(weak) strong = weak;
    if (!strong)
      return;
    [strong kkInParamAction:^(id<FxParameterRetrievalAPI_v6> getAPI,
                              id<FxParameterSettingAPI_v5> setAPI,
                              CMTime actionTime) {
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
    }];
  };

  // Coalesce a continuous mini-viewer handle drag into one undo entry: the
  // per-tick onTimelineMutated writes nest inside this outer group. FxUndoAPI
  // resolves to nil outside an action scope, so begin/end run inside one.
  view.onDragBegin = ^{
    __strong typeof(weak) strong = weak;
    if (!strong)
      return;
    // The overlay guarantees a balanced onHandleDragEnd (it ends any active
    // drag before a new press and on teardown), so a session should never
    // already be open here. If one is - a SECOND overlay (keypose popover over
    // the constants popover) pressed while the first still held its session -
    // close it before opening the next. Overwriting the property instead would
    // end the old group AFTER the new one began, and that out-of-order
    // endUndoGroup is what leaves FCP's undo stack pointing at a dead action
    // (EXC_BAD_ACCESS in FFUndoHandler on the next Cmd-Z).
    if (strong.miniDragSession.active) {
      KKLogWarn(@"[dragundo] onDragBegin while a session is already open - "
                @"closing the stale one first");
      [strong.miniDragSession finish];
      strong.miniDragSession = nil;
    }
    strong.miniDragSession =
        [KKDragUndoSession beginWithAPIManager:strong.apiManager
                                     principal:strong
                                          name:dragUndoLabel
                                          mode:KKDragUndoSessionModeGroupOnly];
  };
  view.onDragEnd = ^{
    __strong typeof(weak) strong = weak;
    if (!strong)
      return;
    [strong.miniDragSession finish];
    strong.miniDragSession = nil;
  };

  // Boundary popover just wrote its request file. FCP only re-runs
  // scheduleInputs: on a render, and serves a cached frame for a static
  // playhead. Writing a fresh random value to a hidden scratch param makes FCP
  // treat it as a real change -> re-render -> scheduleInputs picks up the file.
  view.onBoundaryPreviewNeedsRender = ^{
    __strong typeof(weak) strong = weak;
    if (!strong)
      return;
    [strong kkInParamAction:^(id<FxParameterRetrievalAPI_v6> getAPI,
                              id<FxParameterSettingAPI_v5> setAPI,
                              CMTime actionTime) {
      NSString *nonce = [[NSUUID UUID] UUIDString];
      KKWriteCustomParamString(setAPI, nonce, renderNudgeParamID);
    }];
  };

  // Scrub: drag the Basic playhead -> move the host playhead. FxTimingAPI
  // resolves inside this action scope (nil in the render tick).
  view.onScrub = ^(double frac) {
    __strong typeof(weak) strong = weak;
    if (!strong)
      return;
    [strong kkInActionScope:^{
      id<FxTimingAPI_v4> timing =
          [strong.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
      id<FxCommandAPI_v2> cmd =
          [strong.apiManager apiForProtocol:@protocol(FxCommandAPI_v2)];
      id<FxCustomParameterActionAPI_v4> action = [strong.apiManager
          apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      if (!timing || !cmd)
        return;

      CMTime effectStart = kCMTimeZero, effectDuration = kCMTimeZero;
      CMTime inputStart = kCMTimeZero, inputDuration = kCMTimeZero;
      CMTime timelineStart = kCMTimeZero, timelineEnd = kCMTimeZero;
      CMTime timelineIn = kCMTimeInvalid, timelineOut = kCMTimeInvalid;
      [timing startTimeForEffect:&effectStart];
      [timing durationTimeForEffect:&effectDuration];
      [timing startTimeOfInputToFilter:&inputStart];
      [timing durationTimeOfInputToFilter:&inputDuration];
      [timing inPointTimeOfTimelineForEffect:&timelineIn];
      [timing outPointTimeOfTimelineForEffect:&timelineOut];

      double startSec, endSec;
      if ([KKHostInfo isRunningInFinalCut]) {
        [timing timelineTime:&timelineStart fromInputTime:inputStart];
        [timing timelineTime:&timelineEnd
               fromInputTime:CMTimeAdd(inputStart, inputDuration)];
        startSec = CMTimeGetSeconds(timelineStart);
        endSec = CMTimeGetSeconds(timelineEnd);
      } else {
        startSec = CMTimeGetSeconds(effectStart);
        endSec = startSec + CMTimeGetSeconds(effectDuration);
      }
      if (!(endSec > startSec))
        return;

      double frameDur = KKProcessFrameDurationSeconds();
      double targetSec = startSec + frac * (endSec - startSec);
      double lo = startSec + frameDur * 0.5;
      double hi = endSec - frameDur * 0.5;
      if (hi > lo)
        targetSec = MAX(lo, MIN(hi, targetSec));

      CMTime currentTime = action ? [action currentTime] : kCMTimeInvalid;
      // A filter on a Motion transition layer reports template-local timeline
      // values here (e.g. 7s), while FxCommandAPI expects the parent FCP
      // timeline clock (e.g. 7207s). The render tick publishes that real
      // parent-project start onto the inspector; use it for the same one-shot
      // absolute seek ordinary clips use.
      BOOL localTimelineMapping =
          [KKHostInfo isRunningInFinalCut] &&
          startSec + frameDur < CMTimeGetSeconds(inputStart);
      if (localTimelineMapping) {
        KKLogWarn(@"[scrub-local-timeline] cannot seek without the outer "
                  @"project origin: frac=%.6f current=%.6f effectStart=%.6f "
                  @"inputStart=%.6f localStart=%.6f timelineIn=%.6f "
                  @"timelineOut=%.6f",
                  frac, CMTimeGetSeconds(currentTime),
                  CMTimeGetSeconds(effectStart), CMTimeGetSeconds(inputStart),
                  startSec, CMTimeGetSeconds(timelineIn),
                  CMTimeGetSeconds(timelineOut));
        return;
      }

      CMTime targetTime = CMTimeMakeWithSeconds(targetSec, 600);
      NSError *seekError = nil;
      BOOL moved = [cmd movePlayheadToTime:targetTime error:&seekError];
      KKLogInfo(@"[scrub] frac=%.6f current=%.6f effectStart=%.6f "
                @"effectDuration=%.6f inputStart=%.6f inputDuration=%.6f "
                @"timelineStart=%.6f timelineEnd=%.6f timelineIn=%.6f "
                @"timelineOut=%.6f frame=%.6f "
                @"target=%.6f fcp=%d timing=%p command=%p action=%p "
                @"seekScope=inside-action moved=%d error=%@",
                frac, CMTimeGetSeconds(currentTime),
                CMTimeGetSeconds(effectStart), CMTimeGetSeconds(effectDuration),
                CMTimeGetSeconds(inputStart), CMTimeGetSeconds(inputDuration),
                startSec, endSec, CMTimeGetSeconds(timelineIn),
                CMTimeGetSeconds(timelineOut), frameDur, targetSec,
                [KKHostInfo isRunningInFinalCut], timing, cmd, action, moved,
                seekError);
    }];
  };

  // Spacebar in the inspector -> play/pause (FCP eats it otherwise).
  view.onTogglePlayback = ^{
    __strong typeof(weak) strong = weak;
    if (!strong)
      return;
    [strong kkInActionScope:^{
      id<FxCommandAPI_v2> cmd =
          [strong.apiManager apiForProtocol:@protocol(FxCommandAPI_v2)];
      [cmd performCommand:kFxCommand_TogglePlayback error:nil];
    }];
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
