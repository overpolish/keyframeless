/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKJoyrideGuideHost.h"
#import <KeyframelessKit/KKTimelineLanesView.h>
#import <KeyframelessKit/KKTimingStage.h>

@implementation KKJoyrideGuideHost {
  __weak NSView *_hostView;
  __weak KKTimelineLanesView *_lanesView;
  KKJoyrideController *_guide;
  KKJoyrideLanesBinder *_binder;
  KKTimeline *_savedTimeline;
  NSInteger _finalIndex;
}

- (instancetype)initWithHostView:(NSView *)hostView
                       lanesView:(KKTimelineLanesView *)lanesView {
  self = [super init];
  if (self) {
    _hostView = hostView;
    _lanesView = lanesView;
    _finalIndex = -1;
  }
  return self;
}

- (KKJoyrideController *)currentGuide {
  return _guide;
}

- (KKJoyrideLanesBinder *)currentBinder {
  return _binder;
}

- (BOOL)isActive {
  return _guide.isActive;
}

- (void)dismiss {
  [_guide dismiss];
}

- (void)runWithSeed:(KKTimeline * (^)(void))seedBlock
         buildSteps:(NSArray<KKJoyrideStep *> *(^)(
                        KKJoyrideController *,
                        KKJoyrideLanesBinder *))buildSteps
    extraOnComplete:(void (^)(void))extraOnComplete {
  // End any in-flight run (its onComplete will restore + release).
  [_guide dismiss];
  KKTimeline *seed = seedBlock ? seedBlock() : nil;
  if (seed)
    [self prepareWithSeed:seed];
  [self runBuildSteps:buildSteps extraOnComplete:extraOnComplete];
}

- (void)prepareWithSeed:(KKTimeline *)seed {
  if (!seed)
    return;
  if (self.currentTimelineProvider)
    _savedTimeline = self.currentTimelineProvider();
  if (self.timelineApplier)
    self.timelineApplier(seed);
}

- (void)runBuildSteps:(NSArray<KKJoyrideStep *> *(^)(
                          KKJoyrideController *,
                          KKJoyrideLanesBinder *))buildSteps
      extraOnComplete:(void (^)(void))extraOnComplete {
  NSView *hostView = _hostView;
  KKTimelineLanesView *lanesView = _lanesView;
  if (!hostView || !lanesView || !buildSteps)
    return;

  KKJoyrideController *guide =
      [[KKJoyrideController alloc] initWithHostView:hostView];
  guide.forwardsGestures = self.forwardsGestures;
  KKJoyrideLanesBinder *binder =
      [[KKJoyrideLanesBinder alloc] initWithLanesView:lanesView guide:guide];
  _guide = guide;
  _binder = binder;

  NSArray<KKJoyrideStep *> *steps = buildSteps(guide, binder);
  _finalIndex = (NSInteger)steps.count - 1;

  __weak typeof(self) weak = self;
  void (^extra)(void) = [extraOnComplete copy];
  [guide startWithSteps:steps
             onComplete:^{
               __strong typeof(weak) s = weak;
               if (!s)
                 return;
               KKJoyrideController *g = s->_guide;
               BOOL completed = g && g.currentStepIndex >= s->_finalIndex;
               if (completed && s.onGuideCompleted)
                 s.onGuideCompleted();
               if (extra)
                 extra();
               [s _teardown];
             }];
}

- (void)_teardown {
  [_binder teardown];
  _binder = nil;

  // Defer controller release until the next runloop tick — we're inside
  // its own onComplete block, so dropping the strong ref here would
  // dealloc it mid-call.
  KKJoyrideController *toRelease = _guide;
  _guide = nil;
  if (toRelease) {
    dispatch_async(dispatch_get_main_queue(), ^{
      (void)toRelease;
    });
  }

  // Restore the saved timeline on the next tick, for the same reason —
  // the inspector callback chain that fires off applyTimeline: may still
  // be unwinding on this call stack.
  KKTimeline *saved = _savedTimeline;
  _savedTimeline = nil;
  void (^applier)(KKTimeline *) = self.timelineApplier;
  if (saved && applier) {
    dispatch_async(dispatch_get_main_queue(), ^{
      applier(saved);
    });
  }
}

@end
