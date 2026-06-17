/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKJoyrideLanesBinder.h"
#import "KKJoyrideTrigger_Internal.h"
#import <KeyframelessKit/KKMiniViewerView.h>
#import <KeyframelessKit/KKSegmentEditView.h>
#import <KeyframelessKit/KKTimelineBasicView+Guide.h>
#import <KeyframelessKit/KKTimelineBasicView.h>
#import <KeyframelessKit/KKTimelineLanesView+Guide.h>
#import <KeyframelessKit/KKTimelineLanesView.h>

@interface _KKJoyrideStepBinding : NSObject
@property(nonatomic, weak) KKJoyrideStep *step;
@property(nonatomic) NSInteger stepIndex;
/// Original (pre-arm) advance trigger; preserved so that re-entering this
/// step resets the arm state.
@property(nonatomic, strong, nullable) KKJoyrideTrigger *advanceOriginal;
/// Currently-listening advance trigger - equal to `advanceOriginal` until a
/// `thenWaitFor:` outer matches, after which it points at the inner.
@property(nonatomic, strong, nullable) KKJoyrideTrigger *advanceActive;
@property(nonatomic, strong, nullable) KKJoyrideTrigger *dismiss;
@property(nonatomic) KKJoyrideCloseOnAdvance closeOnAdvance;
/// playToggleEdge state, per binding (armed by the first play-button tap).
@property(nonatomic) BOOL playStarted;
@property(nonatomic) CFAbsoluteTime activatedAt;
@end
@implementation _KKJoyrideStepBinding
@end

@implementation KKJoyrideLanesBinder {
  __weak KKTimelineLanesView *_lanes;
  __weak KKJoyrideController *_guide;
  NSMutableArray<_KKJoyrideStepBinding *> *_bindings;
  __weak NSString *_latestOptedInLane;
  NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *_latestStaticValues;
  // Field handlers we've installed on the lanes view (per label), so we can
  // nil them out on teardown.
  NSMutableSet<NSString *> *_installedFieldHandlerLabels;
  __weak KKMiniViewerView *_mcWiredCanvas;
  NSInteger _lastFiredFromStep;
  BOOL _installed;
}

- (instancetype)initWithLanesView:(KKTimelineLanesView *)lanesView
                            guide:(KKJoyrideController *)guide {
  self = [super init];
  if (self) {
    _lanes = lanesView;
    _guide = guide;
    _bindings = [NSMutableArray array];
    _latestStaticValues = [NSMutableDictionary dictionary];
    _installedFieldHandlerLabels = [NSMutableSet set];
    _lastFiredFromStep = -1;
    [self _installCallbacks];
  }
  return self;
}

- (void)dealloc {
  [self teardown];
}

#pragma mark - Binding API

- (void)bindStep:(KKJoyrideStep *)step
         atIndex:(NSInteger)stepIndex
       advanceOn:(KKJoyrideTrigger *)advance
       dismissOn:(KKJoyrideTrigger *)dismiss {
  _KKJoyrideStepBinding *b = [[_KKJoyrideStepBinding alloc] init];
  b.step = step;
  b.stepIndex = stepIndex;
  b.advanceOriginal = advance;
  b.advanceActive = advance;
  b.dismiss = dismiss;
  [_bindings addObject:b];
}

- (void)setCloseOnAdvance:(KKJoyrideCloseOnAdvance)close
                  forStep:(KKJoyrideStep *)step {
  for (_KKJoyrideStepBinding *b in _bindings) {
    if (b.step == step) {
      b.closeOnAdvance = close;
      return;
    }
  }
}

#pragma mark - Latest payloads

- (NSView *)latestOptedInLaneRow {
  KKTimelineLanesView *lanes = _lanes;
  NSString *label = _latestOptedInLane;
  if (!lanes || !label)
    return nil;
  return [lanes laneRowViewForLabel:label];
}

- (NSArray<NSNumber *> *)latestStaticValueForLabel:(NSString *)label {
  return _latestStaticValues[label];
}

#pragma mark - Inspector signal forwarding

