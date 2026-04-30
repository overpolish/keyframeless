/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../../Math/KKTimingStage.h"
#import "../../Style/KKTokens.h"
#import "../../Views/KKAnimatableProperty.h"
#import "../../Views/StageSequencer/KKEmptyLanesView.h"
#import "../../Views/StageSequencer/KKLaneVisibilityBar.h"
#import "../../Views/StageSequencer/KKSequencerScrollView.h"
#import "../../Views/StageSequencer/KKStagePlayheadView.h"
#import "../../Views/StageSequencer/KKStageSequencerRulerView.h"
#import "../../Views/StageSequencer/KKStageSequencerView.h"
#import "../KKPluginInstanceState.h"
#import "../KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>

typedef struct {
  CGFloat fullLanesH;
  CGFloat rulerH;
  CGFloat seqContainerH;
  CGFloat barH;
  CGFloat wrapperHeight;
} KKTimingGraphMetrics;

/// Sequencer container height for the given visible-lane count. In capped
/// (inspector) mode, the container caps at 2.5 lanes worth and scrolls
/// past that. In uncapped (window) mode, lanes always fit (no scroll).
static CGFloat KKSeqContainerHeightForVisible(BOOL uncapped,
                                              NSUInteger visibleCount) {
  // Treat zero-visible as one lane's worth so the empty container has
  // some presence rather than collapsing to ruler-only.
  NSUInteger laneCountForHeight = MAX((NSUInteger)1, visibleCount);
  CGFloat lanesH;
  if (uncapped || visibleCount <= 2) {
    lanesH = [KKStageSequencerView heightForLaneCount:laneCountForHeight];
  } else {
    CGFloat h2 = [KKStageSequencerView heightForLaneCount:2];
    CGFloat h3 = [KKStageSequencerView heightForLaneCount:3];
    lanesH = h2 + (h3 - h2) * 0.5;
  }
  CGFloat rulerH = [KKStageSequencerRulerView preferredHeight];
  return KKPaddingSM + rulerH + lanesH;
}

static KKTimingGraphMetrics KKTimingGraphMetricsCompute(BOOL uncapped,
                                                        NSUInteger propsCount) {
  CGFloat fullLanesH = [KKStageSequencerView heightForLaneCount:propsCount];
  CGFloat rulerH = [KKStageSequencerRulerView preferredHeight];
  CGFloat seqContainerH = KKSeqContainerHeightForVisible(uncapped, propsCount);
  CGFloat barH = [KKLaneVisibilityBar preferredHeight];
  return (KKTimingGraphMetrics){
      .fullLanesH = fullLanesH,
      .rulerH = rulerH,
      .seqContainerH = seqContainerH,
      .barH = barH,
      .wrapperHeight = barH + KKPaddingSM + seqContainerH + KKPaddingLG,
  };
}

@implementation KKPlugin (SequencerBuilder)

