/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "../KKDataBlob.h"
#import "../KKPluginInstanceState.h"
#import "../KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKConstants.h>
#import <KeyframelessKit/KKTimingStage.h>

/// Returns a canonical form of `json` for dedup comparison — sorted keys
/// so two semantically-equal JSONs that differ only in field order
/// compare equal. Selection (`sel`) is **not** stripped: each segment
/// click writes a real undo entry through the host (typical document-
/// editor behavior — cmd-Z bounces through selection history along with
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

BOOL KKWriteMultiStageJSONDeduped(NSString *json,
                                  id<FxParameterSettingAPI_v5> setAPI,
                                  id<PROAPIAccessing> apiManager) {
  if (!setAPI || !json)
    return NO;
  KKPluginInstanceState *state =
      apiManager ? KKInstanceStateForAPI(apiManager) : nil;
  NSString *normalized = KKMultiStageNormalizedForDedup(json);
  if (state && [state.lastWrittenMultiStageJSON isEqualToString:normalized])
    return NO;
  KKWriteCustomParamString(setAPI, json, kKKParamMultiStageData);
  if (state)
    state.lastWrittenMultiStageJSON = normalized;
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
