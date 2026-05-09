/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

/// Multi-stage live-update pump. Drives sequencer view updates from two
/// callback sources: `drawOSC` (authoritative when an effect is OSC-selected)
/// and `renderDestinationImage:` (fallback when an unrelated plugin has OSC
/// focus). Coordinates via recency gates to avoid flicker caused by FCP's
/// warm-up renders during slider drags.
///
/// See project_fxplug_custom_view_live_update.md for the full architecture.

#import "../../KKLog.h"
#import "../../Views/StageSequencer/KKLaneVisibilityBar.h"
#import "../../Views/StageSequencer/KKStagePlayheadView.h"
#import "../../Views/StageSequencer/KKStageSequencerRulerView.h"
#import "../../Views/StageSequencer/KKStageSequencerView.h"
#import "../KKConstants.h"
#import "../KKDataBlob.h"
#import "../KKHostInfo.h"
#import "../KKPluginInstanceState.h"
#import "../KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <QuartzCore/QuartzCore.h>

/// Timestamp of the most recent drawOSC-sourced playhead pump. Used to
/// suppress render-sourced pumps while drawOSC is active.
static NSTimeInterval sLastDrawOSCPumpTime = 0;

/// Timestamp of the most recent `parameterChanged:` on any plugin instance.
/// Suppresses render-sourced playhead pumps briefly afterwards: FCP triggers
/// warm-up renders at renderTime=0 in the wake of param changes.
static NSTimeInterval sLastParameterChangedTime = 0;

/// Window (seconds) for which a recent drawOSC/parameterChanged suppresses
/// render-sourced playhead updates. Long enough to span FCP's warm-up render
/// burst, short enough that render takes over promptly when the user stops
/// dragging.
static const NSTimeInterval kRenderSuppressionWindow = 0.2;

void KKMultiStageMarkParameterChanged(void) {
  sLastParameterChangedTime = CACurrentMediaTime();
}

static void KKFlushPendingLanes(void) {
  // Broadcast: any running callback flushes pending lanes for every live
  // instance, not just its own. FCP only runs `drawOSC` for the OSC-selected
  // effect, but the inspector may show multiple effects' sequencer views at
  // once — each needs live updates when its slider moves.
  for (KKPluginInstanceState *state in KKAllInstanceStates()) {
    NSArray<KKTimingLane *> *pending = state.pendingLanes;
    if (!pending)
      continue;
    state.pendingLanes = nil;
    KKStageSequencerView *seq = state.sequencerView;
    NSArray<KKTimingViewRefs *> *extras =
        [state.additionalTimingViews copy] ?: @[];
    if (!seq && extras.count == 0)
      continue;
    NSArray<KKTimingLane *> *visible =
        KKFilterLanesForVisibility(pending, state.hiddenLaneLabels);
    dispatch_async(dispatch_get_main_queue(), ^{
      seq.lanes = visible;
      for (KKTimingViewRefs *r in extras)
        r.seqView.lanes = visible;
    });
  }
}

/// Read the loop-enabled param and broadcast it to every ruler for the
/// instance (primary + additional). Follows the same pattern as
/// `KKSyncFromParams` — called from both pump ticks so inspector↔window
/// sync is automatic regardless of which ruler the user toggled.
static void KKSyncLoopFromParams(id<PROAPIAccessing> apiManager) {
  KKPluginInstanceState *state = KKInstanceStateForAPI(apiManager);
  if (!state)
    return;
  KKStageSequencerRulerView *primaryRuler = state.rulerView;
  NSArray<KKTimingViewRefs *> *extras =
      [state.additionalTimingViews copy] ?: @[];
  if (!primaryRuler && extras.count == 0)
    return;
  id<FxParameterRetrievalAPI_v6> getAPI =
      [apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!getAPI)
    return;
  BOOL loopEnabled = NO;
  [getAPI getBoolValue:&loopEnabled
         fromParameter:kKKParamTimingLoopEnabled
                atTime:kCMTimeZero];
  // No state-equality early-return: the toggling click handler already
  // mirrors `state.loopEnabled` synchronously, so a guard here would skip
  // the broadcast to the *other* window's ruler. `setLoopEnabled:` on each
  // ruler is itself a no-op when already in sync.
  state.loopEnabled = loopEnabled;
  dispatch_async(dispatch_get_main_queue(), ^{
    primaryRuler.loopEnabled = loopEnabled;
    for (KKTimingViewRefs *r in extras)
      r.ruler.loopEnabled = loopEnabled;
  });
}

static void KKSyncFromParams(id<PROAPIAccessing> apiManager, NSString *source);

