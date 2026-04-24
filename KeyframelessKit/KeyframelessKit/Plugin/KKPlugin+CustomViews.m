/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../KKLog.h"
#import "../Math/KKEasing.h"
#import "../Math/KKTimingStage.h"
#import "../Style/KKTokens.h"
#import "../Views/KKAlertView.h"
#import "../Views/KKCustomGroupHeaderView.h"
#import "../Views/KKSegmentEditView.h"
#import "../Views/KKSeparatorView.h"
#import "../Views/StageSequencer/KKRemoteWindowKeyHandlerView.h"
#import "../Views/StageSequencer/KKSequencerScrollView.h"
#import "../Views/StageSequencer/KKStagePlayheadView.h"
#import "../Views/StageSequencer/KKStageSequencerRulerView.h"
#import "../Views/StageSequencer/KKStageSequencerView.h"
#import "KKPlugin+Color.h"

#import "../Views/KKAnimatableProperty.h"
#import "../Views/KKPillToggleRowView.h"
#import "../Views/KKTimingGraphView.h"
#import "../Views/KKTimingSlot.h"
#import "../Views/KKUpdateBannerView.h"
#import "KKConstants.h"
#import "KKPluginInstanceState.h"
#import "KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>
#import <QuartzCore/QuartzCore.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKPlugin (CustomViews)

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kKKParamUpdateBanner)
    return [[KKUpdateBannerView alloc] init];

  if (parameterID == kKKParamColorGroup)
    return [self
        createGroupHeaderWithTitle:@"Color Style"
                              icon:[NSImage
                                       imageWithSystemSymbolName:@"paintpalette"
                                        accessibilityDescription:nil]
                       parameterID:parameterID
                   expandedParamID:kKKParamColorExpanded];

  if (parameterID == kKKParamColorCustomUI)
    return [self _createColorCustomUI:parameterID];

  if (parameterID == kKKParamAnimationSeparator)
    return [self _createTimingHeader:parameterID];

  if (parameterID == kKKParamTimingCurvePreview)
    return [self _createTimingGraphViewUncapped:NO];

  NSString *separatorText =
      kkClassRegistry([self class], kKKSepTexts)[@(parameterID)];
  if (separatorText) {
    return [[KKSeparatorView alloc]
        initWithText:(separatorText.length > 0 ? separatorText : nil)
                icon:kkClassRegistry([self class],
                                     kKKSepIcons)[@(parameterID)]];
  }

  NSAttributedString *attributedText =
      kkClassRegistry([self class], kKKInfoAttrTexts)[@(parameterID)];
  if (attributedText) {
    KKAlertView *infoView =
        [[KKAlertView alloc] initWithAttributedText:attributedText];
    infoView.icon = kkClassRegistry([self class], kKKInfoIcons)[@(parameterID)];
    return infoView;
  }

  NSString *text = kkClassRegistry([self class], kKKInfoTexts)[@(parameterID)];
  if (!text)
    return nil;

  KKAlertView *infoView = [[KKAlertView alloc] initWithText:text];
  infoView.icon = kkClassRegistry([self class], kKKInfoIcons)[@(parameterID)];
  return infoView;
}

- (NSView *)createGroupHeaderWithTitle:(NSString *)title
                                  icon:(nullable NSImage *)icon
                           parameterID:(UInt32)parameterID
                       expandedParamID:(UInt32)expandedParamID
    NS_RETURNS_RETAINED {
  KKCustomGroupHeaderView *header =
      [[KKCustomGroupHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 300, 26)
                                          apiManager:self.apiManager
                                         parameterId:parameterID
                                                text:title
                                                icon:icon
                                       showsCheckbox:NO];

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];

  BOOL expanded = NO;
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  [paramGetAPI getBoolValue:&expanded
              fromParameter:expandedParamID
                     atTime:[actionAPI currentTime]];
  header.isExpanded = expanded;
  header.isEnabled = YES;

  [actionAPI endAction:self];

  __weak typeof(self) weakSelf = self;
  header.onExpandedChanged = ^(BOOL isExpanded) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI startAction:strongSelf];
    id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    [setAPI setBoolValue:isExpanded
             toParameter:expandedParamID
                  atTime:[actAPI currentTime]];
    [actAPI endAction:strongSelf];
  };

  return header;
}

