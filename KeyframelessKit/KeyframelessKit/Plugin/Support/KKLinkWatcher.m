/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLinkWatcher.h"

#import "KKLinkBus.h" // changeStampForLink
#import "KKLocalized.h"
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
  // A nudge burst (throttled fires during a live source drag + the settle
  // fire) is wrapped in ONE FxUndoAPI undo group so the per-write undo
  // entries the host insists on (no param flag exempts a write - tested:
  // plain, DONT_SAVE, DISABLED) coalesce into a single entry.
  id<FxUndoAPI> _burstUndoAPI; // non-nil while a burst group is open
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
  if (_burstUndoAPI)
    [_burstUndoAPI endUndoGroup];
}

- (void)invalidate {
  [_timer invalidate];
  _timer = nil;
  [_stamps removeAllObjects];
  _pendingChange = NO;
  [self _closeBurstUndoGroup];
}

// Called INSIDE the nudge's action scope: FxUndoAPI resolves nil outside one
// (same as the setting API - observed in the XPC).
- (void)_openBurstUndoGroupScoped:(id<PROAPIAccessing>)mgr {
  if (_burstUndoAPI)
    return;
  id<FxUndoAPI> undo = [mgr apiForProtocol:@protocol(FxUndoAPI)];
  if (!undo) {
    KKLogWarn(@"KKLinkWatcher[%@]: FxUndoAPI nil even in-scope - not grouped",
              [NSProcessInfo processInfo].processName);
    return;
  }
  if ([undo startUndoGroup:KKLoc(@"Update Link", @"Undo menu name for a "
                                 @"linked-parameter refresh")])
    _burstUndoAPI = undo;
}

- (void)_closeBurstUndoGroup {
  if (!_burstUndoAPI)
    return;
  [_burstUndoAPI endUndoGroup];
  _burstUndoAPI = nil;
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
    // until it settles. Every honored write charges an undo entry, so the
    // whole burst rides one FxUndoAPI group (opened here on the first fire,
    // closed by the settle fire) and coalesces into a single entry.
    if (now - _lastFireWall >= 0.25) {
      _lastFireWall = now;
      [self _nudgeClosingGroup:NO];
    }
    return;
  }
  // Fire one final re-render once the source has been stable for the debounce
  // window, so the subscriber lands exactly on the settled value.
  if (_pendingChange && (now - _lastChangeWall) >= 0.15) {
    _pendingChange = NO;
    _lastFireWall = now;
    [self _nudgeClosingGroup:YES];
  }
}

// Force FCP to re-render this clip: a fresh nonce to the hidden render-nudge
// scratch param inside an action scope. The write MUST ride an action scope -
// the host silently ignores setting-API writes outside one (observed in both
// plugins' XPC) - and EVERY honored write charges one undo entry regardless
// of param type or flags (tested: string vs blob, DONT_SAVE, DISABLED).
// That's why the burst-level FxUndoAPI group exists: it coalesces the fires
// of one source edit into a single entry. The group is opened inside the
// burst's FIRST action scope and closed inside its LAST (the settle fire) -
// FxUndoAPI, like the setting API, resolves nil outside a scope.
- (void)_nudgeClosingGroup:(BOOL)closeGroup {
  id<PROAPIAccessing> mgr = _apiManager;
  NSObject *target = _actionTarget;
  if (!mgr || !target)
    return;
  id<FxCustomParameterActionAPI_v4> act =
      [mgr apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!act) {
    KKLogWarn(@"KKLinkWatcher[%@]: action API unavailable - nudge dropped",
              [NSProcessInfo processInfo].processName);
    return;
  }
  [act startAction:target];
  [self _openBurstUndoGroupScoped:mgr];
  id<FxParameterSettingAPI_v5> setAPI =
      [mgr apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  [setAPI setStringParameterValue:[[NSUUID UUID] UUIDString]
                      toParameter:_nudgeParamID];
  if (closeGroup)
    [self _closeBurstUndoGroup];
  [act endAction:target];
}

@end
