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