- (NSView *)_createTimingHeader:(UInt32)parameterID {
  NSImage *icon = [NSImage imageWithSystemSymbolName:@"timer"
                            accessibilityDescription:nil];
  KKCustomGroupHeaderView *header =
      [[KKCustomGroupHeaderView alloc] initWithFrame:NSMakeRect(0, 0, 300, 26)
                                          apiManager:self.apiManager
                                         parameterId:parameterID
                                                text:@"Timing"
                                                icon:icon
                                       showsCheckbox:NO];
  header.isEnabled = YES;

  __weak typeof(self) weakSelf = self;
  header.onExpandedChanged = ^(BOOL isExpanded) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI startAction:strongSelf];
    id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    [setAPI setBoolValue:isExpanded
             toParameter:kKKParamTimingExpanded
                  atTime:[actAPI currentTime]];
    [actAPI endAction:strongSelf];
  };

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];

  static pid_t sInitializedPID = 0;
  pid_t currentPID = getpid();
  BOOL isNewProcess = (sInitializedPID != currentPID);
  if (isNewProcess)
    sInitializedPID = currentPID;

  BOOL expanded;
  if (isNewProcess) {
    expanded = YES;
    id<FxParameterSettingAPI_v5> setAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    [setAPI setBoolValue:YES
             toParameter:kKKParamTimingExpanded
                  atTime:[actionAPI currentTime]];
  } else {
    expanded = NO;
    id<FxParameterRetrievalAPI_v6> paramGetAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    [paramGetAPI getBoolValue:&expanded
                fromParameter:kKKParamTimingExpanded
                       atTime:[actionAPI currentTime]];
  }
  header.isExpanded = expanded;
  [actionAPI endAction:self];

  NSImage *windowIcon =
      [NSImage imageWithSystemSymbolName:@"macwindow.on.rectangle"
                accessibilityDescription:@"Open in window"];
  __weak typeof(self) weakSelfForWindow = self;
  [header addTrailingButtonWithIcon:windowIcon
                             action:^{
                               [weakSelfForWindow _openTimingRemoteWindow];
                             }];

  self.timingHeader = header;
  return header;
}