/// Drives plugin-side reconciliation (e.g. Canvas: layers ↔ lanes). Asks
/// the plugin to reconcile against its current source items, and — when the
/// result differs from the in-memory snapshot — dispatches a JSON write
/// inside a fresh action scope.
///
/// Short-circuits via the plugin-supplied `kkReconcileFingerprintForAPI:` —
/// when the fingerprint matches the previous successful reconcile, the
/// reconcile call (and the FCP read it would otherwise need) is skipped.
///
/// Uses `state.lanesSnapshot` as the existing-lanes baseline rather than
/// reading the JSON param via XPC. The snapshot is the authoritative
/// in-memory mirror — kept in sync by `KKSyncFromParams` on the canonical
/// path and by this function's own writes — so the read is redundant.
///
/// Returns the reconciled lanes when they differ from the existing snapshot,
/// or nil when no change / no plugin / APIs unavailable. Callers should
/// prefer the returned lanes over re-reading the param: FCP doesn't reliably
/// propagate the write within the same outer tick, and a follow-up read
/// outside the action scope can return the pre-write value (per CLAUDE.md
/// FxPlug action-scope rules).
static NSArray<KKTimingLane *> *
KKReconcileLanesIfNeeded(id<PROAPIAccessing> apiManager, KKPlugin *plugin,
                         NSString *source) {
  if (!plugin)
    return nil;
  id<FxCustomParameterActionAPI_v4> actAPI =
      [apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!actAPI)
    return nil;

  KKPluginInstanceState *state = KKInstanceStateForAPI(apiManager);
  NSString *fingerprint = [plugin kkReconcileFingerprintForAPI:apiManager];
  if (state && fingerprint && state.cachedReconcileFingerprint &&
      [fingerprint isEqualToString:state.cachedReconcileFingerprint])
    return nil;

  [actAPI startAction:plugin];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!getAPI || !setAPI) {
    [actAPI endAction:plugin];
    return nil;
  }

  // Cold-start fallback: if `lanesSnapshot` hasn't been seeded yet (FCP
  // just loaded the project, store observer fired before
  // `timingGraphApplyState` could populate the snapshot from the persisted
  // JSON), reconciling against `@[]` would build lanes from scratch with
  // default segments and the JSON write below would clobber the user's
  // persisted data. Read the JSON directly here so reconcile sees the
  // real prior state and preserves segment edits across FCP restarts.
  // Hot path is untouched: once `timingGraphApplyState` (or any
  // mutation site) has seeded the snapshot, this branch is skipped.
  NSArray<KKTimingLane *> *existing = state.lanesSnapshot;
  if (existing.count == 0) {
    NSString *json = KKReadCustomParamString(getAPI, kKKParamMultiStageData);
    if (json.length) {
      NSArray<KKTimingLane *> *fromJSON = [KKTimingLane lanesFromJSON:json];
      if (fromJSON.count)
        existing = fromJSON;
    }
  }
  if (!existing)
    existing = @[];
  NSArray<KKTimingLane *> *reconciled = [plugin reconcileLanes:existing
                                                        atTime:kCMTimeZero
                                                   paramGetAPI:getAPI];
  if (!reconciled) {
    [actAPI endAction:plugin];
    if (state && fingerprint)
      state.cachedReconcileFingerprint = fingerprint;
    return nil;
  }
  NSString *newJSON = [KKTimingLane jsonFromLanes:reconciled];
  NSString *existingJSON = [KKTimingLane jsonFromLanes:existing];
  BOOL changed = (newJSON && ![newJSON isEqualToString:existingJSON ?: @""]);
  if (changed)
    KKWriteMultiStageJSONDeduped(newJSON, setAPI, apiManager);
  [actAPI endAction:plugin];
  if (state && fingerprint)
    state.cachedReconcileFingerprint = fingerprint;
  return changed ? reconciled : nil;
}

