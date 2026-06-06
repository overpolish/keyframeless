/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineInspectorView+Guide.h"
#import "KKTimelineInspectorView+Presets.h"
#import "KKTimelineInspectorView_Private.h"

#import "KKCheckboxView.h"
#import "KKLocalized.h"
#import "KKParameterRowView.h"
#import "KKPresetRowView.h" // KKPresetScreenRectForView
#import "KKPresetTimelineOps.h"
#import "KKPresets.h"
#import "KKPresetsPopover.h"
#import <KeyframelessKit/KKJoyrideController.h>
#import <KeyframelessKit/KKJoyrideGuideHost.h>
#import <KeyframelessKit/KKTimingCompat.h>

@interface KKTimelineInspectorView (PresetsInternal)
- (void)_applyPresetJSON:(NSString *)timelineJSON atPlayhead:(BOOL)atPlayhead;
@end

@implementation KKTimelineInspectorView (Presets)

// Falls back to 1.0 until the clip/frame duration is known.
- (double)_presetEndFraction {
  if (_clipDurationSeconds > 0.0 && _frameDurationSeconds > 0.0 &&
      _frameDurationSeconds < _clipDurationSeconds)
    return (_clipDurationSeconds - _frameDurationSeconds) /
           _clipDurationSeconds;
  return 1.0;
}

- (void)_buildPresetsRow {
  KKCheckboxView *unused = nil;
  _presetsRow = [self
      _buildTickGearRowWithParameterID:0
                            iconSymbol:@"bookmark"
                                 title:KKLoc(@"Presets",
                                             @"Section title: saved animation "
                                             @"presets.")
                     gearAccessibility:KKLoc(@"Preset library",
                                             @"Accessibility: open the saved "
                                             @"animation preset library.")
                            gearAction:@selector(_presetsClicked:)
                          showCheckbox:NO
                              checkbox:&unused
                            gearButton:&_presetsButton];
  [self addSubview:_presetsRow];
}

// Lazily build the popover and wire its save-capture + apply callbacks once.
- (KKPresetsPopover *)_ensurePresetsPopover {
  KKPresetsPopover *popover = _presetsPopover;
  if (!popover) {
    popover = [[KKPresetsPopover alloc] init];
    _presetsPopover = popover;
    __weak typeof(self) weak = self;
    popover.currentTimelineJSON = ^NSString *_Nullable {
      KKTimelineInspectorView *strong = weak;
      KKTimeline *timeline = strong.basicLanesView.currentTimeline;
      if (!timeline)
        return nil;
      // Fix the moving gaps to seconds so the preset keeps its transition feel.
      timeline =
          KKPresetTimelineAutoLocked(timeline, strong->_clipDurationSeconds);
      return [KKTimeline jsonFromTimeline:timeline];
    };
    popover.onApplyPreset = ^(NSString *timelineJSON, BOOL atPlayhead) {
      KKTimelineInspectorView *strong = weak;
      if (!strong)
        return;
      [strong _applyPresetJSON:timelineJSON atPlayhead:atPlayhead];
    };
  }
  popover.pluginKey = self.presetPluginKey;
  return popover;
}

- (void)_presetsClicked:(id)sender {
  [[self _ensurePresetsPopover] showRelativeToRect:_presetsButton.bounds
                                            ofView:_presetsButton];
}

- (void)_applyPresetJSON:(NSString *)timelineJSON atPlayhead:(BOOL)atPlayhead {
  KKTimeline *preset = [KKTimeline timelineFromJSON:timelineJSON];
  if (!preset)
    return;
  double end = [self _presetEndFraction];
  double clip = _clipDurationSeconds;
  KKTimeline *result;
  if (atPlayhead) {
    // Merge the preset in starting at the playhead, keeping earlier keyposes -
    // lets you stack e.g. a pop-in then a later pop-out.
    double p = self.basicLanesView.playheadFraction;
    p = fmax(0.0, fmin(p, end));
    result = KKPresetTimelineMergedAtFraction(
        preset, self.basicLanesView.currentTimeline, p, end, clip);
  } else {
    // Override: fit the preset to the clip's reachable range [0, end].
    result = KKPresetTimelineRemapped(preset, 0.0, end, clip);
  }
  if (!result)
    return;
  // Persist + undo via the host's existing write path, then refresh the UI
  // immediately (the same two-step the AI merge apply uses).
  if (self.onTimelineMutated)
    self.onTimelineMutated(result);
  [self applyTimeline:result];
  // A multi-lane / structurally-rich preset may not fit Basic; jump to Advanced
  // so the user sees the real animation rather than a degraded Basic
  // projection.
  if (_selectedTab == KKTimelineTabBasic &&
      !KKTimelineIsBasicCompatible(result, end))
    [self setActiveTab:KKTimelineTabAdvanced];
}

#pragma mark - Guide