/// Stage sequencer container — sticky ruler + vertically-scrolled lanes
/// (capped at 2.5 lanes) with top/bottom shadow overlays. Hidden until
/// multi-stage is enabled. Inspector mode uses fixed height; window (uncapped)
/// mode pins top+bottom so the container stretches with the wrapper.
- (NSView *)_buildSeqContainerInWrapper:(NSView *)wrapper
                              topAnchor:(NSLayoutYAxisAnchor *)topAnchor
                               topInset:(CGFloat)topInset
                               uncapped:(BOOL)uncapped
                          seqContainerH:(CGFloat)seqContainerH {
  NSView *seqContainer = [[NSView alloc] initWithFrame:NSZeroRect];
  seqContainer.translatesAutoresizingMaskIntoConstraints = NO;
  seqContainer.wantsLayer = YES;
  seqContainer.layer.masksToBounds = YES;
  seqContainer.layer.cornerRadius = KKSpacingMD;
  seqContainer.layer.backgroundColor =
      [NSColor colorWithWhite:0.15 alpha:1.0].CGColor;
  seqContainer.layer.borderWidth = KKBorderWidthXS;
  seqContainer.layer.borderColor =
      [NSColor colorWithWhite:1.0 alpha:0.05].CGColor;
  seqContainer.hidden = YES;
  [wrapper addSubview:seqContainer];

  NSMutableArray<NSLayoutConstraint *> *anchors =
      [NSMutableArray arrayWithArray:@[
        [seqContainer.leadingAnchor
            constraintEqualToAnchor:wrapper.leadingAnchor
                           constant:KKInspectorHorizontalInset],
        [seqContainer.trailingAnchor
            constraintEqualToAnchor:wrapper.trailingAnchor
                           constant:-KKInspectorHorizontalInset],
        [seqContainer.topAnchor constraintEqualToAnchor:topAnchor
                                               constant:topInset],
      ]];
  if (uncapped) {
    [anchors addObject:[seqContainer.bottomAnchor
                           constraintEqualToAnchor:wrapper.bottomAnchor
                                          constant:-KKPaddingLG]];
  } else {
    [anchors addObject:[seqContainer.heightAnchor
                           constraintEqualToConstant:seqContainerH]];
  }
  [NSLayoutConstraint activateConstraints:anchors];
  return seqContainer;
}

- (KKStageSequencerRulerView *)_buildSeqRulerInContainer:(NSView *)seqContainer
                                             rulerHeight:(CGFloat)rulerH {
  KKStageSequencerRulerView *rulerView =
      [[KKStageSequencerRulerView alloc] initWithFrame:NSZeroRect];
  rulerView.translatesAutoresizingMaskIntoConstraints = NO;
  [seqContainer addSubview:rulerView];
  [NSLayoutConstraint activateConstraints:@[
    [rulerView.leadingAnchor
        constraintEqualToAnchor:seqContainer.leadingAnchor],
    [rulerView.trailingAnchor
        constraintEqualToAnchor:seqContainer.trailingAnchor],
    [rulerView.topAnchor constraintEqualToAnchor:seqContainer.topAnchor
                                        constant:KKPaddingSM],
    [rulerView.heightAnchor constraintEqualToConstant:rulerH],
  ]];
  return rulerView;
}

