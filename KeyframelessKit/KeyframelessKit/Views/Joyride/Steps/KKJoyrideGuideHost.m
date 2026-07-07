/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKJoyrideGuideHost.h"
#import <KeyframelessKit/KKHostInfo.h>
#import <KeyframelessKit/KKTimelineAdvancedView.h>
#import <KeyframelessKit/KKTimelineLanesView+Guide.h>
#import <KeyframelessKit/KKTimelineLanesView.h>
#import <KeyframelessKit/KKTimingStage.h>

// OSC warm-up timing: after the zoom-to-fit AppleScript, the host needs time
// to actually resize the viewer before the guide reads spotlight positions.
// Wait for the resize to settle, force a re-render at the final geometry, then
// wait once more before starting. Tuned values; do not shorten without testing
// against a slow host resize.
static const NSTimeInterval kKKOSCZoomSettleDelay = 0.6;
static const NSTimeInterval kKKOSCRunDelay = 0.2;

@implementation KKJoyrideGuideHost {
  __weak NSView *_hostView;
  __weak KKTimelineLanesView *_lanesView;
  KKJoyrideController *_guide;
  KKJoyrideLanesBinder *_binder;
  KKTimeline *_savedTimeline;
  // Advanced-graph selection at seed time, cleared for the guide's duration and
  // restored on teardown so the guide's marquee / multi-select doesn't leak
  // out.
  NSSet<NSString *> *_savedPillKeys;
  NSSet<NSString *> *_savedGapKeys;
  BOOL _didSaveSelection;
  // Lane-filter visibility at seed time: the guide shows every lane for its
  // duration, then the user's hidden set is reinstated on teardown.
  NSSet<NSString *> *_savedHiddenLaneLabels;
  BOOL _didSaveHidden;
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
         buildSteps:
             (NSArray<KKJoyrideStep *> * (^)(KKJoyrideController *,
                                             KKJoyrideLanesBinder *))buildSteps
    extraOnComplete:(void (^)(void))extraOnComplete {
  // End any in-flight run (its onComplete will restore + release).
  [_guide dismiss];
  // Close any popover the user left open so it isn't sitting over the guide.
  [_lanesView guideCloseAllPopovers];
  KKTimeline *seed = seedBlock ? seedBlock() : nil;
  if (seed)
    [self prepareWithSeed:seed];
  [self runBuildSteps:buildSteps extraOnComplete:extraOnComplete];
}

- (void)runOSCGuideWithSeed:(KKTimeline *)seed
                 buildSteps:(NSArray<KKJoyrideStep *> * (^)(
                                KKJoyrideController *,
                                KKJoyrideLanesBinder *))buildSteps
            extraOnComplete:(void (^)(void))extraOnComplete {
  [_guide dismiss];
  [_lanesView guideCloseAllPopovers];
  [self prepareWithSeed:seed];

  NSArray<KKJoyrideStep *> * (^build)(
      KKJoyrideController *, KKJoyrideLanesBinder *) = [buildSteps copy];
  void (^extra)(void) = [extraOnComplete copy];
  __weak typeof(self) weak = self;
  dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
    [KKHostInfo zoomHostViewerToFit];
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW,
                      (int64_t)(kKKOSCZoomSettleDelay * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          __strong typeof(weak) s = weak;
          if (!s)
            return;
          // Settle: re-apply the seed so a re-render runs at the final,
          // post-resize geometry before the guide reads spotlight positions.
          if (s.timelineApplier && seed)
            s.timelineApplier(seed);
          dispatch_after(
              dispatch_time(DISPATCH_TIME_NOW,
                            (int64_t)(kKKOSCRunDelay * NSEC_PER_SEC)),
              dispatch_get_main_queue(), ^{
                __strong typeof(weak) s2 = weak;
                if (s2)
                  [s2 runBuildSteps:build extraOnComplete:extra];
              });
        });
  });
}

- (void)autostartOnceWithSeenKey:(NSString *)seenKey
                    precondition:(BOOL (^)(void))precondition
                           start:(void (^)(void))start {
  if (!start)
    return;
  if (![self _autostartAllowedWithKey:seenKey precondition:precondition])
    return;
  BOOL (^pre)(void) = [precondition copy];
  void (^st)(void) = [start copy];
  __weak typeof(self) weak = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    if ([s _autostartAllowedWithKey:seenKey precondition:pre])
      st();
  });
}

