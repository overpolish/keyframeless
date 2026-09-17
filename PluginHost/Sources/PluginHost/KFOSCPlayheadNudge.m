/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFOSCPlayheadNudge.h"
#import "KFHostSettings.h"
@import OSCViewer;

@implementation KFOSCPlayheadNudge {
  __weak id<PROAPIAccessing> _manager;
  NSArray<NSNumber *> *_visibilityParameters;
  // The same fold the control runs on its draw ticks, so both processes agree
  // on what counts as a moving playhead and on when it has settled.
  OSCPlayheadMotion _motion;
  BOOL _pending;
}

- (instancetype)initWithManager:(id<PROAPIAccessing>)manager
           visibilityParameters:(NSArray<NSNumber *> *)visibilityParameters {
  if ((self = [super init])) {
    _manager = manager;
    _visibilityParameters = [visibilityParameters copy];
  }
  return self;
}

- (void)tickInAction:(id<FxCustomParameterActionAPI_v4>)action {
  (void)[self tickInAction:action wall:NSProcessInfo.processInfo.systemUptime];
}

- (BOOL)tickInAction:(id<FxCustomParameterActionAPI_v4>)action wall:(NSTimeInterval)wall {
  if (!action) return NO;
  CMTime now = [action currentTime];
  if (!CMTIME_IS_NUMERIC(now)) return NO;
  if (OSCPlayheadMotionUpdate(&_motion, CMTimeGetSeconds(now), wall)) {
    // Moving: the control is hiding itself, so a redraw is owed once it stops.
    _pending = YES;
    return NO;
  }
  if (!_pending) return NO;
  _pending = NO;
  return [self writeNonceAtTime:now];
}

// Only nudge when a control would actually appear: with every toggle off the
// redraw would change nothing and the undo entry would be pure noise.
- (BOOL)anyControlVisibleAtTime:(CMTime)time {
  id<FxParameterRetrievalAPI_v6> get = [_manager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!get) return NO;
  for (NSNumber *toggle in _visibilityParameters) {
    BOOL visible = NO;
    if ([get getBoolValue:&visible fromParameter:toggle.unsignedIntValue atTime:time] && visible) return YES;
  }
  return NO;
}

- (BOOL)writeNonceAtTime:(CMTime)time {
  if (![self anyControlVisibleAtTime:time]) return NO;
  id<FxUndoAPI> undo = [_manager apiForProtocol:@protocol(FxUndoAPI)];
  BOOL grouped = [undo startUndoGroup:@"Show On-Screen Controls"];
  @try {
    return KFRequestHostRefresh(_manager, time);
  } @finally {
    if (grouped) [undo endUndoGroup];
  }
}
@end