- (void)_buildSeqScrollViewInContainer:(NSView *)seqContainer
                            underRuler:(KKStageSequencerRulerView *)rulerView
                              uncapped:(BOOL)uncapped
                              seqProps:
                                  (NSArray<KKAnimatableProperty *> *)seqProps
                            fullLanesH:(CGFloat)fullLanesH
                            outSeqView:(KKStageSequencerView **)outSeqView
                          outEmptyView:(KKEmptyLanesView **)outEmptyView {
  NSScrollView *scrollView =
      [[KKSequencerScrollView alloc] initWithFrame:NSZeroRect];
  scrollView.translatesAutoresizingMaskIntoConstraints = NO;
  scrollView.hasVerticalScroller = YES;
  scrollView.hasHorizontalScroller = NO;
  scrollView.autohidesScrollers = YES;
  scrollView.drawsBackground = YES;
  scrollView.backgroundColor = [NSColor colorWithWhite:0.15 alpha:1.0];
  scrollView.borderType = NSNoBorder;
  scrollView.wantsLayer = YES;
  scrollView.layer.cornerRadius = KKSpacingMD;
  scrollView.layer.masksToBounds = YES;
  scrollView.contentView.postsBoundsChangedNotifications = YES;

  KKStageSequencerView *seqView = [[KKStageSequencerView alloc]
      initWithFrame:NSMakeRect(0, 0, 300, fullLanesH)];
  seqView.translatesAutoresizingMaskIntoConstraints = NO;
  // Let the renderer differentiate color/gradient lanes (which should render
  // as a value strip + single easing curve) from scalar lanes. Color and
  // gradient props each have exactly one entry in `valueParamKinds`, so the
  // first entry is representative.
  NSMutableDictionary<NSString *, NSNumber *> *laneKinds =
      [NSMutableDictionary dictionaryWithCapacity:seqProps.count];
  NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *laneCompKinds =
      [NSMutableDictionary dictionaryWithCapacity:seqProps.count];
  for (KKAnimatableProperty *p in seqProps) {
    NSNumber *kind = p.valueParamKinds.firstObject;
    if (kind)
      laneKinds[p.label] = kind;
    NSMutableArray<NSNumber *> *expanded = [NSMutableArray array];
    for (NSNumber *k in p.valueParamKinds) {
      KKAnimatableParamKind kk = (KKAnimatableParamKind)k.integerValue;
      NSUInteger n = 1;
      switch (kk) {
      case KKAnimatableParamKindColor:
        n = 3;
        break;
      case KKAnimatableParamKindPoint:
        n = 2;
        break;
      case KKAnimatableParamKindGradient:
        n = 0;
        break;
      default:
        n = 1;
        break;
      }
      for (NSUInteger i = 0; i < n; i++)
        [expanded addObject:k];
    }
    if (expanded.count)
      laneCompKinds[p.label] = expanded;
  }
  seqView.laneKindsByLabel = laneKinds;
  seqView.laneComponentKindsByLabel = laneCompKinds;
  seqView.laneLabelsWithOSC = [self animatablePropertyLabelsWithOSC];
  scrollView.documentView = seqView;
  [seqContainer addSubview:scrollView];

  // Pin the document view to the clip view's width so segments never overflow
  // past the visible area. A low-priority bottom-pin lets the sequencer grow
  // with the clip view so lanes stretch vertically when there's spare room
  // (few visible lanes), while still allowing intrinsic-content-size to push
  // past the clip view and scroll when there are too many.
  NSMutableArray<NSLayoutConstraint *> *seqViewConstraints =
      [NSMutableArray arrayWithArray:@[
        [seqView.widthAnchor
            constraintEqualToAnchor:scrollView.contentView.widthAnchor],
        [seqView.topAnchor
            constraintEqualToAnchor:scrollView.contentView.topAnchor],
        [seqView.leadingAnchor
            constraintEqualToAnchor:scrollView.contentView.leadingAnchor],
      ]];
  [seqView setContentHuggingPriority:NSLayoutPriorityDefaultLow - 1
                      forOrientation:NSLayoutConstraintOrientationVertical];
  NSLayoutConstraint *bottomFill = [seqView.bottomAnchor
      constraintEqualToAnchor:scrollView.contentView.bottomAnchor];
  bottomFill.priority = NSLayoutPriorityDefaultLow;
  [seqViewConstraints addObject:bottomFill];
  [NSLayoutConstraint activateConstraints:seqViewConstraints];

  [NSLayoutConstraint activateConstraints:@[
    [scrollView.leadingAnchor
        constraintEqualToAnchor:seqContainer.leadingAnchor],
    [scrollView.trailingAnchor
        constraintEqualToAnchor:seqContainer.trailingAnchor],
    [scrollView.topAnchor constraintEqualToAnchor:rulerView.bottomAnchor],
    [scrollView.bottomAnchor constraintEqualToAnchor:seqContainer.bottomAnchor],
  ]];

  KKEmptyLanesView *emptyView = [[KKEmptyLanesView alloc] init];
  emptyView.hidden = YES;
  [seqContainer addSubview:emptyView
                positioned:NSWindowAbove
                relativeTo:scrollView];
  [NSLayoutConstraint activateConstraints:@[
    [emptyView.leadingAnchor constraintEqualToAnchor:scrollView.leadingAnchor],
    [emptyView.trailingAnchor
        constraintEqualToAnchor:scrollView.trailingAnchor],
    [emptyView.topAnchor constraintEqualToAnchor:scrollView.topAnchor],
    [emptyView.bottomAnchor constraintEqualToAnchor:scrollView.bottomAnchor],
  ]];

  *outSeqView = seqView;
  if (outEmptyView)
    *outEmptyView = emptyView;
}