- (void)notifyPlaybackToggleTapped {
  [self _fireType:KKJoyrideTriggerTypePlayToggleEdge
           intArg:0
          intArg2:0
            label:nil];
  if (self.playToggleTapped)
    self.playToggleTapped();
}

#pragma mark - Teardown

- (void)teardown {
  if (!_installed)
    return;
  _installed = NO;
  KKTimelineLanesView *lanes = _lanes;
  if (lanes) {
    lanes.onManagePopoverWillOpen = nil;
    lanes.onManagePopoverClosed = nil;
    lanes.onLaneOptedIn = nil;
    lanes.onStaticValuesPopoverWillOpen = nil;
    lanes.onStaticValuesPopoverClosed = nil;
    lanes.onStaticValueChanged = nil;
    lanes.onStaticValueDragEnded = nil;
    lanes.onGapPopoverWillOpen = nil;
    lanes.onGapPopoverCurveChanged = nil;
    lanes.onGuideRenderModeChanged = nil;
    lanes.onGuideMiniViewerSizeChanged = nil;
    lanes.onGuideFilmstripCellActivated = nil;
    lanes.onGuideDynamicToggled = nil;
    lanes.onGuideLaneFilterToggled = nil;
    KKTimelineBasicView *graph = lanes.basicGraph;
    graph.onPhaseToggled = nil;
    graph.onDiamondTapped = nil;
    graph.onGapTapped = nil;
    for (NSString *label in _installedFieldHandlerLabels)
      [lanes setGuideConstantFieldEditHandlerForLabel:label handler:nil];
    [_installedFieldHandlerLabels removeAllObjects];
  }
  KKMiniViewerView *cv = _mcWiredCanvas;
  if (cv) {
    cv.onViewTransformChanged = nil;
    cv.onViewReset = nil;
    cv.onDelegateHandledDoubleClick = nil;
    cv.onOptHideHandle = nil;
  }
  _mcWiredCanvas = nil;
  self.playToggleTapped = nil;
  KKJoyrideController *guide = _guide;
  if (guide)
    guide.additionalPassthroughWindow = nil;
}

#pragma mark - Callback installation

