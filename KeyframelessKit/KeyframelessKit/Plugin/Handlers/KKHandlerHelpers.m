/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKDataBlob.h"
#import "KKPluginInstanceState.h"
#import "KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKConstants.h>
#import <KeyframelessKit/KKTimingStage.h>

/// Returns a canonical form of `json` for dedup comparison - sorted keys
/// so two semantically-equal JSONs that differ only in field order
/// compare equal. Selection (`sel`) is **not** stripped: each segment
/// click writes a real undo entry through the host (typical document-
/// editor behavior - cmd-Z bounces through selection history along with
/// structural edits).
NSString *KKMultiStageNormalizedForDedup(NSString *json) {
  if (!json.length)
    return json;
  NSData *data = [json dataUsingEncoding:NSUTF8StringEncoding];
  id parsed = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  if (!parsed)
    return json;
  NSData *out = [NSJSONSerialization dataWithJSONObject:parsed
                                                options:NSJSONWritingSortedKeys
                                                  error:nil];
  return out ? [[NSString alloc] initWithData:out encoding:NSUTF8StringEncoding]
             : json;
}

/// Native-string mirror of the lanes JSON. Written in lockstep with
/// every blob write; read by the OSC's drawTick on cold-boot to seed
/// the snapshot before consumers (oscVisible, bezier path, etc.) run.
/// The blob remains the canonical undoable store - this is a write-
/// through cache, not a separate source of truth.
void KKWriteMultiStageMirror(NSString *json,
                             id<FxParameterSettingAPI_v5> setAPI) {
  if (!setAPI)
    return;
  [setAPI setStringParameterValue:json ?: @""
                      toParameter:kKKParamMultiStageDataMirror];
}

NSString *KKReadMultiStageMirror(id<PROAPIAccessing> apiManager) {
  if (!apiManager)
    return nil;
  id<FxParameterRetrievalAPI_v6> getAPI =
      [apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!getAPI)
    return nil;
  NSString *value = nil;
  [getAPI getStringParameterValue:&value
                    fromParameter:kKKParamMultiStageDataMirror];
  return value;
}

BOOL KKWriteMultiStageJSONDeduped(NSString *json,
                                  id<FxParameterSettingAPI_v5> setAPI,
                                  id<PROAPIAccessing> apiManager) {
  if (!setAPI || !json)
    return NO;
  KKPluginInstanceState *state =
      apiManager ? KKInstanceStateForAPI(apiManager) : nil;
  // While the host is reverting params for a cmd-Z, suppress all writes -
  // every write here registers a fresh undo entry, which immediately
  // overwrites the host's revert and fragments one logical undo into N.
  // Flag is set by `multiStageRefreshFromParamForAPI:` and cleared after
  // ~100ms (long enough to cover the full revert burst plus any deferred
  // live-update blocks queued before MS-REFRESH ran).
  if (state.hostUndoSuppressionPending)
    return NO;
  NSString *normalized = KKMultiStageNormalizedForDedup(json);
  if (state && [state.lastWrittenMultiStageJSON isEqualToString:normalized])
    return NO;
  KKWriteCustomParamString(setAPI, json, kKKParamMultiStageData);
  // Mirror the same JSON to a native string param so OSC scope can
  // read it on cold-boot (the blob is unreadable there).
  KKWriteMultiStageMirror(json, setAPI);
  if (state) {
    state.lastWrittenMultiStageJSON = normalized;
    // Every successful write triggers exactly one parameterChanged echo
    // from the host. Bumping this counter lets MS-REFRESH classify its
    // next callback as an echo without any I/O - see the consume-side
    // logic in `multiStageRefreshFromParamForAPI:`.
    state.expectedMultiStageEchoCount += 1;
  }
  return YES;
}

void KKRunOnMain(dispatch_block_t block) {
  if (!block)
    return;
  if (NSThread.isMainThread)
    block();
  else
    dispatch_async(dispatch_get_main_queue(), block);
}

BOOL KKBeginUndoGroup(id<PROAPIAccessing> apiManager, NSString *name) {
  id<FxUndoAPI> undoAPI =
      apiManager ? [apiManager apiForProtocol:@protocol(FxUndoAPI)] : nil;
  return undoAPI && [undoAPI startUndoGroup:name ?: @""];
}

void KKEndUndoGroup(id<PROAPIAccessing> apiManager, BOOL started) {
  if (!started)
    return;
  id<FxUndoAPI> undoAPI =
      apiManager ? [apiManager apiForProtocol:@protocol(FxUndoAPI)] : nil;
  [undoAPI endUndoGroup];
}

void KKWithUndoGroup(id<PROAPIAccessing> apiManager, NSString *name,
                     dispatch_block_t block) {
  if (!block)
    return;
  BOOL started = KKBeginUndoGroup(apiManager, name);
  @try {
    block();
  } @finally {
    KKEndUndoGroup(apiManager, started);
  }
}

NSMutableArray<KKTimingLane *> *
KKReadLanesRebalanced(id<PROAPIAccessing> __unused apiManager,
                      id<FxParameterRetrievalAPI_v6> __unused getAPI) {
  return nil;
}

NSInteger KKLaneJSONIndexForViewIndex(NSInteger viewIndex,
                                      NSArray<KKTimingLane *> *jsonLanes,
                                      NSSet<NSString *> *hidden) {
  NSInteger visible = 0;
  for (NSInteger i = 0; i < (NSInteger)jsonLanes.count; i++) {
    KKTimingLane *lane = jsonLanes[i];
    if (hidden && [hidden containsObject:lane.propertyLabel])
      continue;
    if (visible == viewIndex)
      return i;
    visible++;
  }
  return -1;
}

void KKWriteLanesJSON(NSArray<KKTimingLane *> *lanes,
                      id<FxParameterSettingAPI_v5> setAPI,
                      id<PROAPIAccessing> apiManager) {
  NSMutableArray<KKTimingLane *> *mutableLanes = [lanes mutableCopy];
  KKApplyHTHNormalizationInPlace(mutableLanes);
  NSString *updated = [KKTimingLane jsonFromLanes:mutableLanes];
  if (updated)
    KKWriteMultiStageJSONDeduped(updated, setAPI, apiManager);
  if (apiManager) {
    KKPluginInstanceState *state = KKInstanceStateForAPI(apiManager);
    if (state) {
      state.lanesSnapshot = [mutableLanes copy];
      state.lanesEverPersisted = YES;
    }
  }
}