static void KKSyncFromParams(id<PROAPIAccessing> apiManager, NSString *source) {
  KKPluginInstanceState *state = KKInstanceStateForAPI(apiManager);
  if (!state)
    return;
  KKStageSequencerView *seq = state.sequencerView;
  NSArray<KKTimingViewRefs *> *extras =
      [state.additionalTimingViews copy] ?: @[];
  double dur = KKCurrentEffectDurationSeconds(apiManager);

  // Early-exit when nothing the seq cares about has changed:
  //   1. The plugin's source-state fingerprint matches the last reconcile
  //      (so reconcile would no-op), AND
  //   2. The `lanesSnapshot` pointer matches the last one we pushed (so
  //      no in-memory edit — e.g. inspector value tweak from a plugin
  //      mutation site — has replaced the array since), AND
  //   3. No clip-duration drift.
  //
  // Pointer-equality on lanesSnapshot is required: the fingerprint only
  // captures *source* topology (path layerIDs / *Enabled flags for
  // Canvas), not lane values, easing curves, or segment durations. A
  // value tweak replaces lanesSnapshot via [copy] but leaves the
  // fingerprint unchanged — without the pointer check the live graph
  // update would be skipped until the user clicked something else.
  //
  // Compute fingerprint locally rather than reading a shared flag:
  // drawOSCTick runs off-main while the store observer runs on main,
  // and a shared flag would race (one thread overwriting the other's
  // NO/YES, causing a fresh-add to be misread as a fingerprint-skip
  // → seq push gets dropped → newly-added shape disappears from the
  // sequencer until the next event nudged things).
  NSString *currentFingerprint =
      [state.plugin kkReconcileFingerprintForAPI:apiManager];
  if (currentFingerprint && state.cachedReconcileFingerprint &&
      [currentFingerprint isEqualToString:state.cachedReconcileFingerprint] &&
      state.lanesSnapshot.count &&
      state.lanesSnapshot == state.lastPushedLanesSnapshot) {
    BOOL durDrift = NO;
    if (dur > 0) {
      for (KKTimingLane *lane in state.lanesSnapshot) {
        if (fabs(lane.lastKnownClipDuration - dur) > 1e-6) {
          durDrift = YES;
          break;
        }
      }
    }
    if (!durDrift)
      return;
  }

  NSArray<KKTimingLane *> *reconciledLanes =
      KKReconcileLanesIfNeeded(apiManager, state.plugin, source);
  NSArray<KKTimingLane *> *raw = nil;
  if (reconciledLanes) {
    // Reconcile changed something (e.g. Canvas user added a layer). Use the
    // returned lanes directly — re-reading the param here can return the
    // pre-write value and falsely trip jsonSame, leaving the seqView empty
    // until the next view rebuild.
    raw = reconciledLanes;
  } else {
    // Reconcile produced no new lanes — fingerprint matched, or it
    // early-bailed (no plugin / no actAPI). Do NOT fall back to a
    // `getStringParameterValue` read here: outside an action scope FCP
    // returns the pre-write value (CLAUDE.md FxPlug rule), which would
    // overwrite our fresh in-memory snapshot with stale or empty JSON
    // and erase newly-added shapes from the sequencer until the next
    // event refreshed things. The snapshot is the canonical mirror; it
    // is updated synchronously by every in-process mutation site
    // (writePaths, _modifyPaths, segment-edit handlers, etc.).
    //
    // The only legitimate reason to continue past this point is a
    // clip-duration change — re-rebalance the current snapshot for the
    // new duration and push it to seq. No FCP I/O.
    BOOL durDrift = NO;
    if (dur > 0) {
      for (KKTimingLane *lane in state.lanesSnapshot) {
        if (fabs(lane.lastKnownClipDuration - dur) > 1e-6) {
          durDrift = YES;
          break;
        }
      }
    }
    BOOL snapshotChanged =
        (state.lanesSnapshot != state.lastPushedLanesSnapshot);
    if ((!snapshotChanged && !durDrift) || state.lanesSnapshot.count == 0)
      return;
    raw = state.lanesSnapshot;
  }
  NSArray<KKTimingLane *> *lanes =
      (dur > 0) ? KKTimingRebalancedLanes(raw, dur) : raw;
  state.lanesSnapshot = lanes;
  state.lastPushedLanesSnapshot = lanes;
  state.pendingLanes = nil;
  // Use the cached plugin-hidden snapshot maintained by the
  // mode-change refresh path. Reverse-deriving it from the previous
  // `hiddenLaneLabels` raced with mode toggles — a freshly-hidden lane
  // wouldn't appear in the old set, so the pump would un-hide it
  // until the next refresh tick. Recompute the effective set fresh
  // against the live JSON so user-toggled visibility (undo/redo or
  // external edits) still applies.
  NSSet<NSString *> *pluginHidden = state.pluginHiddenLaneLabels ?: [NSSet set];
  state.hiddenLaneLabels = KKEffectiveHiddenLaneLabels(pluginHidden, lanes);
  KKPushLanesToVisibilityBar(state.visibilityBar, lanes, pluginHidden);
  KKApplyEmptyLanesVisibility(state.emptyLanesView, lanes, state.plugin);
  for (KKTimingViewRefs *r in extras) {
    KKPushLanesToVisibilityBar(r.visibilityBar, lanes, pluginHidden);
    KKApplyEmptyLanesVisibility(r.emptyLanesView, lanes, state.plugin);
  }
  if (!seq && extras.count == 0)
    return;
  NSArray<KKTimingLane *> *visible =
      KKFilterLanesForVisibility(lanes, state.hiddenLaneLabels);
  KKStageSequencerRulerView *primaryRuler = state.rulerView;
  dispatch_block_t apply = ^{
    if (dur > 0) {
      seq.effectDuration = dur;
      primaryRuler.effectDuration = dur;
    }
    seq.lanes = visible;
    for (KKTimingViewRefs *r in extras) {
      if (dur > 0) {
        r.seqView.effectDuration = dur;
        r.ruler.effectDuration = dur;
      }
      r.seqView.lanes = visible;
    }
  };
  // When the caller is already on main (store observer, custom-view
  // callbacks), apply synchronously — dispatch_async would push the seq
  // update to the back of the main queue, *behind* whatever FCP enqueues
  // on its parameterChanged callbacks. That gap is what makes the timing
  // sequencer feel like it lags the layer list (which updates inline).
  if (NSThread.isMainThread)
    apply();
  else
    dispatch_async(dispatch_get_main_queue(), apply);
}