- (void)_installCallbacks {
  KKTimelineLanesView *lanes = _lanes;
  if (!lanes)
    return;
  _installed = YES;
  __weak typeof(self) weak = self;

  lanes.onManagePopoverWillOpen = ^(NSView *row) {
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    s->_latestManagePopoverRow = row;
    KKJoyrideController *g = s->_guide;
    g.additionalPassthroughWindow = row.window;
    [s _fireType:KKJoyrideTriggerTypeManagePopoverWillOpen
          intArg:0
         intArg2:0
           label:nil];
  };

  lanes.onManagePopoverClosed = ^{
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    s->_latestManagePopoverRow = nil;
    KKJoyrideController *g = s->_guide;
    g.additionalPassthroughWindow = nil;
    [s _fireType:KKJoyrideTriggerTypeManagePopoverClosed
          intArg:0
         intArg2:0
           label:nil];
  };

  lanes.onLaneOptedIn = ^(NSString *label) {
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    s->_latestOptedInLane = label;
    [s _fireType:KKJoyrideTriggerTypeLaneOptedIn
          intArg:0
         intArg2:0
           label:label];
  };

  lanes.onStaticValuesPopoverWillOpen =
      ^(NSView *content, KKMiniViewerView *_Nullable cv) {
        __strong typeof(weak) s = weak;
        if (!s)
          return;
        s->_latestStaticValuesPopoverContent = content;
        s->_latestMiniViewer = cv;
        KKJoyrideController *g = s->_guide;
        g.additionalPassthroughWindow = content.window;
        [s _wireMiniViewer:cv];
        [s _installFieldHandlersForOpenPopover];
        [s _fireType:KKJoyrideTriggerTypeStaticValuesPopoverWillOpen
              intArg:0
             intArg2:0
               label:nil];
        if (s.staticValuesPopoverDidOpen)
          s.staticValuesPopoverDidOpen(content, cv);
      };

  lanes.onStaticValuesPopoverClosed = ^{
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    s->_latestStaticValuesPopoverContent = nil;
    s->_latestMiniViewer = nil;
    KKJoyrideController *g = s->_guide;
    g.additionalPassthroughWindow = nil;
    [s _fireType:KKJoyrideTriggerTypeStaticValuesPopoverClosed
          intArg:0
         intArg2:0
           label:nil];
    if (s.staticValuesPopoverDidClose)
      s.staticValuesPopoverDidClose();
  };

  lanes.onStaticValueChanged = ^(NSString *label, NSArray<NSNumber *> *values) {
    __strong typeof(weak) s = weak;
    if (!s || !label)
      return;
    s->_latestStaticValues[label] = [values copy];
  };

  lanes.onStaticValueDragEnded =
      ^(NSString *label, NSArray<NSNumber *> *values) {
        __strong typeof(weak) s = weak;
        if (!s)
          return;
        if (label)
          s->_latestStaticValues[label] = [values copy];
        [s _fireType:KKJoyrideTriggerTypeStaticValueDragEnded
              intArg:0
             intArg2:0
               label:label];
        if (s.staticValueDragDidEnd)
          s.staticValueDragDidEnd(label ?: @"", values ?: @[]);
      };

  lanes.onGapPopoverWillOpen = ^(NSView *content, KKSegmentEditView *editor) {
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    s->_latestGapPopoverContent = content;
    s->_latestGapSegmentEditor = editor;
    KKJoyrideController *g = s->_guide;
    g.additionalPassthroughWindow = content.window;
    [s _fireType:KKJoyrideTriggerTypeGapPopoverWillOpen
          intArg:0
         intArg2:0
           label:nil];
  };

  lanes.onGapPopoverCurveChanged = ^(NSInteger curveType) {
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    [s _fireType:KKJoyrideTriggerTypeGapPopoverCurveChanged
          intArg:curveType
         intArg2:0
           label:nil];
  };

  lanes.onGuideRenderModeChanged = ^(KKMiniViewerRenderMode mode) {
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    [s _fireType:KKJoyrideTriggerTypeRenderModeChanged
          intArg:(NSInteger)mode
         intArg2:0
           label:nil];
  };

  lanes.onGuideMiniViewerSizeChanged = ^(NSInteger sizeIndex) {
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    [s _fireType:KKJoyrideTriggerTypeMiniViewerSizeChanged
          intArg:sizeIndex
         intArg2:0
           label:nil];
  };

  lanes.onGuideFilmstripCellActivated = ^(double fraction) {
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    [s _fireType:KKJoyrideTriggerTypeFilmstripCellActivated
          intArg:0
         intArg2:0
           label:nil];
  };

  lanes.onGuideDynamicToggled = ^(BOOL on) {
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    [s _fireType:KKJoyrideTriggerTypeDynamicToggled
          intArg:on ? 1 : 0
         intArg2:0
           label:nil];
  };

  lanes.onGuideLaneFilterToggled = ^{
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    [s _fireType:KKJoyrideTriggerTypeLaneFilterToggled
          intArg:0
         intArg2:0
           label:nil];
  };

  KKTimelineBasicView *graph = lanes.basicGraph;
  graph.onPhaseToggled = ^(NSInteger phase, BOOL on) {
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    [s _fireType:KKJoyrideTriggerTypePhaseToggled
          intArg:phase
         intArg2:(on ? 1 : 0)label:nil];
  };
  graph.onDiamondTapped = ^(NSInteger idx) {
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    [s _fireType:KKJoyrideTriggerTypeDiamondTapped
          intArg:idx
         intArg2:0
           label:nil];
  };
  graph.onGapTapped = ^(NSInteger section) {
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    [s _fireType:KKJoyrideTriggerTypeGapTapped
          intArg:section
         intArg2:0
           label:nil];
  };
}

