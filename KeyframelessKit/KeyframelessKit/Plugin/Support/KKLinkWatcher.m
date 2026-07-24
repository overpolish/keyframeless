/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLinkWatcher.h"

#import "KKLinkBus.h" // changeStampForLink
#import "KKLog.h"
#import <FxPlug/FxPlugSDK.h>

@interface KKLinkWatcher () {
  __weak id<PROAPIAccessing> _apiManager;
  __weak NSObject *_actionTarget;
  uint32_t _nudgeParamID;
  NSTimer *_timer;
  NSMutableDictionary<NSString *, NSNumber *> *_stamps; // name -> last stamp
  BOOL _pendingChange;
  NSTimeInterval _lastChangeWall;
  NSTimeInterval _lastFireWall;
}
@end

@implementation KKLinkWatcher

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                      actionTarget:(NSObject *)actionTarget
                      nudgeParamID:(uint32_t)nudgeParamID {
  if ((self = [super init])) {
    _apiManager = apiManager;
    _actionTarget = actionTarget;
    _nudgeParamID = nudgeParamID;
    _stamps = [NSMutableDictionary dictionary];
  }
  return self;
}

- (void)dealloc {
  [_timer invalidate];
}

- (void)invalidate {
  [_timer invalidate];
  _timer = nil;
  [_stamps removeAllObjects];
  _pendingChange = NO;
}

- (void)setSourceNames:(NSSet<NSString *> *)names {
  if (names.count == 0) {
    [self invalidate];
    return;
  }
  // Drop stamps for names no longer watched; seed new names with their CURRENT
  // stamp so the first observation doesn't count as a change (no spurious
  // nudge).
  for (NSString *gone in _stamps.allKeys)
    if (![names containsObject:gone])
      [_stamps removeObjectForKey:gone];
  for (NSString *n in names)
    if (!_stamps[n])
      _stamps[n] = @([KKLinkBus changeStampForLink:n]);
  if (!_timer) {
    _timer = [NSTimer scheduledTimerWithTimeInterval:0.08
                                              target:self
                                            selector:@selector(_tick:)
                                            userInfo:nil
                                             repeats:YES];
  }
}

- (void)_tick:(NSTimer *)timer {
  BOOL changed = NO;
  for (NSString *n in _stamps.allKeys) {
    long long cur = [KKLinkBus changeStampForLink:n];
    if (cur != _stamps[n].longLongValue) {
      _stamps[n] = @(cur);
      changed = YES;
    }
  }
  NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
  if (changed) {
    _pendingChange = YES;
    _lastChangeWall = now; // keep resetting while a drag is live
    // Sustained change (a live drag on the source): fire a THROTTLED nudge
    // (at most ~4/s) so the subscriber TRACKS the drag instead of freezing
    // until it settles. FCP coalesces the repeated same-target nudge writes
    // into one implicit undo entry (same-target writes with no group
    // boundary between them), so this doesn't spam the undo stack.
    if (now - _lastFireWall >= 0.25) {
      _lastFireWall = now;
      [self _nudge];
    }
    return;
  }
  // Fire one final re-render once the source has been stable for the debounce
  // window, so the subscriber lands exactly on the settled value.
  if (_pendingChange && (now - _lastChangeWall) >= 0.15) {
    _pendingChange = NO;
    _lastFireWall = now;
    [self _nudge];
  }
}

// Force FCP to re-render this clip: a fresh nonce to the hidden render-nudge
// scratch param inside an action scope. A STRING write, because string writes
// are the one param write FCP keeps off the undo stack - the watcher fires
// autonomously, so an undoable (blob) nudge stacked stray entries around
// every source edit and re-armed itself when the user hit undo (the revert
// republishes the curves, the stamp changes, and a fresh nudge lands on the
// stack being unwound). `_nudgeParamID` must therefore be a string param
// (kKKParamRenderNudgeString).
- (void)_nudge {
  id<PROAPIAccessing> mgr = _apiManager;
  NSObject *target = _actionTarget;
  if (!mgr || !target)
    return;
  // NO action scope around this write. startAction/endAction is FCP's
  // FFUIAction beginWithUndoState - the ACTION registers an undo entry even
  // when nothing undoable is written inside it (the audio-tickets string
  // write skips undo, but it rides inside an action a lane edit opened
  // anyway). A scoped nudge therefore stacked one stray undo entry per fire,
  // and worse: undoing the source edit republished the curves, re-fired the
  // watcher, and pushed a fresh entry onto the stack being unwound. The
  // string write alone re-renders without touching undo - IF the setting API
  // resolves outside a scope in this (XPC main-thread timer) context; the log
  // says which case we're in.
  id<FxParameterSettingAPI_v5> setAPI =
      [mgr apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  if (!setAPI) {
    // Canary: if a host update stops resolving the setting API outside action
    // scopes, cross-clip updates go stale and this says why. Only logs in the
    // broken state.
    KKLogWarn(@"KKLinkWatcher[%@]: setting API nil outside action scope - "
              @"nudge dropped",
              [NSProcessInfo processInfo].processName);
    return;
  }
  [setAPI setStringParameterValue:[[NSUUID UUID] UUIDString]
                      toParameter:_nudgeParamID];
}

@end
