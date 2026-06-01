/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPlayheadPoller.h"
#import "../Views/KKTimelineInspectorView.h"
#import "KKHostInfo.h"
#import "KKPluginHost.h"
#import <FxPlug/FxPlugSDK.h>

@interface KKPlayheadPoller () {
  __weak id<PROAPIAccessing> _apiManager;
  __weak NSObject *_actionTarget;
  __weak KKTimelineInspectorView *_inspectorView;
  KKRenderCache *_cache;
  NSTimer *_timer;
  double _pollLast;
  NSInteger _pollStall;
  NSTimeInterval _lastMoveWall; // wall-clock of the last currentTime change
  double _lastPushedPlayheadFrac;
  BOOL _lastPushedPlaying;
  NSTimeInterval _lastLoopWrapTime;
}
@end

@implementation KKPlayheadPoller

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                      actionTarget:(NSObject *)actionTarget
                       renderCache:(KKRenderCache *)renderCache {
  if ((self = [super init])) {
    _apiManager = apiManager;
    _actionTarget = actionTarget;
    _cache = renderCache;
    _lastPushedPlayheadFrac = -1.0;
    _lastPushedPlaying = NO;
  }
  return self;
}

- (void)setInspectorView:(KKTimelineInspectorView *)inspectorView {
  _inspectorView = inspectorView;
  // The new view starts at the hidden sentinel (-1.0); reset our cached
  // last-pushed fraction so the next tick re-delivers the current value
  // even if it matches what we pushed to the *previous* view. Without
  // this, "select a different clip then come back" (or rebooting FCP)
  // leaves the scrubber invisible until the user nudges the playhead.
  _lastPushedPlayheadFrac = -1.0;
  _lastPushedPlaying = NO;
}

- (void)dealloc {
  [_timer invalidate];
}

- (void)ensureRunning {
  if (_timer)
    return;
  double frameDur =
      _cache.frameDurSec > 0.0 ? _cache.frameDurSec : (1.0 / 60.0);
  _pollLast = -999.0;
  _pollStall = 0;
  _timer = [NSTimer scheduledTimerWithTimeInterval:frameDur
                                            target:self
                                          selector:@selector(_tick:)
                                          userInfo:nil
                                           repeats:YES];
}

- (void)invalidate {
  [_timer invalidate];
  _timer = nil;
}

- (void)_tick:(NSTimer *)timer {
  id<FxCustomParameterActionAPI_v4> act =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  NSObject *actTarget = _actionTarget;
  KKTimelineInspectorView *iv = _inspectorView;
  if (!act || !actTarget) {
    [self invalidate];
    return;
  }
  [act startAction:actTarget];
  double curSec = CMTimeGetSeconds([act currentTime]);
  [act endAction:actTarget];

  double es = _cache.effectStartSec, ed = _cache.effectDurSec;
  if (ed <= 0.0) {
    // No timing yet (cold clip) - still show the scrubber at start instead
    // of hiding it. Self-terminate if it stays idle; render tick re-arms.
    if (_lastPushedPlayheadFrac != 0.0) {
      _lastPushedPlayheadFrac = 0.0;
      [iv setPlayheadFraction:0.0];
    }
    if (++_pollStall >= 10)
      [self invalidate];
    return;
  }

  // Movement tracking. `_pollStall` counts consecutive no-change ticks (reset
  // on arm and on movement) and drives the idle cutoff - same as before, so the
  // poller reliably stops when paused. `_lastMoveWall` is the wall-clock of the
  // last real movement and drives the play button. The first tick after (re)arm
  // just adopts the value (the -999 sentinel would read as a huge jump).
  NSTimeInterval nowWall = [NSDate timeIntervalSinceReferenceDate];
  if (_pollLast <= -900.0) {
    _pollLast = curSec;
  } else if (fabs(curSec - _pollLast) >= 1.0e-4) {
    _pollLast = curSec;
    _pollStall = 0;
    _lastMoveWall = nowWall;
  } else {
    _pollStall += 1;
  }

  double ph = MAX(0.0, MIN(1.0, (curSec - es) / ed));
  if (fabs(ph - _lastPushedPlayheadFrac) > 1.0e-5) {
    _lastPushedPlayheadFrac = ph;
    [iv setPlayheadFraction:ph];
  }
  // Infer "playing" from how long since currentTime last moved, in WALL-CLOCK
  // time rather than a tick count. Motion blur advances currentTime in bursts
  // (N samples per frame); the old tick-count threshold flickered the play
  // button between bursts, a time window tolerates them. The idle cutoff below
  // is a longer count, so a real pause flips the button off before polling
  // stops.
  BOOL playing = (nowWall - _lastMoveWall) < 0.3;
  if (playing != _lastPushedPlaying) {
    _lastPushedPlaying = playing;
    [iv setPlaying:playing];
  }

  if ([self _handleLoopBackWithActionAPI:act curSec:curSec inspector:iv])
    return;

  if (_pollStall >= 24) // ~0.4s+ of no movement → idle, stop polling
    [self invalidate];
}

/// Loop-back: pause→seek→resume when playhead is within ~1 frame of the
/// clip end (or stalled-near-end as a fallback for hosts that halt
/// currentTime a hair short). Cooldown so the sequence isn't re-fired
/// while the host processes it.
- (BOOL)_handleLoopBackWithActionAPI:(id<FxCustomParameterActionAPI_v4>)act
                              curSec:(double)curSec
                           inspector:(KKTimelineInspectorView *)iv {
  if (!_cache.loopEnabled)
    return NO;
  double es = _cache.effectStartSec, ed = _cache.effectDurSec;
  double frameDur =
      _cache.frameDurSec > 0.0 ? _cache.frameDurSec : (1.0 / 60.0);
  double ph = MAX(0.0, MIN(1.0, (curSec - es) / ed));
  double remaining = (es + ed) - curSec;
  BOOL atEnd = remaining <= frameDur * 1.5 || (_pollStall >= 4 && ph >= 0.97);
  if (!atEnd)
    return NO;
  NSTimeInterval nowMach = CACurrentMediaTime();
  if ((nowMach - _lastLoopWrapTime) <= 0.3)
    return NO;
  _lastLoopWrapTime = nowMach;
  // FCP's movePlayheadToTime: is timeline-time; Motion's is effect-time.
  // Half-frame nudge inside the clip avoids landing on the edit seam.
  double base = [KKHostInfo isRunningInFinalCut] ? _cache.timelineStartSec : es;
  CMTime target = CMTimeMakeWithSeconds(base + frameDur * 0.5, 600);
  NSObject *actTarget = _actionTarget;
  [act startAction:actTarget];
  id<FxCommandAPI_v2> cmd =
      [_apiManager apiForProtocol:@protocol(FxCommandAPI_v2)];
  [cmd performCommand:kFxCommand_TogglePlayback error:nil]; // pause
  [cmd movePlayheadToTime:target error:nil];
  [cmd performCommand:kFxCommand_TogglePlayback error:nil]; // resume
  [act endAction:actTarget];
  _lastPushedPlayheadFrac = 0.0;
  [iv setPlayheadFraction:0.0];
  _pollLast = base;
  _pollStall = 0;
  return YES;
}

@end
