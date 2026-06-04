/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLocalized.h"
#import "KKMiniCanvasRenderer.h"
#import "KKMiniCanvasView.h"
#import "KKPopoverHeaderView.h"
#import "KKTimelineLanesView+Guide.h"
#import "KKTimelineLanesView_Popovers.h"
#import "KKTokens.h"
#import <KeyframelessKit/KKEasing.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKSegmentEditView.h>

@implementation KKTimelineLanesView (SegmentPopovers)

- (void)_presentGapPopoverFromAnchor:(NSView *)anchor
                          animateOut:(BOOL)animateOut
                       startFraction:(double)startFraction
                         endFraction:(double)endFraction
                               curve:(KKIntervalCurve)curve
                           intensity:(double)intensity
                           frequency:(double)frequency
                          partLabels:(NSArray<NSString *> *)partLabels
                          partStates:(NSArray<NSNumber *> *)partStates
                       partRebuilder:
                           (NSArray<NSNumber *> * (^)(void))partRebuilder
                             onCurve:(void (^)(KKIntervalCurve))onCurve
                         onIntensity:(void (^)(double))onIntensity
                         onFrequency:(void (^)(double))onFrequency
                     onParticipation:(void (^)(NSInteger, BOOL))onParticipation
                         onDragBegin:(void (^)(void))onDragBegin
                           onDragEnd:(void (^)(void))onDragEnd
                               phase:(KKGapPopoverPhase)phase
                           laneLabel:(NSString *)laneLabel
                      representative:(KKInterval *)representativeInterval
                      intervalReader:(KKGapIntervalReader)intervalReader
                     intervalMutator:(KKGapIntervalMutator)intervalMutator {
  KKSegmentEditView *edit =
      [[KKSegmentEditView alloc] initWithKind:KKSegmentEditKindTransition
                                  showsLinked:NO
                                   bulkHeader:NO
                          participationLabels:partLabels
                          participationStates:partStates];
  edit.onParticipationToggled = ^(NSInteger idx, BOOL on) {
    if (onParticipation)
      onParticipation(idx, on);
  };
  edit.onParticipationDragBegin = ^{
    if (onDragBegin)
      onDragBegin();
  };
  edit.onParticipationDragEnd = ^{
    if (onDragEnd)
      onDragEnd();
  };
  edit.animateOut = animateOut;
  edit.curveType = (NSInteger)curve;
  edit.intensity = intensity;
  edit.frequency = frequency;
  // A curve pick is discrete → commits immediately (its own undo entry).
  // Intensity/frequency are continuous → KKSegmentEditView brackets the drag
  // via onSliderDragBegin/End, which we route to the host's undo group so the
  // per-tick writes coalesce to one entry (same chain as the boundary drag).
  __weak typeof(self) weakGap = self;
  edit.onCurveTypeChanged = ^(NSInteger ct) {
    if (onCurve)
      onCurve((KKIntervalCurve)ct);
    __strong typeof(weakGap) sg = weakGap;
    if (sg && sg->_onGapPopoverCurveChanged)
      sg->_onGapPopoverCurveChanged(ct);
  };
  edit.onIntensityChanged = ^(double v) {
    if (onIntensity)
      onIntensity(v);
  };
  edit.onFrequencyChanged = ^(double v) {
    if (onFrequency)
      onFrequency(v);
  };
  edit.onSliderDragBegin = ^{
    if (onDragBegin)
      onDragBegin();
  };
  edit.onSliderDragEnd = ^{
    if (onDragEnd)
      onDragEnd();
  };

  CGFloat w = [KKSegmentEditView contentWidth];
  CGFloat editH =
      [KKSegmentEditView contentHeightForKind:KKSegmentEditKindTransition
                                  showsLinked:NO
                                   bulkHeader:NO
                                participation:(partLabels.count > 0)];
  edit.translatesAutoresizingMaskIntoConstraints = NO;

  // Plugin-supplied extras (toggles, sliders) appended below the segment
  // editor. Each row gets its own intrinsic height; container height grows.
  NSArray<NSView *> *extras = nil;
  if (self.gapPopoverExtraRows && representativeInterval && intervalMutator)
    extras = self.gapPopoverExtraRows(phase, laneLabel, representativeInterval,
                                      intervalReader ?: ^KKInterval *{
                                        return representativeInterval;
                                      },
                                      intervalMutator);

  // Wrap the editor with a "Curve <start>–<end>" header (the editor itself is
  // left untouched - it's also used by the hold-modulation popover).
  NSString *range = [NSString
      stringWithFormat:@"%@ → %@", [self _timeStringForFraction:startFraction],
                       [self _timeStringForFraction:endFraction]];
  KKPopoverHeaderView *header = [[KKPopoverHeaderView alloc]
      initWithTitle:KKLoc(@"Curve", @"Section: easing curve.")
             detail:range
         symbolName:@"point.topleft.down.to.point.bottomright.curvepath"];
  CGFloat headerH = [KKPopoverHeaderView height];
  CGFloat extrasH = 0;
  for (NSView *v in extras)
    extrasH += v.intrinsicContentSize.height;
  CGFloat totalH =
      KKPaddingMD + headerH + KKSpacingSM + editH + extrasH + KKPaddingMD;
  NSView *container =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, w, totalH)];
  [container addSubview:header];
  [container addSubview:edit];
  [NSLayoutConstraint activateConstraints:@[
    [header.leadingAnchor constraintEqualToAnchor:container.leadingAnchor
                                         constant:KKPaddingMD],
    [header.topAnchor constraintEqualToAnchor:container.topAnchor
                                     constant:KKPaddingMD],
    [edit.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
    [edit.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
    [edit.topAnchor constraintEqualToAnchor:header.bottomAnchor
                                   constant:KKSpacingSM],
    [edit.heightAnchor constraintEqualToConstant:editH],
    [container.widthAnchor constraintEqualToConstant:w],
    [container.heightAnchor constraintEqualToConstant:totalH],
  ]];
  NSView *prev = edit;
  for (NSView *extra in extras) {
    extra.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:extra];
    [NSLayoutConstraint activateConstraints:@[
      // Match KKSegmentEditView's internal kHPadding (10) so the extras row
      // aligns with the segment editor's Linked-toggle row above it.
      [extra.leadingAnchor constraintEqualToAnchor:container.leadingAnchor
                                          constant:10.0],
      [extra.trailingAnchor constraintEqualToAnchor:container.trailingAnchor
                                           constant:-10.0],
      // First extra anchors to edit.bottom which already includes the
      // editor's internal kVPadding (~10pt); zero gap here lands at roughly
      // the same visual spacing as the editor's internal kRowGap rows.
      // Subsequent extras stack with no extra gap; rows that need separation
      // should bake it into their own intrinsicContentSize.
      [extra.topAnchor constraintEqualToAnchor:prev.bottomAnchor],
    ]];
    prev = extra;
  }

  // Track the editor + a rebuilder so _refresh can push fresh participation
  // pill states after an external mutation (cmd-Z) without reopening - same
  // pattern as the hold-modulation popover.
  _openGapEditor = edit;
  _openGapRebuilder = [partRebuilder copy];
  _openGapIntervalReader = [intervalReader copy];
  _openExtraRows = extras;
  __weak typeof(self) weakClose = self;
  [self _showPopoverWithContent:container
                       fromView:anchor
                        onClose:^{
                          __strong typeof(weakClose) sc = weakClose;
                          if (!sc)
                            return;
                          sc->_openGapEditor = nil;
                          sc->_openGapRebuilder = nil;
                          sc->_openGapIntervalReader = nil;
                          sc->_openExtraRows = nil;
                        }];

  // Guide hook: same settle delay as the static-values popover so the
  // segment editor is in a window and laid out before the guide reads pill
  // rects. content == editor for this popover.
  if (self.onGapPopoverWillOpen) {
    __weak KKSegmentEditView *weakEdit = edit;
    __weak typeof(self) weakSelf = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          __strong typeof(weakSelf) s = weakSelf;
          __strong KKSegmentEditView *e = weakEdit;
          if (s && e && s.onGapPopoverWillOpen)
            s.onGapPopoverWillOpen(e, e);
        });
  }
}