- (NSArray<KKJoyrideStep *> *)
    _presetsGuideStepsForGuide:(KKJoyrideController *)guide
                       popover:(KKPresetsPopover *)pop {
  __weak KKPresetsPopover *wpop = pop;
  __weak KKJoyrideController *wguide = guide;
  __weak typeof(self) wself = self;
  // Cutout clicks reach the popover only while its window is the controller's
  // additionalPassthroughWindow - so only the (interactive) apply step sets it;
  // the narrated steps clear it so their spotlighted buttons aren't pressable.
  // Resolved lazily because the popover isn't open until the user opens it.
  void (^passthrough)(BOOL) = ^(BOOL on) {
    wguide.additionalPassthroughWindow = on ? wpop.popoverWindow : nil;
  };

  // Step 1: the user opens the popover themselves (the gear lives in the host
  // window, so the cutout click forwards there). Advances on onDidShow.
  KKJoyrideStep *open = [KKJoyrideStep
      stepWithMessage:KKLoc(@"Open your presets to get started.",
                            @"Presets guide step: open the popover.")
           targetView:nil];
  open.targetScreenRect = ^{
    __strong typeof(wself) s = wself;
    return s ? KKPresetScreenRectForView(s->_presetsButton) : NSZeroRect;
  };
  open.onEnter = ^{
    passthrough(NO);
  };

  KKJoyrideStep *apply = [KKJoyrideStep
      stepWithMessage:KKLoc(@"Click a preset to apply it - it replaces the "
                            @"current animation.",
                            @"Presets guide step: apply.")
           targetView:nil];
  apply.targetScreenRect = ^{
    return wpop ? [wpop guideFirstRowScreenRect] : NSZeroRect;
  };
  apply.onEnter = ^{
    passthrough(YES);
  };

  KKJoyrideStep *insert = [KKJoyrideStep
      stepWithMessage:KKLoc(@"This inserts the preset at the playhead instead, "
                            @"keeping your existing keyposes.",
                            @"Presets guide step: insert at playhead.")
           targetView:nil];
  insert.targetScreenRect = ^{
    return wpop ? [wpop guideFirstRowInsertButtonScreenRect] : NSZeroRect;
  };
  insert.showsNext = YES;
  insert.onEnter = ^{
    passthrough(NO);
  };

  KKJoyrideStep *save = [KKJoyrideStep
      stepWithMessage:KKLoc(@"To save your own, type a name here and press +.",
                            @"Presets guide step: save.")
           targetView:nil];
  save.targetScreenRect = ^{
    return wpop ? [wpop guideSaveAreaScreenRect] : NSZeroRect;
  };
  save.showsNext = YES;
  save.onEnter = ^{
    passthrough(NO);
  };

  KKJoyrideStep *closer = [KKJoyrideStep
      stepWithMessage:KKLoc(@"Presets let you reuse a move across clips and "
                            @"projects - build it once, apply it anywhere.",
                            @"Presets guide step: closing value statement.")
           targetView:nil];
  closer.targetScreenRect = ^{
    return wpop ? [wpop guidePopoverScreenRect] : NSZeroRect;
  };
  closer.showsNext = YES;
  closer.onEnter = ^{
    passthrough(NO);
  };

  return @[ open, apply, insert, save, closer ];
}

- (void)runPresetsGuide {
  KKJoyrideGuideHost *host = [self timingGuideHost];
  // forwardsGestures + the apply step's additionalPassthroughWindow let that
  // step's cutout click reach the popover.
  host.forwardsGestures = YES;
  __weak typeof(self) weak = self;

  host.onRunWillStart = ^{
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    // Prepare the popover but DON'T open it - the first step has the user open
    // it. guideMode makes it stay open + not auto-close on apply once shown.
    KKPresetsPopover *pop = [s _ensurePresetsPopover];
    pop.guideMode = YES;
  };

  [host
      runWithSeed:^KKTimeline * {
        // Seed with the current timeline so the host snapshots and restores it
        // (undoing the demo apply); nothing visibly changes at start.
        __strong typeof(weak) s = weak;
        return s.basicLanesView.currentTimeline;
      }
      buildSteps:^NSArray<KKJoyrideStep *> *(KKJoyrideController *guide,
                                             KKJoyrideLanesBinder *binder) {
        __strong typeof(weak) s = weak;
        if (!s)
          return @[];
        KKPresetsPopover *pop = (KKPresetsPopover *)s->_presetsPopover;
        pop.onDidShow = ^{
          __strong typeof(weak) s2 = weak;
          KKJoyrideController *g = [s2 timingGuideHost].currentGuide;
          if (g.currentStepIndex == 0) // the open step
            [g advance];
        };
        pop.onDidApplyPreset = ^{
          __strong typeof(weak) s2 = weak;
          KKJoyrideController *g = [s2 timingGuideHost].currentGuide;
          if (g.currentStepIndex == 1) // the apply step
            [g advance];
        };
        return [s _presetsGuideStepsForGuide:guide popover:pop];
      }
      extraOnComplete:^{
        __strong typeof(weak) s = weak;
        if (!s)
          return;
        KKPresetsPopover *pop = (KKPresetsPopover *)s->_presetsPopover;
        pop.onDidShow = nil;
        pop.onDidApplyPreset = nil;
        [pop closeForGuide];
        pop.guideMode = NO;
        // Clear the open-popover hook so other guides don't reopen it.
        [s timingGuideHost].onRunWillStart = nil;
      }];
}

@end