- (void)_openTimingRemoteWindow {
  static KKLog *sLog;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    sLog = [KKLog loggerForPlugin:@"co.overpolish.keyframeless.Timing"];
  });

  [sLog info:@"_openTimingRemoteWindow invoked"];

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];

  id<FxRemoteWindowAPI> windowAPI =
      [self.apiManager apiForProtocol:@protocol(FxRemoteWindowAPI)];
  if (!windowAPI) {
    [sLog error:@"FxRemoteWindowAPI unavailable (apiManager=%@)",
                self.apiManager];
    [actionAPI endAction:self];
    return;
  }
  [sLog info:@"got windowAPI=%@", windowAPI];

  NSArray<KKAnimatableProperty *> *seqProps = [self animatableProperties];
  CGFloat lanesH = [KKStageSequencerView heightForLaneCount:seqProps.count];
  CGFloat rulerH = [KKStageSequencerRulerView preferredHeight];
  CGFloat contentH = KKPaddingSM + rulerH + lanesH + KKPaddingLG;
  CGSize contentSize = CGSizeMake(300.0, contentH);

  __weak typeof(self) weakSelf = self;
  [windowAPI
      remoteWindowOfSize:contentSize
                   reply:^(FxXPView *parentView, NSError *error) {
                     __strong typeof(weakSelf) strongSelf = weakSelf;
                     if (!strongSelf || !parentView) {
                       if (error)
                         [sLog error:@"remoteWindow error: %@", error];
                       return;
                     }
                     // The host hands us a parent view positioned at
                     // a non-zero origin within its superview; adding
                     // content to it causes right-clipping and a
                     // first-render offset. Attach to the superview
                     // (the XPC jail) which is correctly sized.
                     NSView *host = parentView.superview ?: parentView;
                     KKRemoteWindowKeyHandlerView *keyHandler =
                         [[KKRemoteWindowKeyHandlerView alloc]
                             initWithFrame:NSZeroRect];
                     keyHandler.translatesAutoresizingMaskIntoConstraints = NO;
                     __weak typeof(strongSelf) weakForKey = strongSelf;
                     keyHandler.onTogglePlayback = ^{
                       __strong typeof(weakForKey) s = weakForKey;
                       if (!s)
                         return;
                       // FxCommandAPI resolves to nil outside an action scope.
                       id<FxCustomParameterActionAPI_v4> actionAPI =
                           [s.apiManager
                               apiForProtocol:
                                   @protocol(FxCustomParameterActionAPI_v4)];
                       if (!actionAPI)
                         return;
                       [actionAPI startAction:s];
                       id<FxCommandAPI_v2> cmd = [s.apiManager
                           apiForProtocol:@protocol(FxCommandAPI_v2)];
                       [cmd performCommand:kFxCommand_TogglePlayback error:nil];
                       [actionAPI endAction:s];
                     };
                     [host addSubview:keyHandler];
                     [NSLayoutConstraint activateConstraints:@[
                       [keyHandler.leadingAnchor
                           constraintEqualToAnchor:host.leadingAnchor],
                       [keyHandler.trailingAnchor
                           constraintEqualToAnchor:host.trailingAnchor],
                       [keyHandler.topAnchor
                           constraintEqualToAnchor:host.topAnchor],
                       [keyHandler.bottomAnchor
                           constraintEqualToAnchor:host.bottomAnchor],
                     ]];

                     NSView *graph =
                         [strongSelf _createTimingGraphViewUncapped:YES];
                     graph.translatesAutoresizingMaskIntoConstraints = NO;
                     [keyHandler addSubview:graph];
                     [NSLayoutConstraint activateConstraints:@[
                       [graph.leadingAnchor
                           constraintEqualToAnchor:keyHandler.leadingAnchor],
                       [graph.trailingAnchor
                           constraintEqualToAnchor:keyHandler.trailingAnchor],
                       [graph.topAnchor
                           constraintEqualToAnchor:keyHandler.topAnchor],
                       [graph.bottomAnchor
                           constraintEqualToAnchor:keyHandler.bottomAnchor],
                     ]];
                   }];

  [actionAPI endAction:self];
}

/// Returns the per-section param ID for a property given the graph's
/// selected section (In/Out/Hold).
static UInt32 KKHoldPropertyParamID(KKAnimatableProperty *prop,
                                    KKTimingGraphSection section) {
  switch (section) {
  case KKTimingGraphSectionIn:
    return prop.inParamID;
  case KKTimingGraphSectionOut:
    return prop.outParamID;
  default:
    return prop.holdParamID;
  }
}