- (void)_wireMiniViewer:(KKMiniViewerView *)cv {
  KKMiniViewerView *prev = _mcWiredCanvas;
  if (prev && prev != cv) {
    prev.onViewTransformChanged = nil;
    prev.onViewReset = nil;
    prev.onDelegateHandledDoubleClick = nil;
    prev.onOptHideHandle = nil;
  }
  _mcWiredCanvas = cv;
  if (!cv)
    return;
  __weak typeof(self) weak = self;
  cv.onViewTransformChanged = ^(KKMiniViewerTransformKind kind) {
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    [s _fireType:KKJoyrideTriggerTypeMiniViewerViewTransformChanged
          intArg:(NSInteger)kind
         intArg2:0
           label:nil];
  };
  cv.onViewReset = ^{
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    [s _fireType:KKJoyrideTriggerTypeMiniViewerViewReset
          intArg:0
         intArg2:0
           label:nil];
  };
  cv.onDelegateHandledDoubleClick = ^{
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    [s _fireType:KKJoyrideTriggerTypeMiniViewerDoubleClickHandled
          intArg:0
         intArg2:0
           label:nil];
  };
  cv.onOptHideHandle = ^(NSString *label) {
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    [s _fireType:KKJoyrideTriggerTypeMiniViewerOptHide
          intArg:0
         intArg2:0
           label:label];
  };
}

- (void)_installFieldHandlersForOpenPopover {
  KKTimelineLanesView *lanes = _lanes;
  if (!lanes)
    return;
  NSMutableSet<NSString *> *labels = [NSMutableSet set];
  for (_KKJoyrideStepBinding *b in _bindings) {
    KKJoyrideTrigger *t = b.advanceActive;
    while (t) {
      if (t.type == KKJoyrideTriggerTypeConstantFieldEdited && t.label)
        [labels addObject:t.label];
      t = t.next;
    }
    t = b.dismiss;
    while (t) {
      if (t.type == KKJoyrideTriggerTypeConstantFieldEdited && t.label)
        [labels addObject:t.label];
      t = t.next;
    }
  }
  __weak typeof(self) weak = self;
  for (NSString *label in labels) {
    if ([_installedFieldHandlerLabels containsObject:label])
      continue;
    [_installedFieldHandlerLabels addObject:label];
    NSString *capturedLabel = [label copy];
    [lanes setGuideConstantFieldEditHandlerForLabel:label
                                            handler:^(NSInteger comp,
                                                      double disp) {
                                              __strong typeof(weak) s = weak;
                                              if (!s)
                                                return;
                                              // Dispatch checks the
                                              // comp/equals/tolerance match in
                                              // _trigger:matches…
                                              [s _fireFieldEdited:capturedLabel
                                                        component:comp
                                                            value:disp];
                                            }];
  }
}

#pragma mark - Dispatch

- (void)_fireType:(KKJoyrideTriggerType)type
           intArg:(NSInteger)intArg
          intArg2:(NSInteger)intArg2
            label:(NSString *)label {
  KKJoyrideController *guide = _guide;
  if (!guide || !guide.isActive)
    return;
  NSInteger cur = guide.currentStepIndex;
  _KKJoyrideStepBinding *match = nil;
  for (_KKJoyrideStepBinding *b in _bindings) {
    if (b.stepIndex == cur) {
      match = b;
      break;
    }
  }
  if (!match)
    return;
  [self _resetBindingIfNewlyActive:match];

  // playToggleEdge: deterministic, driven by raw taps (notifyPlaybackToggle-
  // Tapped). First tap during the step = started playing; second tap = pause
  // → advance. No play-state inference, so it never flickers under FCP's
  // bursty currentTime mid-guide.
  if (type == KKJoyrideTriggerTypePlayToggleEdge &&
      match.advanceActive.type == KKJoyrideTriggerTypePlayToggleEdge) {
    if (!match.playStarted) {
      match.playStarted = YES;
    } else {
      match.playStarted = NO;
      [self _advanceBinding:match];
    }
    return;
  }

  // Advance match (with thenWaitFor arming).
  if ([self _trigger:match.advanceActive
          matchesType:type
               intArg:intArg
              intArg2:intArg2
                label:label]) {
    if (match.advanceActive.next) {
      match.advanceActive = match.advanceActive.next;
    } else {
      [self _advanceBinding:match];
      return;
    }
  }
  // Dismiss match.
  if ([self _trigger:match.dismiss
          matchesType:type
               intArg:intArg
              intArg2:intArg2
                label:label]) {
    [guide dismiss];
  }
}