- (BOOL)_autostartAllowedWithKey:(NSString *)seenKey
                    precondition:(BOOL (^)(void))precondition {
  if (!_hostView.window)
    return NO;
  if (precondition && !precondition())
    return NO;
  if (seenKey.length &&
      [NSUserDefaults.standardUserDefaults boolForKey:seenKey])
    return NO;
  return YES;
}

- (void)prepareWithSeed:(KKTimeline *)seed {
  if (!seed)
    return;
  if (self.currentTimelineProvider)
    _savedTimeline = self.currentTimelineProvider();
  // Stash + clear any advanced-graph selection so the guide starts clean and
  // its marquee / multi-select is undone again on teardown.
  KKTimelineAdvancedView *adv = _lanesView.advancedGraph;
  if (adv) {
    _savedPillKeys = adv.selectedPillKeys;
    _savedGapKeys = adv.selectedGapKeys;
    _didSaveSelection = YES;
    [adv clearSelection];
  }
  // Snapshot the user's lane-filter visibility, then reveal every lane so the
  // guide's seed (and its spotlight steps) aren't hidden behind a filtered-out
  // pill. Restored on teardown.
  _savedHiddenLaneLabels = [_lanesView guideLaneFilterHiddenLabels];
  _didSaveHidden = YES;
  if (self.timelineApplier)
    self.timelineApplier(seed);
  [_lanesView guideShowAllLanes];
}

- (void)runBuildSteps:
            (NSArray<KKJoyrideStep *> * (^)(KKJoyrideController *,
                                            KKJoyrideLanesBinder *))buildSteps
      extraOnComplete:(void (^)(void))extraOnComplete {
  NSView *hostView = _hostView;
  KKTimelineLanesView *lanesView = _lanesView;
  if (!hostView || !lanesView || !buildSteps)
    return;

  if (self.onRunWillStart)
    self.onRunWillStart();

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
               if (s.onRunDidEnd)
                 s.onRunDidEnd();
               [s _teardown];
             }];
}

- (void)_teardown {
  [_binder teardown];
  _binder = nil;

  // Defer controller release until the next runloop tick - we're inside
  // its own onComplete block, so dropping the strong ref here would
  // dealloc it mid-call.
  KKJoyrideController *toRelease = _guide;
  _guide = nil;
  if (toRelease) {
    dispatch_async(dispatch_get_main_queue(), ^{
      (void)toRelease;
    });
  }

  // Restore the saved timeline on the next tick, for the same reason -
  // the inspector callback chain that fires off applyTimeline: may still
  // be unwinding on this call stack. The pre-guide selection is reinstated
  // right after, once its keyposes exist again in the restored timeline.
  KKTimeline *saved = _savedTimeline;
  _savedTimeline = nil;
  NSSet<NSString *> *pills = _savedPillKeys;
  NSSet<NSString *> *gaps = _savedGapKeys;
  BOOL restoreSelection = _didSaveSelection;
  _savedPillKeys = nil;
  _savedGapKeys = nil;
  _didSaveSelection = NO;
  NSSet<NSString *> *hidden = _savedHiddenLaneLabels;
  BOOL restoreHidden = _didSaveHidden;
  _savedHiddenLaneLabels = nil;
  _didSaveHidden = NO;
  void (^applier)(KKTimeline *) = self.timelineApplier;
  __weak KKTimelineLanesView *lanesView = _lanesView;
  void (^restoreSel)(void) = ^{
    if (restoreSelection)
      [lanesView.advancedGraph applySelectionPillKeys:pills gapKeys:gaps];
    // After the user's timeline is back (its real lanes rebuilt the filter
    // bar), reinstate the pills they had hidden before the guide.
    if (restoreHidden)
      [lanesView guideRestoreLaneFilterHidden:hidden];
  };
  if (saved && applier) {
    dispatch_async(dispatch_get_main_queue(), ^{
      applier(saved);
      restoreSel();
    });
  } else if (restoreSelection || restoreHidden) {
    dispatch_async(dispatch_get_main_queue(), restoreSel);
  }
}

@end