/// Refresh the calling instance's cached effectStart/effectDuration. Cross-
/// instance `FxTimingAPI_v4` queries return nil (and wrapping in a fresh
/// `startAction:/endAction:` inside drawOSC recurses and crashes Motion), so
/// we can only refresh the instance whose callback is currently running.
/// Non-active instances use their cache populated at custom-UI creation time.
static void KKRefreshActiveTiming(id<PROAPIAccessing> apiManager) {
  id<FxTimingAPI_v4> timingAPI =
      [apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  if (!timingAPI)
    return;
  KKPluginInstanceState *activeState = KKInstanceStateForAPI(apiManager);
  if (!activeState)
    return;
  CMTime effectStart = kCMTimeZero, effectDuration = kCMTimeZero;
  CMTime frameDuration = kCMTimeZero;
  [timingAPI startTimeForEffect:&effectStart];
  [timingAPI durationTimeForEffect:&effectDuration];
  [timingAPI frameDuration:&frameDuration];
  activeState.cachedEffectStart = CMTimeGetSeconds(effectStart);
  activeState.cachedEffectDuration = CMTimeGetSeconds(effectDuration);
  activeState.cachedFrameDuration = CMTimeGetSeconds(frameDuration);
  CMTime srcStart = kCMTimeZero, tlStart = kCMTimeZero;
  [timingAPI startTimeOfInputToFilter:&srcStart];
  [timingAPI timelineTime:&tlStart fromInputTime:srcStart];
  activeState.cachedTimelineStart = CMTimeGetSeconds(tlStart);
}

/// Last time we fired a loop-back `movePlayheadToTime:` for the active
/// instance — gates re-triggers while FCP catches up to the new position.
static NSTimeInterval sLastLoopWrapTime = 0;

/// If the active instance has loop enabled and the playhead has reached the
/// end of the effect, jump it back to the effect start. Called from the
/// render tick where the caller's `apiManager` is live and can answer
/// `FxCommandAPI_v2` inside an action scope. The short cooldown avoids
/// spamming `movePlayheadToTime:` while FCP catches up to the new position.
static void KKMaybeLoopPlayback(id<PROAPIAccessing> apiManager,
                                double pumpTimeSec, id sender) {
  KKPluginInstanceState *state = KKInstanceStateForAPI(apiManager);
  double durSec = state.cachedEffectDuration;
  if (durSec <= 0)
    return;
  if (!state.loopEnabled || !sender)
    return;
  // FCP stops rendering roughly one frame before the effect end, so the
  // max observed frac varies with clip length (0.97 on a short clip, 0.99
  // on a long one) and with frame rate. Compare seconds-remaining to the
  // clip's native frame duration so we fire on the last rendered frame
  // at any frame rate. Fallback threshold for clips we haven't cached
  // timing for yet is 60ms (a frame at 16.7fps — permissive).
  double secondsRemaining = (state.cachedEffectStart + durSec) - pumpTimeSec;
  double triggerWindow =
      state.cachedFrameDuration > 0 ? state.cachedFrameDuration + 0.005 : 0.06;
  if (secondsRemaining > triggerWindow)
    return;
  NSTimeInterval now = CACurrentMediaTime();
  double frameDur =
      state.cachedFrameDuration > 0 ? state.cachedFrameDuration : 0.033;
  // Cooldown ~10 frames so subsequent render ticks during the buffered
  // tail don't stack up additional poll chains.
  if (now - sLastLoopWrapTime < 10.0 * frameDur)
    return;
  sLastLoopWrapTime = now;

  // During playback, the render callback runs 3–5 frames AHEAD of what the
  // user sees (FCP pre-renders for smooth playback). So when renderTime
  // reaches the effect end, the display is still 3–5 frames behind. We
  // poll `currentTime` on the main queue — which reports the actual
  // displayed playhead position, not the render-prep position — and fire
  // loop-back when it reaches the end. This is robust across machines,
  // since buffer depth varies with hardware/clip complexity, while
  // `currentTime` always reflects what the user is watching.
  double effectEndSec = state.cachedEffectStart + durSec;
  // `cachedEffectStart` comes from `startTimeForEffect:` and is in source
  // (clip-local) time, but `movePlayheadToTime:` interprets its argument as
  // timeline time. Seeking to the raw source value lands at timeline t=0
  // (or gets silently rejected when the clip doesn't start at t=0). Convert
  // through `timelineTime:fromInputTime:` — same pattern as the
  // sequencer-click seek in HandlersModifiers.m.
  // Seek target is in timeline time (what `movePlayheadToTime:` expects).
  // `cachedEffectStart` is source time and lands at timeline t=0 for any
  // clip not positioned at t=0. Use the timeline-time value cached during
  // custom-UI creation, when FxTimingAPI was reliable — it returns nil
  // here, in the render-tick context where the loop check fires. Half-
  // frame nudge keeps the playhead off the seam with the previous clip
  // (FCP resolves t==inPoint to the previous clip's last frame).
  // FCP and Motion report `effectStart` in different time spaces:
  //   - FCP: media-time of the input (e.g. 3601.7); the effect spans the
  //     whole clip, so loop-back-to-effect-start == loop-back-to-clip-start
  //     == `tlStart` (timeline-time of clip start).
  //   - Motion: timeline-time directly (e.g. 0.4667); the effect can begin
  //     partway through the clip, so we want `effectStart` as-is.
  // Pure math from the cached values can't distinguish these cases, so we
  // branch on the host.
  double seekStart = [KKHostInfo isRunningInFinalCut]
                         ? state.cachedTimelineStart
                         : state.cachedEffectStart;
  double targetSec = seekStart + frameDur * 0.5;
  id<PROAPIAccessing> strongAPI = apiManager;
  id strongSender = sender;
  __block NSInteger attemptsLeft = 20;
  __block __weak void (^weakPoll)(void);
  // The poll waits for the displayed `currentTime` to catch up to the clip
  // end before firing the seek — FCP pre-renders a few frames ahead, so
  // when the render-tick that triggered us hits end-of-clip, `currentTime`
  // is still a few frames behind. Don't bail out on individual no-advance
  // polls: FCP updates `currentTime` at roughly half the poll rate, so
  // every other poll naturally shows delta=0 even during smooth playback.
  // Just iterate until `atEnd` (good case) or attempts exhausted (give up).
  void (^poll)(void) = ^{
    id<FxCustomParameterActionAPI_v4> actAPI =
        [strongAPI apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    if (!actAPI)
      return;
    [actAPI startAction:strongSender];
    double nowSec = CMTimeGetSeconds([actAPI currentTime]);
    double secondsRemaining = effectEndSec - nowSec;
    BOOL atEnd = secondsRemaining <= frameDur + 0.005;

    if (atEnd) {
      id<FxCommandAPI_v2> cmd =
          [strongAPI apiForProtocol:@protocol(FxCommandAPI_v2)];
      [cmd performCommand:kFxCommand_TogglePlayback error:nil];
      CMTime target = CMTimeMakeWithSeconds(targetSec, 600);
      [cmd movePlayheadToTime:target error:nil];
      [cmd performCommand:kFxCommand_TogglePlayback error:nil];
      [actAPI endAction:strongSender];
      return;
    }
    [actAPI endAction:strongSender];

    if (--attemptsLeft <= 0)
      return;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(frameDur * NSEC_PER_SEC)),
        dispatch_get_main_queue(), weakPoll);
  };
  weakPoll = poll;
  dispatch_async(dispatch_get_main_queue(), poll);
}