- (void)_fireFieldEdited:(NSString *)label
               component:(NSInteger)component
                   value:(double)value {
  KKJoyrideController *guide = _guide;
  if (!guide || !guide.isActive)
    return;
  NSInteger cur = guide.currentStepIndex;
  for (_KKJoyrideStepBinding *b in _bindings) {
    if (b.stepIndex != cur)
      continue;
    [self _resetBindingIfNewlyActive:b];
    KKJoyrideTrigger *t = b.advanceActive;
    if (t && t.type == KKJoyrideTriggerTypeConstantFieldEdited &&
        [t.label isEqualToString:label] && t.intArg == component &&
        fabs(value - t.doubleArg) <= t.doubleArg2) {
      if (t.next) {
        b.advanceActive = t.next;
      } else {
        [self _advanceBinding:b];
      }
      return;
    }
    KKJoyrideTrigger *d = b.dismiss;
    if (d && d.type == KKJoyrideTriggerTypeConstantFieldEdited &&
        [d.label isEqualToString:label] && d.intArg == component &&
        fabs(value - d.doubleArg) <= d.doubleArg2) {
      [guide dismiss];
      return;
    }
  }
}

- (void)_resetBindingIfNewlyActive:(_KKJoyrideStepBinding *)b {
  if (_lastFiredFromStep == b.stepIndex)
    return;
  _lastFiredFromStep = b.stepIndex;
  b.advanceActive = b.advanceOriginal;
  b.playStarted = NO;
  b.activatedAt = CFAbsoluteTimeGetCurrent();
}

- (void)_advanceBinding:(_KKJoyrideStepBinding *)b {
  KKJoyrideController *guide = _guide;
  KKTimelineLanesView *lanes = _lanes;
  [guide advance];
  switch (b.closeOnAdvance) {
  case KKJoyrideCloseOnAdvanceManagePopover: {
    dispatch_async(dispatch_get_main_queue(), ^{
      [lanes closeManagePopover];
    });
    break;
  }
  case KKJoyrideCloseOnAdvanceContentPopover: {
    dispatch_async(dispatch_get_main_queue(), ^{
      [lanes guideCloseContentPopover];
    });
    break;
  }
  case KKJoyrideCloseOnAdvanceNone:
    break;
  }
}

- (BOOL)_trigger:(KKJoyrideTrigger *)t
     matchesType:(KKJoyrideTriggerType)type
          intArg:(NSInteger)intArg
         intArg2:(NSInteger)intArg2
           label:(NSString *)label {
  if (!t)
    return NO;
  if (t.type != type)
    return NO;
  switch (type) {
  case KKJoyrideTriggerTypeLaneOptedIn:
  case KKJoyrideTriggerTypeStaticValueDragEnded:
    if (t.label && ![t.label isEqualToString:label])
      return NO;
    return YES;
  case KKJoyrideTriggerTypeGapPopoverCurveChanged:
  case KKJoyrideTriggerTypeDiamondTapped:
  case KKJoyrideTriggerTypeGapTapped:
  case KKJoyrideTriggerTypeRenderModeChanged:
  case KKJoyrideTriggerTypeMiniViewerSizeChanged:
  case KKJoyrideTriggerTypeDynamicToggled:
  case KKJoyrideTriggerTypeMiniViewerViewTransformChanged:
    if (t.intArg >= 0 && t.intArg != intArg)
      return NO;
    return YES;
  case KKJoyrideTriggerTypePhaseToggled:
    return (t.intArg == intArg) && (t.intArg2 == intArg2);
  // Field-edited handled in _fireFieldEdited:.
  // PlayToggleEdge handled inline in _fireType:.
  default:
    return YES;
  }
}

@end
