/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKDataBlob.h"
#import "KKPluginInstanceState.h"
#import "KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <KeyframelessKit/KKConstants.h>
#import <KeyframelessKit/KKTimeline.h>

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

/// Bracket a MULTI-WRITE mutation in one host undo group where each write
/// inside `block` manages its OWN action scope (e.g. _modifyPaths-style blob
/// writes followed by a selection write). The group begin and end each get a
/// brief scope of their own - holding one scope across the block would NEST
/// the writes' scopes, which asserts FFUIAction in the host. Complement to
/// KKPerformUndoable (which holds a single scope around scope-less work).
void KKWithHostUndoGroup(id<PROAPIAccessing> apiManager, id principal,
                         NSString *name, void (^block)(void)) {
  if (!block)
    return;
  id<FxCustomParameterActionAPI_v4> act =
      apiManager
          ? [apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)]
          : nil;
  BOOL undoGroup = NO;
  if (act) {
    [act startAction:principal];
    undoGroup = KKBeginUndoGroup(apiManager, name);
    [act endAction:principal];
  }
  @try {
    block();
  } @finally {
    if (act) {
      [act startAction:principal];
      KKEndUndoGroup(apiManager, undoGroup);
      [act endAction:principal];
    }
  }
}

BOOL KKPerformUndoable(id<PROAPIAccessing> apiManager, id principal,
                       NSString *name,
                       void (^block)(id<FxParameterRetrievalAPI_v6> getAPI,
                                     id<FxParameterSettingAPI_v5> setAPI,
                                     CMTime actionTime)) {
  if (!block)
    return NO;
  id<FxCustomParameterActionAPI_v4> act =
      apiManager
          ? [apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)]
          : nil;
  if (!act)
    return NO;
  [act startAction:principal];
  BOOL started = name != nil && KKBeginUndoGroup(apiManager, name);
  @try {
    id<FxParameterRetrievalAPI_v6> getAPI =
        [apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> setAPI =
        [apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    block(getAPI, setAPI, [act currentTime]);
  } @finally {
    // Close in @finally: an early return is fine (blocks can't early-return
    // past this), but an exception escaping an open scope wedges FCP's undo
    // machinery (its next beginWithUndoState aborts).
    KKEndUndoGroup(apiManager, started);
    [act endAction:principal];
  }
  return YES;
}