/// Update the calling instance's playhead fraction from its cached timing
/// and dispatch view updates on the main queue. `nowSec` is the caller's
/// local `currentTime` (clip-relative), so it's only valid for the instance
/// that produced it — applying it to other instances would mix their clip
/// times, which is what caused stacked-clip scrubber bleed and the snap-to-
/// zero when the playhead crossed into the next clip. Each instance's own
/// render tick keeps its own view updated.
static void KKBroadcastPlayheads(id<PROAPIAccessing> apiManager,
                                 double nowSec) {
  KKPluginInstanceState *state = KKInstanceStateForAPI(apiManager);
  if (!state)
    return;
  KKStageSequencerView *seq = state.sequencerView;
  if (!seq && state.additionalTimingViews.count == 0)
    return;
  double durSec = state.cachedEffectDuration;
  if (durSec <= 0)
    return;
  double frac = (nowSec - state.cachedEffectStart) / durSec;
  if (fabs(frac - state.pendingPlayheadFraction) < 0.0001 &&
      fabs(durSec - state.pendingPlayheadDuration) < 0.001)
    return;

  state.pendingPlayheadFraction = frac;
  state.pendingPlayheadDuration = durSec;
  if (state.playheadDispatchPending)
    return;
  state.playheadDispatchPending = YES;
  KKStageSequencerRulerView *ruler = state.rulerView;
  KKStagePlayheadView *ph = state.playheadView;
  NSArray<KKTimingViewRefs *> *extras =
      [state.additionalTimingViews copy] ?: @[];
  dispatch_async(dispatch_get_main_queue(), ^{
    state.playheadDispatchPending = NO;
    seq.effectDuration = state.pendingPlayheadDuration;
    seq.playheadFraction = state.pendingPlayheadFraction;
    ruler.effectDuration = state.pendingPlayheadDuration;
    ph.playheadFraction = state.pendingPlayheadFraction;
    for (KKTimingViewRefs *r in extras) {
      r.seqView.effectDuration = state.pendingPlayheadDuration;
      r.seqView.playheadFraction = state.pendingPlayheadFraction;
      r.ruler.effectDuration = state.pendingPlayheadDuration;
      r.playhead.playheadFraction = state.pendingPlayheadFraction;
    }
  });
}

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKPlugin (MultiStagePump)