// KKSegmentEditView (Hold kind) pills are indexed by KKHoldEffect
// (0 None, 1 Bounce, 2 Wiggle); the model stores KKIntervalModulation. The
// evaluator maps Wiggle→Wiggle, Oscillate→Bounce (KKTimingEvaluation.m), so
// the pill index and the stored enum are NOT interchangeable.
NSInteger KKModulationToPill(KKIntervalModulation m) {
  switch (m) {
  case KKIntervalModulationWiggle:
    return KKHoldEffectWiggle;
  case KKIntervalModulationOscillate:
    return KKHoldEffectBounce;
  case KKIntervalModulationHandheld:
    return KKHoldEffectHandheld;
  default:
    return KKHoldEffectNone;
  }
}
static KKIntervalModulation KKPillToModulation(NSInteger pill) {
  switch (pill) {
  case KKHoldEffectWiggle:
    return KKIntervalModulationWiggle;
  case KKHoldEffectBounce:
    return KKIntervalModulationOscillate;
  case KKHoldEffectHandheld:
    return KKIntervalModulationHandheld;
  default:
    return KKIntervalModulationNone;
  }
}

- (void)
    _presentHoldModulationPopoverFromAnchor:(NSView *)anchor
                              startFraction:(double)startFraction
                                endFraction:(double)endFraction
                                 modulation:(KKIntervalModulation)modulation
                                  intensity:(double)intensity
                                  frequency:(double)frequency
                                       seed:(uint32_t)seed
                                     linked:(BOOL)linked
                                showsLinked:(BOOL)showsLinked
                                 partLabels:(NSArray<NSArray<NSString *> *> *)
                                                partCompoundLabels
                                 partStates:(NSArray<NSArray<NSNumber *> *> *)
                                                partCompoundStates
                              partRebuilder:
                                  (NSArray<NSArray<NSNumber *> *> *_Nullable (
                                      ^)(void))partRebuilder
                               onModulation:
                                   (void (^)(KKIntervalModulation))onModulation
                                onIntensity:(void (^)(double))onIntensity
                                onFrequency:(void (^)(double))onFrequency
                                     onSeed:(void (^)(uint32_t))onSeed
                                   onLinked:(void (^)(BOOL))onLinked
                            onParticipation:(void (^)(NSInteger,
                                                      BOOL))onParticipation
                                onDragBegin:(void (^)(void))onDragBegin
                                  onDragEnd:(void (^)(void))onDragEnd
                                      phase:(KKGapPopoverPhase)phase
                                  laneLabel:(NSString *)laneLabel
                             representative:(KKInterval *)representativeInterval
                             intervalReader:(KKGapIntervalReader)intervalReader
                            intervalMutator:
                                (KKGapIntervalMutator)intervalMutator {
  KKSegmentEditView *edit =
      [[KKSegmentEditView alloc] initWithKind:KKSegmentEditKindHold
                                  showsLinked:showsLinked
                                   bulkHeader:NO
                       participationCompounds:partCompoundLabels
                  participationCompoundStates:partCompoundStates];
  edit.onParticipationToggled = ^(NSInteger idx, BOOL on) {
    if (onParticipation)
      onParticipation(idx, on);
  };
  edit.onParticipationDragBegin = ^{
    if (onDragBegin)
      onDragBegin();
  };
  edit.onParticipationDragEnd = ^{
    if (onDragEnd)
      onDragEnd();
  };
  edit.curveType = KKModulationToPill(modulation);
  edit.intensity = intensity;
  edit.frequency = frequency;
  edit.seed = seed;
  edit.linked = linked;
  __weak KKSegmentEditView *weakEdit = edit;
  edit.onCurveTypeChanged = ^(NSInteger ct) {
    if (onModulation)
      onModulation(KKPillToModulation(ct));
  };
  edit.onIntensityChanged = ^(double v) {
    if (onIntensity)
      onIntensity(v);
  };
  edit.onFrequencyChanged = ^(double v) {
    if (onFrequency)
      onFrequency(v);
  };
  edit.onSeedChanged = ^(uint32_t s) {
    if (onSeed)
      onSeed(s);
  };
  edit.onSeedReroll = ^{
    uint32_t s = arc4random();
    weakEdit.seed = s;
    if (onSeed)
      onSeed(s);
  };
  edit.onLinkedChanged = ^(BOOL l) {
    if (onLinked)
      onLinked(l);
  };
  edit.onSliderDragBegin = ^{
    if (onDragBegin)
      onDragBegin();
  };
  edit.onSliderDragEnd = ^{
    if (onDragEnd)
      onDragEnd();
  };

  CGFloat w = [KKSegmentEditView contentWidth];
  CGFloat editH =
      [KKSegmentEditView contentHeightForKind:KKSegmentEditKindHold
                                  showsLinked:showsLinked
                                   bulkHeader:NO
                                participation:(partCompoundLabels.count > 0)];
  edit.translatesAutoresizingMaskIntoConstraints = NO;

  // Same header treatment as the curve popover (the editor is
  // shared/untouched).
  NSString *range = [NSString
      stringWithFormat:@"%@ → %@", [self _timeStringForFraction:startFraction],
                       [self _timeStringForFraction:endFraction]];
  KKPopoverHeaderView *header = [[KKPopoverHeaderView alloc]
      initWithTitle:KKLoc(@"Modulation", @"Section: modulation settings.")
             detail:range
         symbolName:@"waveform"];
  NSArray<NSView *> *extras = nil;
  if (self.gapPopoverExtraRows && representativeInterval && intervalMutator)
    extras = self.gapPopoverExtraRows(phase, laneLabel, representativeInterval,
                                      intervalReader ?: ^KKInterval *{
                                        return representativeInterval;
                                      },
                                      intervalMutator);
  CGFloat headerH = [KKPopoverHeaderView height];
  CGFloat extrasH = 0;
  for (NSView *v in extras)
    extrasH += v.intrinsicContentSize.height;
  CGFloat totalH =
      KKPaddingMD + headerH + KKSpacingSM + editH + extrasH + KKPaddingMD;
  NSView *container =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, w, totalH)];
  [container addSubview:header];
  [container addSubview:edit];
  [NSLayoutConstraint activateConstraints:@[
    [header.leadingAnchor constraintEqualToAnchor:container.leadingAnchor
                                         constant:KKPaddingMD],
    [header.topAnchor constraintEqualToAnchor:container.topAnchor
                                     constant:KKPaddingMD],
    [edit.leadingAnchor constraintEqualToAnchor:container.leadingAnchor],
    [edit.trailingAnchor constraintEqualToAnchor:container.trailingAnchor],
    [edit.topAnchor constraintEqualToAnchor:header.bottomAnchor
                                   constant:KKSpacingSM],
    [edit.heightAnchor constraintEqualToConstant:editH],
    [container.widthAnchor constraintEqualToConstant:w],
    [container.heightAnchor constraintEqualToConstant:totalH],
  ]];
  NSView *prev = edit;
  for (NSView *extra in extras) {
    extra.translatesAutoresizingMaskIntoConstraints = NO;
    [container addSubview:extra];
    [NSLayoutConstraint activateConstraints:@[
      // Match KKSegmentEditView's internal kHPadding (10) so the extras row
      // aligns with the segment editor's Linked-toggle row above it.
      [extra.leadingAnchor constraintEqualToAnchor:container.leadingAnchor
                                          constant:10.0],
      [extra.trailingAnchor constraintEqualToAnchor:container.trailingAnchor
                                           constant:-10.0],
      // First extra anchors to edit.bottom which already includes the
      // editor's internal kVPadding (~10pt); zero gap here lands at roughly
      // the same visual spacing as the editor's internal kRowGap rows.
      // Subsequent extras stack with no extra gap; rows that need separation
      // should bake it into their own intrinsicContentSize.
      [extra.topAnchor constraintEqualToAnchor:prev.bottomAnchor],
    ]];
    prev = extra;
  }

  // Stash for external refresh on applyTimeline (cmd-Z etc).
  _openHoldModEditor = edit;
  _openHoldModRebuilder = [partRebuilder copy];
  _openHoldModIntervalReader = [intervalReader copy];
  _openExtraRows = extras;
  __weak typeof(self) weak = self;
  [self _showPopoverWithContent:container
                       fromView:anchor
                        onClose:^{
                          __strong typeof(weak) s = weak;
                          if (!s)
                            return;
                          s->_openHoldModEditor = nil;
                          s->_openHoldModRebuilder = nil;
                          s->_openHoldModIntervalReader = nil;
                          s->_openExtraRows = nil;
                        }];
}

// Unified static-values popover presenter. Constants AND keypose (boundary)
// modes flow through here - whatever feature lives in this method is in BOTH
// popovers automatically. New popover features go here, NOT into either
// caller, so the two never drift apart again.

@end