- (KKStagePlayheadView *)_buildSeqPlayheadInContainer:(NSView *)seqContainer
                                          rulerHeight:(CGFloat)rulerH {
  KKStagePlayheadView *playheadView =
      [[KKStagePlayheadView alloc] initWithFrame:NSZeroRect];
  playheadView.translatesAutoresizingMaskIntoConstraints = NO;
  playheadView.rulerHeight = rulerH;
  playheadView.topPadding = KKPaddingSM;
  [seqContainer addSubview:playheadView];
  [NSLayoutConstraint activateConstraints:@[
    [playheadView.leadingAnchor
        constraintEqualToAnchor:seqContainer.leadingAnchor],
    [playheadView.trailingAnchor
        constraintEqualToAnchor:seqContainer.trailingAnchor],
    [playheadView.topAnchor constraintEqualToAnchor:seqContainer.topAnchor],
    [playheadView.bottomAnchor
        constraintEqualToAnchor:seqContainer.bottomAnchor],
  ]];
  return playheadView;
}

/// Reads persisted lanes; if none, seeds defaults from each property's
/// current value and writes them back. Returns rebalanced lanes or nil.
- (NSArray<KKTimingLane *> *)
    _readOrSeedLanesForProps:(NSArray<KKAnimatableProperty *> *)seqProps
                 paramGetAPI:(id<FxParameterRetrievalAPI_v6>)paramGetAPI
                      atTime:(CMTime)time {
  NSArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, paramGetAPI);
  if (lanes || seqProps.count == 0)
    return lanes;

  // Real read failed. Prefer in-memory snapshot if we have one (re-mount
  // recovery). Otherwise fall through and build display-only defaults so
  // the sequencer isn't visually empty — but never persist them, since a
  // nil read can mean "scope not wired yet" rather than "no data". A
  // first user edit will eventually persist real JSON.
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  NSArray<KKTimingLane *> *snapshot = state.lanesSnapshot;
  if (snapshot.count > 0)
    return snapshot;

  return [self _buildDefaultLanesForProps:seqProps
                              paramGetAPI:paramGetAPI
                                   atTime:time];
}

- (NSArray<KKTimingLane *> *)
    _buildDefaultLanesForProps:(NSArray<KKAnimatableProperty *> *)seqProps
                   paramGetAPI:(id<FxParameterRetrievalAPI_v6>)paramGetAPI
                        atTime:(CMTime)time {
  NSSet<NSString *> *oscOffByDefault =
      [self animatablePropertyLabelsWithOSCDefaultOff];
  NSMutableArray<KKTimingLane *> *defaults =
      [NSMutableArray arrayWithCapacity:seqProps.count];
  for (KKAnimatableProperty *prop in seqProps) {
    NSArray<NSNumber *> *baseVals = [prop readValuesWithGetAPI:paramGetAPI
                                                        atTime:time];
    if (!baseVals.count)
      baseVals = @[ @(1.0) ];
    KKTimingLane *lane = [KKTimingLane defaultLaneForLabel:prop.label
                                                baseValues:baseVals];
    if ([oscOffByDefault containsObject:prop.label])
      lane.oscVisible = NO;
    [defaults addObject:lane];
  }
  return defaults;
}

- (void)_seedPlayheadForSeqView:(KKStageSequencerView *)seqView
                      rulerView:(KKStageSequencerRulerView *)rulerView
                   playheadView:(KKStagePlayheadView *)playheadView
                         atTime:(CMTime)nowTime {
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  if (!timingAPI)
    return;
  CMTime effectStart = kCMTimeZero, effectDuration = kCMTimeZero;
  [timingAPI startTimeForEffect:&effectStart];
  [timingAPI durationTimeForEffect:&effectDuration];
  double durSec = CMTimeGetSeconds(effectDuration);
  seqView.effectDuration = durSec;
  rulerView.effectDuration = durSec;
  if (durSec > 0) {
    double startSec = CMTimeGetSeconds(effectStart);
    double nowSec = CMTimeGetSeconds(nowTime);
    double frac = (nowSec - startSec) / durSec;
    seqView.playheadFraction = frac;
    playheadView.playheadFraction = frac;
  }
}