- (void)_installHoldPropertyViewOnGraph:(KKTimingGraphView *)graphView {
  NSArray<KKAnimatableProperty *> *animProps = [self animatableProperties];
  if (animProps.count == 0) {
    NSView *holdPropView = [self holdPropertyView];
    if (holdPropView) {
      graphView.holdPropertyView = holdPropView;
      graphView.holdPropertyViewHeight = [self holdPropertyViewHeight];
      graphView.holdPropertyApplyState = [self holdPropertyApplyState];
    }
    return;
  }

  static const CGFloat kRowH = 18.0;
  BOOL twoRows = animProps.count > 5;
  NSUInteger splitAt = twoRows ? (animProps.count + 1) / 2 : animProps.count;

  KKPillToggleRowView *row1 = nil;
  KKPillToggleRowView *row2 = nil;
  CGFloat totalH = 0;
  NSView *propView = [self _buildHoldPropertyRowsForProps:animProps
                                                  splitAt:splitAt
                                                  twoRows:twoRows
                                                     rowH:kRowH
                                                  outRow1:&row1
                                                  outRow2:&row2
                                                outTotalH:&totalH];

  __weak typeof(self) weakSelf = self;
  __weak KKTimingGraphView *weakGraph = graphView;

  void (^handleToggle)(NSInteger, BOOL) = ^(NSInteger index, BOOL isOn) {
    [weakSelf _handleHoldPropertyToggleAtIndex:index
                                          isOn:isOn
                                         props:animProps
                                         graph:weakGraph];
  };
  row1.onToggled = ^(NSInteger index, BOOL isOn) {
    handleToggle(index, isOn);
  };
  if (row2) {
    row2.onToggled = ^(NSInteger index, BOOL isOn) {
      handleToggle(index + (NSInteger)splitAt, isOn);
    };
  }

  graphView.holdPropertyView = propView;
  graphView.holdPropertyViewHeight = totalH;
  graphView.showPropertyViewForAllSections = YES;
  graphView.holdPropertyApplyState = ^(id paramAPI, CMTime time) {
    KKTimingGraphView *graph = weakGraph;
    if (!graph)
      return;
    for (NSUInteger i = 0; i < animProps.count; i++) {
      UInt32 paramID =
          KKHoldPropertyParamID(animProps[i], graph.selectedSection);
      BOOL val = YES;
      [paramAPI getBoolValue:&val fromParameter:paramID atTime:time];
      if (i < splitAt)
        [row1 setState:val atIndex:i];
      else
        [row2 setState:val atIndex:i - splitAt];
    }
  };
}

- (NSView *)_buildHoldPropertyRowsForProps:
                (NSArray<KKAnimatableProperty *> *)animProps
                                   splitAt:(NSUInteger)splitAt
                                   twoRows:(BOOL)twoRows
                                      rowH:(CGFloat)kRowH
                                   outRow1:(KKPillToggleRowView **)outRow1
                                   outRow2:(KKPillToggleRowView **)outRow2
                                 outTotalH:(CGFloat *)outTotalH {
  NSMutableArray<NSString *> *labels = [NSMutableArray new];
  for (KKAnimatableProperty *p in animProps)
    [labels addObject:p.label];

  if (!twoRows) {
    KKPillToggleRowView *row =
        [[KKPillToggleRowView alloc] initWithLabels:labels];
    *outRow1 = row;
    *outRow2 = nil;
    *outTotalH = kRowH;
    return row;
  }

  NSArray *labels1 = [labels subarrayWithRange:NSMakeRange(0, splitAt)];
  NSArray *labels2 = [labels
      subarrayWithRange:NSMakeRange(splitAt, animProps.count - splitAt)];
  KKPillToggleRowView *row1 =
      [[KKPillToggleRowView alloc] initWithLabels:labels1];
  KKPillToggleRowView *row2 =
      [[KKPillToggleRowView alloc] initWithLabels:labels2];
  row1.autoresizingMask = NSViewWidthSizable;
  row2.autoresizingMask = NSViewWidthSizable;
  CGFloat totalH = kRowH * 2 + KKSpacingXS;
  NSView *container =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, totalH)];
  row1.frame = NSMakeRect(0, 0, 300, kRowH);
  row2.frame = NSMakeRect(0, kRowH + KKSpacingXS, 300, kRowH);
  [container addSubview:row1];
  [container addSubview:row2];
  *outRow1 = row1;
  *outRow2 = row2;
  *outTotalH = totalH;
  return container;
}

- (void)_handleHoldPropertyToggleAtIndex:(NSInteger)index
                                    isOn:(BOOL)isOn
                                   props:
                                       (NSArray<KKAnimatableProperty *> *)props
                                   graph:(KKTimingGraphView *)graph {
  if (!graph || (NSUInteger)index >= props.count)
    return;
  UInt32 paramID = KKHoldPropertyParamID(props[index], graph.selectedSection);
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  [setAPI setBoolValue:isOn toParameter:paramID atTime:[actAPI currentTime]];
  [actAPI endAction:self];
}