+ (void)multiStageDrawOSCTickForAPI:(id<PROAPIAccessing>)apiManager
                             atTime:(CMTime)time {
  KKFlushPendingLanes();
  // Cold-boot: snapshot may be empty because the canonical blob isn't
  // readable from OSC scope. The native-string mirror IS readable —
  // seed `lanesSnapshot` from it so every downstream consumer (OSC
  // visibility, bezier path, etc.) sees lane data on the first frame
  // after a project reload, not after the first user click.
  KKPluginInstanceState *state = KKInstanceStateForAPI(apiManager);
  if (state && state.lanesSnapshot.count == 0) {
    NSString *mirrored = KKReadMultiStageMirror(apiManager);
    if (mirrored.length) {
      NSArray<KKTimingLane *> *lanes = [KKTimingLane lanesFromJSON:mirrored];
      if (lanes.count)
        state.lanesSnapshot = lanes;
    }
  }
  KKSyncFromParams(apiManager, @"drawOSCTick");
  KKSyncLoopFromParams(apiManager);
  [self multiStageUpdatePlayheadsForAPI:apiManager atTime:time];
}

+ (BOOL)multiStageOSCVisibleForAPI:(id<PROAPIAccessing>)apiManager
                             label:(NSString *)label {
  return [self multiStageOSCVisibleForAPI:apiManager label:label groupKey:nil];
}

+ (BOOL)multiStageOSCVisibleForAPI:(id<PROAPIAccessing>)apiManager
                             label:(NSString *)label
                          groupKey:(NSString *)groupKey {
  KKPluginInstanceState *state = KKInstanceStateForAPI(apiManager);
  for (KKTimingLane *lane in state.lanesSnapshot) {
    if (![lane.propertyLabel isEqualToString:label])
      continue;
    if (groupKey.length && ![lane.groupKey isEqualToString:groupKey])
      continue;
    if (!lane.oscVisible)
      return NO;
    if (KKIsHTHTransition(lane, lane.selectedSegment))
      return NO;
    return YES;
  }
  return YES;
}