/// Seeds lane data (creating defaults if missing) and syncs the playhead.
- (void)
    _seedSequencerWithSeqContainer:(NSView *)seqContainer
                           seqView:(KKStageSequencerView *)seqView
                         rulerView:(KKStageSequencerRulerView *)rulerView
                      playheadView:(KKStagePlayheadView *)playheadView
                          seqProps:(NSArray<KKAnimatableProperty *> *)seqProps
                       paramGetAPI:(id<FxParameterRetrievalAPI_v6>)paramGetAPI
                         actionAPI:
                             (id<FxCustomParameterActionAPI_v4>)actionAPI {
  seqContainer.hidden = NO;

  NSArray<KKTimingLane *> *lanes =
      [self _readOrSeedLanesForProps:seqProps
                         paramGetAPI:paramGetAPI
                              atTime:[actionAPI currentTime]];
  if (lanes) {
    KKPluginInstanceState *instState = KKInstanceStateForAPI(self.apiManager);
    instState.lanesSnapshot = [lanes copy];
    NSSet<NSString *> *pluginHidden =
        [self hiddenAnimatablePropertyLabels] ?: [NSSet set];
    NSSet<NSString *> *hidden =
        KKEffectiveHiddenLaneLabels(pluginHidden, lanes);
    instState.hiddenLaneLabels = hidden;
    instState.pluginHiddenLaneLabels = pluginHidden;
    seqView.lanes = KKFilterLanesForVisibility(lanes, hidden);
    KKPushLanesToVisibilityBar(instState.visibilityBar, lanes, pluginHidden);
    KKApplyEmptyLanesVisibility(instState.emptyLanesView, lanes);
    for (KKTimingViewRefs *r in instState.additionalTimingViews) {
      KKPushLanesToVisibilityBar(r.visibilityBar, lanes, pluginHidden);
      KKApplyEmptyLanesVisibility(r.emptyLanesView, lanes);
    }
  }

  // FCP often can't deliver the real persisted JSON during the initial
  // create-view scope. Schedule a deferred re-apply on the next runloop
  // tick — by then FCP has wired the action scope and the read returns
  // the actual data, replacing the displayed defaults without needing
  // user interaction. Safe in Motion: if the read still fails, the
  // snapshot fallback inside KKReadLanesRebalanced makes it a no-op.
  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    [weakSelf timingGraphApplyState];
  });

  [self _seedPlayheadForSeqView:seqView
                      rulerView:rulerView
                   playheadView:playheadView
                         atTime:[actionAPI currentTime]];
}

/// In inspector (capped) mode, the primary views are stored on the plugin
/// so callbacks can find them. In uncapped (window) mode they're added to
/// per-instance state as an additional ref set, and we push current state
/// through so the window opens already in sync.
- (void)_registerSequencerViewsForUncapped:(BOOL)uncapped
                              seqContainer:(NSView *)seqContainer
                                   seqView:(KKStageSequencerView *)seqView
                                 rulerView:
                                     (KKStageSequencerRulerView *)rulerView
                              playheadView:(KKStagePlayheadView *)playheadView
                             visibilityBar:(KKLaneVisibilityBar *)visibilityBar
                                 emptyView:(KKEmptyLanesView *)emptyView {
  if (!uncapped) {
    self.stageSequencer = seqView;
    self.stageSequencerContainer = seqContainer;
    self.stageSequencerRuler = rulerView;
    [self _registerMultiStageSequencerView:seqView
                                 rulerView:rulerView
                              playheadView:playheadView];
    KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
    state.visibilityBar = visibilityBar;
    state.emptyLanesView = emptyView;
    return;
  }
  KKTimingViewRefs *refs = [[KKTimingViewRefs alloc] init];
  refs.seqView = seqView;
  refs.seqContainer = seqContainer;
  refs.ruler = rulerView;
  refs.playhead = playheadView;
  refs.visibilityBar = visibilityBar;
  refs.emptyLanesView = emptyView;
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  if (state) {
    if (!state.additionalTimingViews)
      state.additionalTimingViews = [NSMutableArray array];
    [state.additionalTimingViews addObject:refs];
  }
  [self timingGraphApplyState];
}

