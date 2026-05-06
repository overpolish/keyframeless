/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "../../Math/KKTimingStage.h"
#import "../../Style/KKTokens.h"
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

/// Sequencer container height. In capped (inspector) mode the row is
/// reserved at a constant 2.5-lane height regardless of lane count — FCP
/// locks parameter row height at createView time, so dynamic-lane-count
/// plugins (Canvas) need a stable reservation; lanes overflow into the
/// scroll view. In uncapped (window) mode the container fits all lanes
/// exactly (no scroll).
static CGFloat KKSeqContainerHeightForVisible(BOOL uncapped,
                                              NSUInteger visibleCount) {
  CGFloat lanesH;
  if (uncapped) {
    NSUInteger laneCountForHeight = MAX((NSUInteger)1, visibleCount);
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
  // Lane kind/OSC info now lives on each KKTimingLane (valueComponentKinds,
  // hasOSC) — the sequencer view reads them directly.
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
    _readOrSeedLanesWithParamGetAPI:(id<FxParameterRetrievalAPI_v6>)paramGetAPI
                             atTime:(CMTime)time
                      fromPersisted:(BOOL *)fromPersisted {
  if (fromPersisted)
    *fromPersisted = NO;
  NSArray<KKTimingLane *> *lanes =
      KKReadLanesRebalanced(self.apiManager, paramGetAPI);
  if (lanes) {
    if (fromPersisted)
      *fromPersisted = YES;
    // Run plugin reconciliation against current source items (e.g. Canvas:
    // current layer list) so a remount catches up to layer adds/deletes/
    // renames that happened while the inspector was unmounted.
    NSArray<KKTimingLane *> *reconciled = [self reconcileLanes:lanes
                                                        atTime:time
                                                   paramGetAPI:paramGetAPI];
    return reconciled ?: lanes;
  }

  // Real read failed. Prefer in-memory snapshot if we have one (re-mount
  // recovery). Otherwise fall through and build display-only defaults so
  // the sequencer isn't visually empty — but never persist them, since a
  // nil read can mean "scope not wired yet" rather than "no data". A
  // first user edit will eventually persist real JSON.
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  NSArray<KKTimingLane *> *snapshot = state.lanesSnapshot;
  if (snapshot.count > 0) {
    if (fromPersisted)
      *fromPersisted = YES;
    return snapshot;
  }

  return [self defaultLanesAtTime:time paramGetAPI:paramGetAPI];
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
- (void)_seedSequencerWithSeqContainer:(NSView *)seqContainer
                               seqView:(KKStageSequencerView *)seqView
                             rulerView:(KKStageSequencerRulerView *)rulerView
                          playheadView:(KKStagePlayheadView *)playheadView
                           paramGetAPI:
                               (id<FxParameterRetrievalAPI_v6>)paramGetAPI
                             actionAPI:
                                 (id<FxCustomParameterActionAPI_v4>)actionAPI {
  seqContainer.hidden = NO;

  BOOL fromPersisted = NO;
  NSArray<KKTimingLane *> *lanes =
      [self _readOrSeedLanesWithParamGetAPI:paramGetAPI
                                     atTime:[actionAPI currentTime]
                              fromPersisted:&fromPersisted];
  KKPluginInstanceState *instState = KKInstanceStateForAPI(self.apiManager);
  if (lanes) {
    // Only seed `lanesSnapshot` from real persisted data. Cold-scope
    // defaults (radius=0 etc.) must stay display-only — if they reach
    // `lanesSnapshot`, an off-main pump (drawOSC/render tick) can
    // capture the stale lanes in its dispatch_async block and clobber
    // the seqView after `timingGraphApplyState` has corrected it.
    if (fromPersisted)
      instState.lanesSnapshot = [lanes copy];
    NSSet<NSString *> *pluginHidden =
        [self hiddenAnimatablePropertyLabels] ?: [NSSet set];
    NSSet<NSString *> *hidden =
        KKEffectiveHiddenLaneLabels(pluginHidden, lanes);
    instState.hiddenLaneLabels = hidden;
    instState.pluginHiddenLaneLabels = pluginHidden;
    seqView.lanes = KKFilterLanesForVisibility(lanes, hidden);
    KKPushLanesToVisibilityBar(instState.visibilityBar, lanes, pluginHidden);
  }
  // Empty-state apply runs even when `lanes` is nil so dynamic-lane plugins
  // (Canvas with no layers yet) get their no-lanes message at create time
  // — the pump's gated paths only fire once JSON exists.
  KKApplyEmptyLanesVisibility(instState.emptyLanesView, lanes, self);
  for (KKTimingViewRefs *r in instState.additionalTimingViews)
    KKApplyEmptyLanesVisibility(r.emptyLanesView, lanes, self);

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
    state.plugin = self;
    // Push the current selection into the freshly-attached sequencer.
    // The layer-list store seed fires its observer before the sequencer
    // view exists, so that observer's `kkRefreshSequencerSelectedGroup`
    // call no-ops on `state.sequencerView == nil` and the seq starts up
    // with no accent. Re-push here now that the view is attached.
    [self kkRefreshSequencerSelectedGroup];
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
    state.plugin = self;
  }
  [self timingGraphApplyState];
}

- (NSView *)_createTimingGraphViewUncapped:(BOOL)uncapped {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  // Probe current lane count: use persisted lanes if available, otherwise
  // ask the plugin for its default templates so metrics size correctly
  // before the rest of the wiring runs.
  NSArray<KKTimingLane *> *probeLanes =
      KKReadLanesRebalanced(self.apiManager, paramGetAPI);
  if (!probeLanes.count)
    probeLanes = [self defaultLanesAtTime:[actionAPI currentTime]
                              paramGetAPI:paramGetAPI];
  KKTimingGraphMetrics metrics =
      KKTimingGraphMetricsCompute(uncapped, probeLanes.count);

  NSView *wrapper = [[NSView alloc]
      initWithFrame:NSMakeRect(0, 0, 300, metrics.wrapperHeight)];
  wrapper.autoresizingMask = NSViewWidthSizable;

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
                           paramGetAPI:paramGetAPI
                             actionAPI:actionAPI];
  [actionAPI endAction:self];

  return wrapper;
}

@end