- (void)_wireTimingGraphCallbacks:(KKTimingGraphView *)graphView {
  __weak typeof(self) weakSelf = self;
  graphView.onInToggled = ^(BOOL enabled) {
    [weakSelf _timingGraphSetAnimateEnabled:enabled
                               forParameter:kKKParamAnimateIn
                            disabledSection:KKTimingGraphSectionIn];
  };
  graphView.onOutToggled = ^(BOOL enabled) {
    [weakSelf _timingGraphSetAnimateEnabled:enabled
                               forParameter:kKKParamAnimateOut
                            disabledSection:KKTimingGraphSectionOut];
  };
  graphView.onSectionSelected = ^(KKTimingGraphSection section) {
    [weakSelf timingGraphSelectSection:section];
  };
  graphView.onInDurationChanged = ^(double duration) {
    [weakSelf timingGraphSetFloatValue:duration
                          forParameter:kKKParamAnimateInDuration];
  };
  graphView.onOutDurationChanged = ^(double duration) {
    [weakSelf timingGraphSetFloatValue:duration
                          forParameter:kKKParamAnimateOutDuration];
  };
  graphView.onInCurveChanged = ^(KKEasingCurve curve) {
    [weakSelf timingGraphSetIntValue:(int)curve
                        forParameter:kKKParamAnimateInInterpolation];
  };
  graphView.onOutCurveChanged = ^(KKEasingCurve curve) {
    [weakSelf timingGraphSetIntValue:(int)curve
                        forParameter:kKKParamAnimateOutInterpolation];
  };
  graphView.onHoldEffectChanged = ^(KKHoldEffect effect) {
    [weakSelf timingGraphSetIntValue:(int)effect
                        forParameter:kKKParamHoldEffect];
  };
  graphView.onInIntensityChanged = ^(double intensity) {
    [weakSelf timingGraphSetFloatValue:intensity
                          forParameter:kKKParamAnimateInIntensity];
  };
  graphView.onOutIntensityChanged = ^(double intensity) {
    [weakSelf timingGraphSetFloatValue:intensity
                          forParameter:kKKParamAnimateOutIntensity];
  };
  graphView.onHoldIntensityChanged = ^(double intensity) {
    [weakSelf timingGraphSetFloatValue:intensity
                          forParameter:kKKParamHoldIntensity];
  };
  graphView.onInFrequencyChanged = ^(double frequency) {
    [weakSelf timingGraphSetFloatValue:frequency
                          forParameter:kKKParamAnimateInFrequency];
  };
  graphView.onOutFrequencyChanged = ^(double frequency) {
    [weakSelf timingGraphSetFloatValue:frequency
                          forParameter:kKKParamAnimateOutFrequency];
  };
  graphView.onHoldFrequencyChanged = ^(double frequency) {
    [weakSelf timingGraphSetFloatValue:frequency
                          forParameter:kKKParamHoldFrequency];
  };
  graphView.onHoldSeedChanged = ^(int seed) {
    [weakSelf timingGraphSetIntValue:seed forParameter:kKKParamHoldSeed];
  };
}