+ (void)multiStageRenderTickForAPI:(id<PROAPIAccessing>)apiManager
                            atTime:(CMTime)renderTime
                            sender:(id)sender {
  // `renderTime` is filter-input time (effect-local) whereas the pump expects
  // timeline time. Convert first, otherwise playhead fractions are wrong.
  CMTime pumpTime = renderTime;
  id<FxTimingAPI_v4> timingAPI =
      [apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  if (timingAPI)
    [timingAPI timelineTime:&pumpTime fromInputTime:renderTime];

  KKFlushPendingLanes();
  KKSyncLoopFromParams(apiManager);
  [self multiStageUpdatePlayheadsFromRenderForAPI:apiManager
                                           atTime:pumpTime
                                           sender:sender];
}

+ (void)multiStageFlushPendingLanes {
  KKFlushPendingLanes();
}

+ (void)multiStageSyncFromParams:(id<PROAPIAccessing>)apiManager {
  KKSyncFromParams(apiManager, @"public");
}

/// Force-refresh path for *external* changes to `kKKParamMultiStageData` —
/// notably host cmd-Z, which reverts the param outside any of our action
/// scopes. The pump's hot path short-circuits on a still-valid in-memory
/// snapshot and lastPushed pointer, both of which lag in this case (we
/// never wrote the post-undo state ourselves). Bust those caches and
/// re-read JSON straight from the param, then push to seq.
+ (void)multiStageRefreshFromParamForAPI:(id<PROAPIAccessing>)apiManager {
  if (!apiManager)
    return;
  KKPluginInstanceState *state = KKInstanceStateForAPI(apiManager);
  if (!state)
    return;

  // Distinguish "echo of our own write" from "real host cmd-Z" without
  // any I/O — every `setCustomParameterValue:` we make causes FCP to
  // fire `parameterChanged:` back to us, and we bump
  // `expectedMultiStageEchoCount` on every successful MS-WRITE. If the
  // count is > 0, this callback is consuming an echo (no suppression
  // needed). If it's 0, it's a host-driven revert and we engage
  // suppression IMMEDIATELY — synchronously, before the primary
  // KKReadCustomParamString below, because that read can yield to the
  // runloop and let a pending live-update block race in.
  if (state.expectedMultiStageEchoCount > 0) {
    state.expectedMultiStageEchoCount -= 1;
  } else {
    state.hostUndoSuppressionPending = YES;
    __weak KKPluginInstanceState *weakState = state;
    // Hold suppression for ~100ms — long enough to cover any deferred
    // live-update blocks queued before this MS-REFRESH ran (including
    // the 16ms-delayed ones in plugin handlers) plus a margin for the
    // host's full revert burst. Drags don't trigger this path — echo
    // counter skips it.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 100 * NSEC_PER_MSEC),
                   dispatch_get_main_queue(), ^{
                     weakState.hostUndoSuppressionPending = NO;
                   });
  }
  id<FxParameterRetrievalAPI_v6> getAPI =
      [apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!getAPI)
    return;

  NSString *json = KKReadCustomParamString(getAPI, kKKParamMultiStageData);
  // Empty reads happen mid-undo (host briefly returns the param's default
  // before propagating the reverted value) and as XPC scope artefacts.
  // A non-empty in-memory snapshot is sufficient evidence we had real
  // data — don't blank the sequencer; wait for the next refresh with
  // real content. The host will fire another parameterChanged for
  // kKKParamMultiStageData when the actual reverted JSON arrives.
  if (!json.length && state.lanesSnapshot.count > 0)
    return;
  NSArray<KKTimingLane *> *parsed =
      json.length ? [KKTimingLane lanesFromJSON:json] : @[];
  if (!parsed)
    parsed = @[];

  double dur = KKCurrentEffectDurationSeconds(apiManager);
  NSArray<KKTimingLane *> *lanes =
      (dur > 0) ? KKTimingRebalancedLanes(parsed, dur) : parsed;

  state.lanesSnapshot = lanes;
  state.lastPushedLanesSnapshot = lanes;
  state.pendingLanes = nil;
  state.cachedReconcileFingerprint = nil;
  state.lastWrittenMultiStageJSON = KKMultiStageNormalizedForDedup(json);

  // The blob just got reverted by the host (cmd-Z); the native-string
  // mirror is NOT on the undo stack so it's now stale. Refresh it from
  // the reverted JSON so the next cold-boot OSC tick reads the correct
  // post-undo state.
  id<FxParameterSettingAPI_v5> mirrorSetAPI =
      [apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (mirrorSetAPI)
    KKWriteMultiStageMirror(json ?: @"", mirrorSetAPI);

  // Recompute the effective hidden set fresh against the reverted JSON
  // so user-toggled visibility pills (which the host stored in lane
  // `visibleInSequencer`) actually re-apply on undo. Without this the
  // pills stay at the post-toggle visual state until something else
  // forces a full re-push.
  NSSet<NSString *> *pluginHidden = state.pluginHiddenLaneLabels ?: [NSSet set];
  state.hiddenLaneLabels = KKEffectiveHiddenLaneLabels(pluginHidden, lanes);

  KKStageSequencerView *seq = state.sequencerView;
  NSArray<KKTimingViewRefs *> *extras =
      [state.additionalTimingViews copy] ?: @[];
  KKStageSequencerRulerView *primaryRuler = state.rulerView;
  NSArray<KKTimingLane *> *visible =
      KKFilterLanesForVisibility(lanes, state.hiddenLaneLabels);
  dispatch_block_t apply = ^{
    if (dur > 0) {
      seq.effectDuration = dur;
      primaryRuler.effectDuration = dur;
      for (KKTimingViewRefs *r in extras) {
        r.seqView.effectDuration = dur;
        r.ruler.effectDuration = dur;
      }
    }
    seq.lanes = visible;
    KKPushLanesToVisibilityBar(state.visibilityBar, lanes, pluginHidden);
    KKApplyEmptyLanesVisibility(state.emptyLanesView, lanes, state.plugin);
    for (KKTimingViewRefs *r in extras) {
      r.seqView.lanes = visible;
      KKPushLanesToVisibilityBar(r.visibilityBar, lanes, pluginHidden);
      KKApplyEmptyLanesVisibility(r.emptyLanesView, lanes, state.plugin);
    }
    KKPlugin *owner = state.plugin;
    if (owner.segmentEditPopover.shown && owner.segmentEditPopoverRefresh)
      owner.segmentEditPopoverRefresh(lanes);
  };
  KKRunOnMain(apply);
}

+ (void)multiStageRefreshLoopFromParamForAPI:(id<PROAPIAccessing>)apiManager {
  KKSyncLoopFromParams(apiManager);
}

+ (void)multiStageUpdatePlayheadsForAPI:(id<PROAPIAccessing>)apiManager
                                 atTime:(CMTime)time {
  // Only mark drawOSC as "authoritative" (which suppresses the render-pump
  // broadcast) when its apiManager actually resolves to instance state — in
  // Motion the drawOSC apiManager's UUID context doesn't match our per-
  // instance state, so its broadcast is a no-op. Without this guard, the
  // render pump (which DOES have valid state) would be perpetually blocked
  // by the suppression gate and the in-plugin scrubber would freeze during
  // playback. FCP's drawOSC apiManager resolves correctly and keeps gating.
  if (KKInstanceStateForAPI(apiManager))
    sLastDrawOSCPumpTime = CACurrentMediaTime();
  KKRefreshActiveTiming(apiManager);
  KKBroadcastPlayheads(apiManager, CMTimeGetSeconds(time));
}

+ (void)multiStageUpdatePlayheadsFromRenderForAPI:
            (id<PROAPIAccessing>)apiManager
                                           atTime:(CMTime)time
                                           sender:(id)sender {
  // Loop-back runs regardless of the view-broadcast suppression gates: those
  // gates protect against playhead flicker, while the loop check needs to
  // fire during playback even when drawOSC is authoritative for view updates.
  KKRefreshActiveTiming(apiManager);
  KKMaybeLoopPlayback(apiManager, CMTimeGetSeconds(time), sender);

  // drawOSC is authoritative when running; recent parameterChanged means
  // warm-up renders are imminent. Either gate closed → skip the broadcast
  // to avoid flickering the playhead to frame 0.
  NSTimeInterval now = CACurrentMediaTime();
  if (now - sLastDrawOSCPumpTime < kRenderSuppressionWindow)
    return;
  if (now - sLastParameterChangedTime < kRenderSuppressionWindow)
    return;

  // `time` here is renderTime → timelineTime, which during playback runs 3–5
  // frames ahead of the displayed playhead (FCP pre-renders for smooth
  // playback). Hop to main and read `currentTime` via the action API, which
  // reports the actually-displayed position. Coalescing in KKBroadcastPlayheads
  // absorbs the 3–5 redundant render ticks per displayed frame.
  //
  // Exception: once `pumpTime` reaches the clip end, render stops firing —
  // but `currentTime` is still 3–5 frames behind at that moment, so the last
  // broadcast lands short of the visual end. Commit to the clip end directly,
  // since no further ticks will arrive to catch up.
  KKPluginInstanceState *endState = KKInstanceStateForAPI(apiManager);
  double endDur = endState.cachedEffectDuration;
  if (endDur > 0) {
    double clipEnd = endState.cachedEffectStart + endDur;
    double frameDur =
        endState.cachedFrameDuration > 0 ? endState.cachedFrameDuration : 0.033;
    if (CMTimeGetSeconds(time) >= clipEnd - frameDur * 0.5) {
      KKBroadcastPlayheads(apiManager, clipEnd);
      return;
    }
  }
  id strongSender = sender;
  __weak id<PROAPIAccessing> weakAPI = apiManager;
  dispatch_async(dispatch_get_main_queue(), ^{
    id<PROAPIAccessing> strongAPI = weakAPI;
    if (!strongAPI)
      return;
    id<FxCustomParameterActionAPI_v4> actAPI =
        [strongAPI apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    if (!actAPI)
      return;
    [actAPI startAction:strongSender];
    double nowSec = CMTimeGetSeconds([actAPI currentTime]);
    // FxTimingAPI is nil in render context but resolves inside this action
    // scope. Trim/slip changes to the clip never reach drawOSC unless the
    // plugin is OSC-focused, so render-tick is the only callback we see —
    // refresh the duration cache and rebalance lanes here.
    id<FxTimingAPI_v4> tAPI =
        [strongAPI apiForProtocol:@protocol(FxTimingAPI_v4)];
    KKPluginInstanceState *st = KKInstanceStateForAPI(strongAPI);
    if (tAPI && st) {
      CMTime d = kCMTimeZero;
      [tAPI durationTimeForEffect:&d];
      double newDur = CMTimeGetSeconds(d);
      if (newDur > 0 && fabs(newDur - st.cachedEffectDuration) > 0.001) {
        st.cachedEffectDuration = newDur;
        NSArray<KKTimingLane *> *raw = st.lanesSnapshot;
        if (raw.count) {
          NSArray<KKTimingLane *> *lanes = KKTimingRebalancedLanes(raw, newDur);
          st.lanesSnapshot = lanes;
          st.lastPushedLanesSnapshot = lanes;
          NSArray<KKTimingLane *> *visible =
              KKFilterLanesForVisibility(lanes, st.hiddenLaneLabels);
          KKStageSequencerView *seq = st.sequencerView;
          KKStageSequencerRulerView *ruler = st.rulerView;
          NSArray<KKTimingViewRefs *> *extras =
              [st.additionalTimingViews copy] ?: @[];
          seq.effectDuration = newDur;
          ruler.effectDuration = newDur;
          seq.lanes = visible;
          for (KKTimingViewRefs *r in extras) {
            r.seqView.effectDuration = newDur;
            r.ruler.effectDuration = newDur;
            r.seqView.lanes = visible;
          }
        }
      }
    }
    [actAPI endAction:strongSender];
    KKBroadcastPlayheads(strongAPI, nowSec);
  });
}

@end