- (NSView *)_createTimingGraphViewUncapped:(BOOL)uncapped {
  NSArray<KKAnimatableProperty *> *seqProps = [self animatableProperties];
  KKTimingGraphMetrics metrics =
      KKTimingGraphMetricsCompute(uncapped, seqProps.count);

  NSView *wrapper = [[NSView alloc]
      initWithFrame:NSMakeRect(0, 0, 300, metrics.wrapperHeight)];
  wrapper.autoresizingMask = NSViewWidthSizable;

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];

  KKLaneVisibilityBar *visibilityBar = [[KKLaneVisibilityBar alloc] init];
  visibilityBar.translatesAutoresizingMaskIntoConstraints = NO;
  [wrapper addSubview:visibilityBar];
  [NSLayoutConstraint activateConstraints:@[
    [visibilityBar.leadingAnchor
        constraintEqualToAnchor:wrapper.leadingAnchor
                       constant:KKInspectorHorizontalInset],
    [visibilityBar.trailingAnchor
        constraintEqualToAnchor:wrapper.trailingAnchor
                       constant:-KKInspectorHorizontalInset],
    [visibilityBar.topAnchor constraintEqualToAnchor:wrapper.topAnchor],
    [visibilityBar.heightAnchor constraintEqualToConstant:metrics.barH],
  ]];

  NSView *seqContainer =
      [self _buildSeqContainerInWrapper:wrapper
                              topAnchor:visibilityBar.bottomAnchor
                               topInset:KKPaddingSM
                               uncapped:uncapped
                          seqContainerH:metrics.seqContainerH];
  KKStageSequencerRulerView *rulerView =
      [self _buildSeqRulerInContainer:seqContainer rulerHeight:metrics.rulerH];
  KKStageSequencerView *seqView = nil;
  KKEmptyLanesView *emptyView = nil;
  [self _buildSeqScrollViewInContainer:seqContainer
                            underRuler:rulerView
                              uncapped:uncapped
                              seqProps:seqProps
                            fullLanesH:metrics.fullLanesH
                            outSeqView:&seqView
                          outEmptyView:&emptyView];
  KKStagePlayheadView *playheadView =
      [self _buildSeqPlayheadInContainer:seqContainer
                             rulerHeight:metrics.rulerH];

  [self _registerSequencerViewsForUncapped:uncapped
                              seqContainer:seqContainer
                                   seqView:seqView
                                 rulerView:rulerView
                              playheadView:playheadView
                             visibilityBar:visibilityBar
                                 emptyView:emptyView];

  __weak typeof(self) weakSelf = self;
  visibilityBar.onPillClicked = ^(NSInteger laneIndex, BOOL optionDown) {
    [weakSelf _handleLaneVisibilityClickedAtIndex:laneIndex
                                       optionDown:optionDown];
  };
  visibilityBar.onPillDraggedToVisible = ^(NSInteger laneIndex, BOOL visible) {
    [weakSelf _handleLaneVisibilitySetAtIndex:laneIndex visible:visible];
  };

  [self _wireStageSequencerCallbacksFor:seqView
                              rulerView:rulerView
                           playheadView:playheadView];

  [actionAPI startAction:self];
  [self _seedSequencerWithSeqContainer:seqContainer
                               seqView:seqView
                             rulerView:rulerView
                          playheadView:playheadView
                              seqProps:seqProps
                           paramGetAPI:paramGetAPI
                             actionAPI:actionAPI];
  [actionAPI endAction:self];

  return wrapper;
}

@end