/// Stage sequencer container — sticky ruler + vertically-scrolled lanes
/// (capped at 2.5 lanes) with top/bottom shadow overlays. Hidden until
/// multi-stage is enabled. Inspector mode uses fixed height; window (uncapped)
/// mode pins top+bottom so the container stretches with the wrapper.
- (NSView *)_buildSeqContainerInWrapper:(NSView *)wrapper
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
        [seqContainer.topAnchor constraintEqualToAnchor:wrapper.topAnchor],
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
                            outSeqView:(KKStageSequencerView **)outSeqView {
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
  for (KKAnimatableProperty *p in seqProps) {
    NSNumber *kind = p.valueParamKinds.firstObject;
    if (kind)
      laneKinds[p.label] = kind;
  }
  seqView.laneKindsByLabel = laneKinds;
  seqView.laneLabelsWithOSC = [self animatablePropertyLabelsWithOSC];
  scrollView.documentView = seqView;
  [seqContainer addSubview:scrollView];

  // Pin the document view to the clip view's width so segments never overflow
  // past the visible area. In inspector (capped) mode, height is driven by
  // `-intrinsicContentSize` on the sequencer — lanes stay at min height and
  // the content shrinks by exactly one slot when a property is hidden. In
  // window (uncapped) mode, a low-priority bottom-pin lets the sequencer
  // grow with the clip view so lanes stretch vertically.
  NSMutableArray<NSLayoutConstraint *> *seqViewConstraints =
      [NSMutableArray arrayWithArray:@[
        [seqView.widthAnchor
            constraintEqualToAnchor:scrollView.contentView.widthAnchor],
        [seqView.topAnchor
            constraintEqualToAnchor:scrollView.contentView.topAnchor],
        [seqView.leadingAnchor
            constraintEqualToAnchor:scrollView.contentView.leadingAnchor],
      ]];
  if (uncapped) {
    // Lower hugging so the bottom-fill can stretch the view past its
    // intrinsic height when the window is enlarged.
    [seqView setContentHuggingPriority:NSLayoutPriorityDefaultLow - 1
                        forOrientation:NSLayoutConstraintOrientationVertical];
    NSLayoutConstraint *bottomFill = [seqView.bottomAnchor
        constraintEqualToAnchor:scrollView.contentView.bottomAnchor];
    bottomFill.priority = NSLayoutPriorityDefaultLow;
    [seqViewConstraints addObject:bottomFill];
  }
  [NSLayoutConstraint activateConstraints:seqViewConstraints];

  [NSLayoutConstraint activateConstraints:@[
    [scrollView.leadingAnchor
        constraintEqualToAnchor:seqContainer.leadingAnchor],
    [scrollView.trailingAnchor
        constraintEqualToAnchor:seqContainer.trailingAnchor],
    [scrollView.topAnchor constraintEqualToAnchor:rulerView.bottomAnchor],
    [scrollView.bottomAnchor constraintEqualToAnchor:seqContainer.bottomAnchor],
  ]];

  *outSeqView = seqView;
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

  NSMutableArray<KKTimingLane *> *defaults =
      [NSMutableArray arrayWithCapacity:seqProps.count];
  for (KKAnimatableProperty *prop in seqProps) {
    NSArray<NSNumber *> *baseVals = [prop readValuesWithGetAPI:paramGetAPI
                                                        atTime:time];
    if (!baseVals.count)
      baseVals = @[ @(1.0) ];
    [defaults addObject:[KKTimingLane defaultLaneForLabel:prop.label
                                               baseValues:baseVals]];
  }
  NSString *seeded = [KKTimingLane jsonFromLanes:defaults];
  if (seeded) {
    id<FxParameterSettingAPI_v5> setAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    [setAPI setStringParameterValue:seeded toParameter:kKKParamMultiStageData];
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

/// When multi-stage is enabled, swaps the graph for the sequencer container,
/// seeds lane data (creating defaults if missing), and syncs the playhead.
- (void)
    _seedSequencerIfEnabledWithSeqContainer:(NSView *)seqContainer
                                  graphView:(KKTimingGraphView *)graphView
                                    seqView:(KKStageSequencerView *)seqView
                                  rulerView:
                                      (KKStageSequencerRulerView *)rulerView
                               playheadView:(KKStagePlayheadView *)playheadView
                                   seqProps:(NSArray<KKAnimatableProperty *> *)
                                                seqProps
                                paramGetAPI:
                                    (id<FxParameterRetrievalAPI_v6>)paramGetAPI
                                  actionAPI:(id<FxCustomParameterActionAPI_v4>)
                                                actionAPI {
  BOOL multiStageEnabled = NO;
  [paramGetAPI getBoolValue:&multiStageEnabled
              fromParameter:kKKParamMultiStageEnabled
                     atTime:[actionAPI currentTime]];
  if (!multiStageEnabled)
    return;

  seqContainer.hidden = NO;
  graphView.hidden = YES;

  NSArray<KKTimingLane *> *lanes =
      [self _readOrSeedLanesForProps:seqProps
                         paramGetAPI:paramGetAPI
                              atTime:[actionAPI currentTime]];
  if (lanes) {
    KKPluginInstanceState *instState = KKInstanceStateForAPI(self.apiManager);
    instState.lanesSnapshot = [lanes copy];
    NSSet<NSString *> *hidden =
        [self hiddenAnimatablePropertyLabels] ?: [NSSet set];
    instState.hiddenLaneLabels = hidden;
    seqView.lanes = KKFilterLanesForVisibility(lanes, hidden);
  }

  [self _seedPlayheadForSeqView:seqView
                      rulerView:rulerView
                   playheadView:playheadView
                         atTime:[actionAPI currentTime]];
}

typedef struct {
  CGFloat fullLanesH;
  CGFloat rulerH;
  CGFloat seqContainerH;
  CGFloat wrapperHeight;
} KKTimingGraphMetrics;

static KKTimingGraphMetrics KKTimingGraphMetricsCompute(BOOL uncapped,
                                                        NSUInteger propsCount) {
  CGFloat fullLanesH = [KKStageSequencerView heightForLaneCount:propsCount];
  CGFloat lanesH;
  if (uncapped || propsCount <= 2) {
    lanesH = fullLanesH;
  } else {
    CGFloat h2 = [KKStageSequencerView heightForLaneCount:2];
    CGFloat h3 = [KKStageSequencerView heightForLaneCount:3];
    lanesH = h2 + (h3 - h2) * 0.5;
  }
  CGFloat rulerH = [KKStageSequencerRulerView preferredHeight];
  // Top inset + ruler + lanes area (which has its own bottom inset).
  CGFloat seqContainerH = KKPaddingSM + rulerH + lanesH;
  return (KKTimingGraphMetrics){
      .fullLanesH = fullLanesH,
      .rulerH = rulerH,
      .seqContainerH = seqContainerH,
      .wrapperHeight = seqContainerH + KKPaddingLG,
  };
}

- (KKTimingGraphView *)_buildTimingGraphInWrapper:(NSView *)wrapper {
  KKTimingGraphView *graphView =
      [[KKTimingGraphView alloc] initWithFrame:NSZeroRect];
  graphView.translatesAutoresizingMaskIntoConstraints = NO;
  [wrapper addSubview:graphView];
  [NSLayoutConstraint activateConstraints:@[
    [graphView.leadingAnchor constraintEqualToAnchor:wrapper.leadingAnchor],
    [graphView.topAnchor constraintEqualToAnchor:wrapper.topAnchor],
    [graphView.bottomAnchor constraintEqualToAnchor:wrapper.bottomAnchor],
    [graphView.trailingAnchor constraintEqualToAnchor:wrapper.trailingAnchor],
  ]];
  return graphView;
}

/// In inspector (capped) mode, the primary views are stored on the plugin
/// so callbacks can find them. In uncapped (window) mode they're added to
/// per-instance state as an additional ref set, and we push current state
/// through so the window opens already in sync.
- (void)_registerSequencerViewsForUncapped:(BOOL)uncapped
                                 graphView:(KKTimingGraphView *)graphView
                              seqContainer:(NSView *)seqContainer
                                   seqView:(KKStageSequencerView *)seqView
                                 rulerView:
                                     (KKStageSequencerRulerView *)rulerView
                              playheadView:(KKStagePlayheadView *)playheadView {
  if (!uncapped) {
    self.stageSequencer = seqView;
    self.stageSequencerContainer = seqContainer;
    self.stageSequencerRuler = rulerView;
    [self _registerMultiStageSequencerView:seqView
                                 rulerView:rulerView
                              playheadView:playheadView];
    return;
  }
  KKTimingViewRefs *refs = [[KKTimingViewRefs alloc] init];
  refs.graphView = graphView;
  refs.seqView = seqView;
  refs.seqContainer = seqContainer;
  refs.ruler = rulerView;
  refs.playhead = playheadView;
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  if (state) {
    if (!state.additionalTimingViews)
      state.additionalTimingViews = [NSMutableArray array];
    [state.additionalTimingViews addObject:refs];
  }
  [self timingGraphApplyState];
}

- (NSView *)_createTimingGraphViewUncapped:(BOOL)uncapped {
  NSArray<KKTimingSlot *> *globalSlots = [self timingGlobalSlots];
  NSArray<KKTimingSlot *> *inSlots =
      [self timingSlotsForSection:KKTimingGraphSectionIn];
  NSArray<KKTimingSlot *> *holdSlots =
      [self timingSlotsForSection:KKTimingGraphSectionHold];
  NSArray<KKTimingSlot *> *outSlots =
      [self timingSlotsForSection:KKTimingGraphSectionOut];

  NSArray<KKAnimatableProperty *> *seqProps = [self animatableProperties];
  KKTimingGraphMetrics metrics =
      KKTimingGraphMetricsCompute(uncapped, seqProps.count);

  NSView *wrapper = [[NSView alloc]
      initWithFrame:NSMakeRect(0, 0, 300, metrics.wrapperHeight)];
  wrapper.autoresizingMask = NSViewWidthSizable;

  KKTimingGraphView *graphView = [self _buildTimingGraphInWrapper:wrapper];

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  [self _applyTimingParamsToGraph:graphView
                     withParamAPI:paramGetAPI
                           atTime:[actionAPI currentTime]];
  [actionAPI endAction:self];

  [self _wireTimingGraphCallbacks:graphView];

  graphView.globalSlots = globalSlots;
  graphView.inSectionSlots = inSlots;
  graphView.holdSectionSlots = holdSlots;
  graphView.outSectionSlots = outSlots;

  [self _installHoldPropertyViewOnGraph:graphView];

  if (!uncapped)
    self.timingGraph = graphView;

  NSView *seqContainer =
      [self _buildSeqContainerInWrapper:wrapper
                               uncapped:uncapped
                          seqContainerH:metrics.seqContainerH];
  KKStageSequencerRulerView *rulerView =
      [self _buildSeqRulerInContainer:seqContainer rulerHeight:metrics.rulerH];
  KKStageSequencerView *seqView = nil;
  [self _buildSeqScrollViewInContainer:seqContainer
                            underRuler:rulerView
                              uncapped:uncapped
                              seqProps:seqProps
                            fullLanesH:metrics.fullLanesH
                            outSeqView:&seqView];
  KKStagePlayheadView *playheadView =
      [self _buildSeqPlayheadInContainer:seqContainer
                             rulerHeight:metrics.rulerH];

  [self _registerSequencerViewsForUncapped:uncapped
                                 graphView:graphView
                              seqContainer:seqContainer
                                   seqView:seqView
                                 rulerView:rulerView
                              playheadView:playheadView];

  [self _wireStageSequencerCallbacksFor:seqView
                              rulerView:rulerView
                           playheadView:playheadView];

  [actionAPI startAction:self];
  [self _seedSequencerIfEnabledWithSeqContainer:seqContainer
                                      graphView:graphView
                                        seqView:seqView
                                      rulerView:rulerView
                                   playheadView:playheadView
                                       seqProps:seqProps
                                    paramGetAPI:paramGetAPI
                                      actionAPI:actionAPI];

  CMTime t = [actionAPI currentTime];
  [self _applySlotState:globalSlots withParamAPI:paramGetAPI atTime:t];
  [self _applySlotState:inSlots withParamAPI:paramGetAPI atTime:t];
  [self _applySlotState:holdSlots withParamAPI:paramGetAPI atTime:t];
  [self _applySlotState:outSlots withParamAPI:paramGetAPI atTime:t];
  if (graphView.holdPropertyApplyState)
    graphView.holdPropertyApplyState(paramGetAPI, t);
  [actionAPI endAction:self];

  return wrapper;
}

@end
