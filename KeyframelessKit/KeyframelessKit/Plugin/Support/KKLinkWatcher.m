/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLinkWatcher.h"

#import "KKDataBlob.h" // KKWriteCustomParamString
#import "KKLinkBus.h"  // changeStampForLink
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
    return;
  }
  // Fire one re-render once the source has been stable for the debounce window.
  if (_pendingChange && (now - _lastChangeWall) >= 0.15) {
    _pendingChange = NO;
    [self _nudge];
  }
}

// Force FCP to re-render this clip: a fresh nonce to the hidden render-nudge
// scratch param inside an action scope. Debounced by -_tick:, so at most one
// undo entry per source edit-burst.
- (void)_nudge {
  id<PROAPIAccessing> mgr = _apiManager;
  NSObject *target = _actionTarget;
  if (!mgr || !target)
    return;
  id<FxCustomParameterActionAPI_v4> act =
      [mgr apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!act)
    return;
  [act startAction:target];
  id<FxParameterSettingAPI_v5> setAPI =
      [mgr apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  KKWriteCustomParamString(setAPI, [[NSUUID UUID] UUIDString], _nudgeParamID);
  [act endAction:target];
}

@end
