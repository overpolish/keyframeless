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
#import "../Views/KKStagePlayheadView.h"
#import "../Views/KKStageSequencerRulerView.h"
#import "../Views/KKStageSequencerView.h"

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

@interface KKScrollShadowView : NSView
@end
@implementation KKScrollShadowView
- (NSView *)hitTest:(NSPoint)point {
  return nil;
}
@end

@interface KKScrollShadowObserver : NSObject
@end
@implementation KKScrollShadowObserver {
  id _token;
}
- (instancetype)initWithClipView:(NSView *)clipView
                           block:(void (^)(void))block {
  self = [super init];
  if (self) {
    clipView.postsBoundsChangedNotifications = YES;
    _token = [[NSNotificationCenter defaultCenter]
        addObserverForName:NSViewBoundsDidChangeNotification
                    object:clipView
                     queue:nil
                usingBlock:^(NSNotification *note) {
                  block();
                }];
  }
  return self;
}
- (void)dealloc {
  if (_token)
    [[NSNotificationCenter defaultCenter] removeObserver:_token];
}
@end

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"
@implementation KKPlugin (CustomViews)

- (void)_applyTimingParamsToGraph:(KKTimingGraphView *)graph
                     withParamAPI:(id<FxParameterRetrievalAPI_v6>)paramGetAPI
                           atTime:(CMTime)t {
  BOOL animIn = NO, animOut = NO;
  int inCurve = KKEasingCurveEaseOut, outCurve = KKEasingCurveEaseOut;
  int sel = KKTimingGraphSectionHold, holdEffectVal = KKHoldEffectNone;
  [paramGetAPI getBoolValue:&animIn fromParameter:kKKParamAnimateIn atTime:t];
  [paramGetAPI getBoolValue:&animOut fromParameter:kKKParamAnimateOut atTime:t];
  [paramGetAPI getIntValue:&inCurve
             fromParameter:kKKParamAnimateInInterpolation
                    atTime:t];
  [paramGetAPI getIntValue:&outCurve
             fromParameter:kKKParamAnimateOutInterpolation
                    atTime:t];
  [paramGetAPI getIntValue:&sel
             fromParameter:kKKParamTimingSelectedSection
                    atTime:t];
  [paramGetAPI getIntValue:&holdEffectVal
             fromParameter:kKKParamHoldEffect
                    atTime:t];

  double inIntensity = 0.5, outIntensity = 0.5, holdIntensity = 0.5;
  [paramGetAPI getFloatValue:&inIntensity
               fromParameter:kKKParamAnimateInIntensity
                      atTime:t];
  [paramGetAPI getFloatValue:&outIntensity
               fromParameter:kKKParamAnimateOutIntensity
                      atTime:t];
  [paramGetAPI getFloatValue:&holdIntensity
               fromParameter:kKKParamHoldIntensity
                      atTime:t];

  double inFrequency = 0.5, outFrequency = 0.5, holdFrequency = 0.5;
  [paramGetAPI getFloatValue:&inFrequency
               fromParameter:kKKParamAnimateInFrequency
                      atTime:t];
  [paramGetAPI getFloatValue:&outFrequency
               fromParameter:kKKParamAnimateOutFrequency
                      atTime:t];
  [paramGetAPI getFloatValue:&holdFrequency
               fromParameter:kKKParamHoldFrequency
                      atTime:t];

  int holdSeed = 0;
  [paramGetAPI getIntValue:&holdSeed fromParameter:kKKParamHoldSeed atTime:t];

  double inDuration = 0.5, outDuration = 0.5;
  [paramGetAPI getFloatValue:&inDuration
               fromParameter:kKKParamAnimateInDuration
                      atTime:t];
  [paramGetAPI getFloatValue:&outDuration
               fromParameter:kKKParamAnimateOutDuration
                      atTime:t];

  graph.inEnabled = animIn;
  graph.outEnabled = animOut;
  graph.inDuration = inDuration;
  graph.outDuration = outDuration;
  graph.inCurve = (KKEasingCurve)inCurve;
  graph.outCurve = (KKEasingCurve)outCurve;
  graph.holdEffect = (KKHoldEffect)holdEffectVal;
  graph.inIntensity = inIntensity;
  graph.outIntensity = outIntensity;
  graph.holdIntensity = holdIntensity;
  graph.inFrequency = inFrequency;
  graph.outFrequency = outFrequency;
  graph.holdFrequency = holdFrequency;
  graph.holdSeed = holdSeed;
  graph.selectedSection = (KKTimingGraphSection)sel;
}

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

  if (parameterID == kKKParamAnimationSeparator)
    return [self _createTimingHeader:parameterID];

  if (parameterID == kKKParamTimingCurvePreview)
    return [self _createTimingGraphView];

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

  self.timingHeader = header;
  return header;
}

- (NSView *)_createTimingGraphView {
  NSArray<KKTimingSlot *> *globalSlots = [self timingGlobalSlots];
  NSArray<KKTimingSlot *> *inSlots =
      [self timingSlotsForSection:KKTimingGraphSectionIn];
  NSArray<KKTimingSlot *> *holdSlots =
      [self timingSlotsForSection:KKTimingGraphSectionHold];
  NSArray<KKTimingSlot *> *outSlots =
      [self timingSlotsForSection:KKTimingGraphSectionOut];

  NSArray<KKAnimatableProperty *> *seqProps = [self animatableProperties];
  CGFloat fullLanesH = [KKStageSequencerView heightForLaneCount:seqProps.count];
  CGFloat cappedLanesH;
  if (seqProps.count <= 2) {
    cappedLanesH = fullLanesH;
  } else {
    CGFloat h2 = [KKStageSequencerView heightForLaneCount:2];
    CGFloat h3 = [KKStageSequencerView heightForLaneCount:3];
    cappedLanesH = h2 + (h3 - h2) * 0.5;
  }
  CGFloat rulerH = [KKStageSequencerRulerView preferredHeight];
  // Top inset + ruler + lanes area (which has its own bottom inset).
  CGFloat seqContainerH = KKPaddingSM + rulerH + cappedLanesH;
  CGFloat wrapperHeight = seqContainerH + KKPaddingLG;

  NSView *wrapper =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, wrapperHeight)];
  wrapper.autoresizingMask = NSViewWidthSizable;

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

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  [self _applyTimingParamsToGraph:graphView
                     withParamAPI:paramGetAPI
                           atTime:[actionAPI currentTime]];
  [actionAPI endAction:self];

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

  graphView.globalSlots = globalSlots;
  graphView.inSectionSlots = inSlots;
  graphView.holdSectionSlots = holdSlots;
  graphView.outSectionSlots = outSlots;

  NSArray<KKAnimatableProperty *> *animProps = [self animatableProperties];
  if (animProps.count > 0) {
    static const CGFloat kRowH = 18.0;
    NSMutableArray<NSString *> *labels = [NSMutableArray new];
    for (KKAnimatableProperty *p in animProps)
      [labels addObject:p.label];

    // Split into 2 rows when >5 properties.
    BOOL twoRows = animProps.count > 5;
    NSView *propView;
    KKPillToggleRowView *row1, *row2;
    NSUInteger splitAt = twoRows ? (animProps.count + 1) / 2 : animProps.count;
    CGFloat totalH;

    if (twoRows) {
      NSArray *labels1 = [labels subarrayWithRange:NSMakeRange(0, splitAt)];
      NSArray *labels2 = [labels
          subarrayWithRange:NSMakeRange(splitAt, animProps.count - splitAt)];
      row1 = [[KKPillToggleRowView alloc] initWithLabels:labels1];
      row2 = [[KKPillToggleRowView alloc] initWithLabels:labels2];
      row1.autoresizingMask = NSViewWidthSizable;
      row2.autoresizingMask = NSViewWidthSizable;
      totalH = kRowH * 2 + KKSpacingXS;
      NSView *container =
          [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, totalH)];
      row1.frame = NSMakeRect(0, 0, 300, kRowH);
      row2.frame = NSMakeRect(0, kRowH + KKSpacingXS, 300, kRowH);
      [container addSubview:row1];
      [container addSubview:row2];
      propView = container;
    } else {
      row1 = [[KKPillToggleRowView alloc] initWithLabels:labels];
      row2 = nil;
      totalH = kRowH;
      propView = row1;
    }

    __weak typeof(self) weakSelf = self;
    __weak KKTimingGraphView *weakGraph = graphView;

    void (^handleToggle)(NSInteger, BOOL) = ^(NSInteger index, BOOL isOn) {
      __strong typeof(weakSelf) strongSelf = weakSelf;
      KKTimingGraphView *graph = weakGraph;
      if (!strongSelf || !graph || (NSUInteger)index >= animProps.count)
        return;
      KKAnimatableProperty *prop = animProps[index];
      UInt32 paramID;
      switch (graph.selectedSection) {
      case KKTimingGraphSectionIn:
        paramID = prop.inParamID;
        break;
      case KKTimingGraphSectionOut:
        paramID = prop.outParamID;
        break;
      default:
        paramID = prop.holdParamID;
        break;
      }
      id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
          apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      [actAPI startAction:strongSelf];
      id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
          apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      [setAPI setBoolValue:isOn
               toParameter:paramID
                    atTime:[actAPI currentTime]];
      [actAPI endAction:strongSelf];
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
        KKAnimatableProperty *prop = animProps[i];
        UInt32 paramID;
        switch (graph.selectedSection) {
        case KKTimingGraphSectionIn:
          paramID = prop.inParamID;
          break;
        case KKTimingGraphSectionOut:
          paramID = prop.outParamID;
          break;
        default:
          paramID = prop.holdParamID;
          break;
        }
        BOOL val = YES;
        [paramAPI getBoolValue:&val fromParameter:paramID atTime:time];
        if (i < splitAt)
          [row1 setState:val atIndex:i];
        else
          [row2 setState:val atIndex:i - splitAt];
      }
    };
  } else {
    NSView *holdPropView = [self holdPropertyView];
    if (holdPropView) {
      graphView.holdPropertyView = holdPropView;
      graphView.holdPropertyViewHeight = [self holdPropertyViewHeight];
      graphView.holdPropertyApplyState = [self holdPropertyApplyState];
    }
  }

  self.timingGraph = graphView;

  // Stage sequencer container — sticky ruler + vertically-scrolled lanes
  // (capped at 2.5 lanes) with top/bottom shadow overlays. Hidden until
  // multi-stage is enabled.
  NSView *seqContainer = [[NSView alloc] initWithFrame:NSZeroRect];
  seqContainer.translatesAutoresizingMaskIntoConstraints = NO;
  seqContainer.wantsLayer = YES;
  seqContainer.layer.masksToBounds = YES;
  seqContainer.layer.cornerRadius = KKSpacingMD;
  seqContainer.layer.borderWidth = KKBorderWidthXS;
  seqContainer.layer.borderColor =
      [NSColor colorWithWhite:1.0 alpha:0.05].CGColor;
  seqContainer.hidden = YES;
  [wrapper addSubview:seqContainer];

  KKStageSequencerRulerView *rulerView =
      [[KKStageSequencerRulerView alloc] initWithFrame:NSZeroRect];
  rulerView.translatesAutoresizingMaskIntoConstraints = NO;
  [seqContainer addSubview:rulerView];

  NSScrollView *scrollView = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  scrollView.translatesAutoresizingMaskIntoConstraints = NO;
  scrollView.hasVerticalScroller = YES;
  scrollView.hasHorizontalScroller = NO;
  scrollView.drawsBackground = NO;
  scrollView.autohidesScrollers = YES;
  scrollView.scrollerStyle = NSScrollerStyleOverlay;
  scrollView.borderType = NSNoBorder;

  scrollView.contentView.postsBoundsChangedNotifications = YES;

  KKStageSequencerView *seqView = [[KKStageSequencerView alloc]
      initWithFrame:NSMakeRect(0, 0, 300, fullLanesH)];
  seqView.translatesAutoresizingMaskIntoConstraints = NO;
  scrollView.documentView = seqView;
  [seqContainer addSubview:scrollView];

  // Pin the document view to the clip view's width so segments never overflow
  // past the visible area; height stays fixed at the full lanes height.
  [NSLayoutConstraint activateConstraints:@[
    [seqView.widthAnchor
        constraintEqualToAnchor:scrollView.contentView.widthAnchor],
    [seqView.heightAnchor constraintEqualToConstant:fullLanesH],
    [seqView.topAnchor
        constraintEqualToAnchor:scrollView.contentView.topAnchor],
    [seqView.leadingAnchor
        constraintEqualToAnchor:scrollView.contentView.leadingAnchor],
  ]];

  CGFloat shadowH = 16.0;
  KKScrollShadowView *topShadow =
      [[KKScrollShadowView alloc] initWithFrame:NSZeroRect];
  topShadow.translatesAutoresizingMaskIntoConstraints = NO;
  topShadow.wantsLayer = YES;
  CAGradientLayer *topGrad = [CAGradientLayer layer];
  topGrad.colors = @[
    (__bridge id)[NSColor colorWithWhite:0 alpha:0.35].CGColor,
    (__bridge id)[NSColor clearColor].CGColor,
  ];
  topGrad.startPoint = CGPointMake(0.5, 1.0);
  topGrad.endPoint = CGPointMake(0.5, 0.0);
  topShadow.layer = topGrad;
  topShadow.alphaValue = 0.0;
  [seqContainer addSubview:topShadow];

  KKScrollShadowView *bottomShadow =
      [[KKScrollShadowView alloc] initWithFrame:NSZeroRect];
  bottomShadow.translatesAutoresizingMaskIntoConstraints = NO;
  bottomShadow.wantsLayer = YES;
  CAGradientLayer *botGrad = [CAGradientLayer layer];
  botGrad.colors = @[
    (__bridge id)[NSColor clearColor].CGColor,
    (__bridge id)[NSColor colorWithWhite:0 alpha:0.35].CGColor,
  ];
  botGrad.startPoint = CGPointMake(0.5, 1.0);
  botGrad.endPoint = CGPointMake(0.5, 0.0);
  bottomShadow.layer = botGrad;
  bottomShadow.alphaValue = 0.0;
  [seqContainer addSubview:bottomShadow];

  KKStagePlayheadView *playheadView =
      [[KKStagePlayheadView alloc] initWithFrame:NSZeroRect];
  playheadView.translatesAutoresizingMaskIntoConstraints = NO;
  playheadView.rulerHeight = rulerH;
  playheadView.topPadding = KKPaddingSM;
  [seqContainer addSubview:playheadView];

  [NSLayoutConstraint activateConstraints:@[
    [seqContainer.leadingAnchor
        constraintEqualToAnchor:wrapper.leadingAnchor
                       constant:KKInspectorHorizontalInset],
    [seqContainer.trailingAnchor
        constraintEqualToAnchor:wrapper.trailingAnchor
                       constant:-KKInspectorHorizontalInset],
    [seqContainer.topAnchor constraintEqualToAnchor:wrapper.topAnchor],
    [seqContainer.heightAnchor constraintEqualToConstant:seqContainerH],

    [rulerView.leadingAnchor
        constraintEqualToAnchor:seqContainer.leadingAnchor],
    [rulerView.trailingAnchor
        constraintEqualToAnchor:seqContainer.trailingAnchor],
    [rulerView.topAnchor constraintEqualToAnchor:seqContainer.topAnchor
                                        constant:KKPaddingSM],
    [rulerView.heightAnchor constraintEqualToConstant:rulerH],

    [scrollView.leadingAnchor
        constraintEqualToAnchor:seqContainer.leadingAnchor],
    [scrollView.trailingAnchor
        constraintEqualToAnchor:seqContainer.trailingAnchor],
    [scrollView.topAnchor constraintEqualToAnchor:rulerView.bottomAnchor],
    [scrollView.bottomAnchor constraintEqualToAnchor:seqContainer.bottomAnchor],

    [topShadow.leadingAnchor constraintEqualToAnchor:scrollView.leadingAnchor],
    [topShadow.trailingAnchor
        constraintEqualToAnchor:scrollView.trailingAnchor],
    [topShadow.topAnchor constraintEqualToAnchor:scrollView.topAnchor],
    [topShadow.heightAnchor constraintEqualToConstant:shadowH],

    [bottomShadow.leadingAnchor
        constraintEqualToAnchor:scrollView.leadingAnchor],
    [bottomShadow.trailingAnchor
        constraintEqualToAnchor:scrollView.trailingAnchor],
    [bottomShadow.bottomAnchor constraintEqualToAnchor:scrollView.bottomAnchor],
    [bottomShadow.heightAnchor constraintEqualToConstant:shadowH],

    [playheadView.leadingAnchor
        constraintEqualToAnchor:seqContainer.leadingAnchor],
    [playheadView.trailingAnchor
        constraintEqualToAnchor:seqContainer.trailingAnchor],
    [playheadView.topAnchor constraintEqualToAnchor:seqContainer.topAnchor],
    [playheadView.bottomAnchor
        constraintEqualToAnchor:seqContainer.bottomAnchor],
  ]];

  self.stageSequencer = seqView;
  self.stageSequencerContainer = seqContainer;
  self.stageSequencerRuler = rulerView;
  [self _registerMultiStageSequencerView:seqView
                               rulerView:rulerView
                            playheadView:playheadView];

  // Keep ruler, lanes, and playhead overlay in lockstep horizontally.
  __weak KKStageSequencerView *weakSeqForSync = seqView;
  __weak KKStageSequencerRulerView *weakRulerForSync = rulerView;
  __weak KKStagePlayheadView *weakPlayheadForSync = playheadView;
  seqView.onZoomPanChanged = ^(CGFloat z, CGFloat p) {
    weakRulerForSync.zoom = z;
    weakRulerForSync.panOffset = p;
    weakPlayheadForSync.zoom = z;
    weakPlayheadForSync.panOffset = p;
  };
  rulerView.onZoomPanChanged = ^(CGFloat z, CGFloat p) {
    weakSeqForSync.zoom = z;
    weakSeqForSync.panOffset = p;
    weakPlayheadForSync.zoom = z;
    weakPlayheadForSync.panOffset = p;
  };

  // Fade shadow overlays based on scroll position (fraction within the
  // scrollable range, using unflipped document coords where higher Y is
  // visual top).
  __weak NSScrollView *weakScroll = scrollView;
  __weak KKScrollShadowView *weakTopShadow = topShadow;
  __weak KKScrollShadowView *weakBottomShadow = bottomShadow;
  void (^updateShadows)(void) = ^{
    NSScrollView *sv = weakScroll;
    if (!sv)
      return;
    NSRect vr = sv.documentVisibleRect;
    NSRect cr = [(NSView *)sv.documentView bounds];
    CGFloat scrollable = cr.size.height - vr.size.height;
    if (scrollable <= 0.5) {
      weakTopShadow.alphaValue = 0.0;
      weakBottomShadow.alphaValue = 0.0;
      return;
    }
    CGFloat fromTop =
        (cr.origin.y + cr.size.height) - (vr.origin.y + vr.size.height);
    CGFloat percent = fromTop / scrollable;
    percent = MAX(0.0, MIN(1.0, percent));
    weakTopShadow.alphaValue = percent;
    weakBottomShadow.alphaValue = 1.0 - percent;
  };
  KKScrollShadowObserver *shadowObs =
      [[KKScrollShadowObserver alloc] initWithClipView:scrollView.contentView
                                                 block:updateShadows];
  // Keep the observer alive for the lifetime of the container.
  static const void *const kShadowObsKey = &kShadowObsKey;
  objc_setAssociatedObject(seqContainer, kShadowObsKey, shadowObs,
                           OBJC_ASSOCIATION_RETAIN_NONATOMIC);

  // KKStageSequencerView's setFrameSize: scrolls the enclosing scroll view to
  // the top on first real layout; run updateShadows once things settle.
  dispatch_async(dispatch_get_main_queue(), ^{
    updateShadows();
  });

  seqView.onSegmentSelected = ^(NSInteger laneIndex, NSInteger segmentIndex) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf || laneIndex < 0)
      return;
    KKPluginInstanceState *state = KKInstanceStateForAPI(strongSelf.apiManager);
    if (!state)
      return;
    state.selectionInProgress = YES;
    NSArray<KKAnimatableProperty *> *props = [strongSelf animatableProperties];
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI startAction:strongSelf];
    id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    id<FxParameterRetrievalAPI_v6> getAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    CMTime ct = [actAPI currentTime];

    NSString *json = nil;
    [getAPI getStringParameterValue:&json fromParameter:kKKParamMultiStageData];
    NSMutableArray<KKTimingLane *> *lanes =
        [[KKTimingLane lanesFromJSON:json] mutableCopy];
    if (!lanes || (NSUInteger)laneIndex >= lanes.count) {
      [actAPI endAction:strongSelf];
      return;
    }

    KKTimingLane *lane = lanes[laneIndex];
    KKAnimatableProperty *prop = nil;
    for (KKAnimatableProperty *p in props) {
      if ([p.label isEqualToString:lane.propertyLabel]) {
        prop = p;
        break;
      }
    }

    // 1. Write-back: save current native param values into this lane's
    //    previously selected segment.
    NSInteger prevSeg = lane.selectedSegment;
    if (prop.valueParamIDs.count > 0 && prevSeg >= 0 &&
        (NSUInteger)prevSeg < lane.segments.count) {
      NSMutableArray<NSNumber *> *curVals =
          [NSMutableArray arrayWithCapacity:prop.valueParamIDs.count];
      for (NSNumber *pid in prop.valueParamIDs) {
        double v = 0;
        [getAPI getFloatValue:&v fromParameter:pid.unsignedIntValue atTime:ct];
        [curVals addObject:@(v)];
      }
      KKTimingLane *mLane = [lane copy];
      NSMutableArray *mSegs = [mLane.segments mutableCopy];
      KKTimingSegment *mSeg = [mSegs[prevSeg] copy];
      mSeg.values = curVals;
      mSegs[prevSeg] = mSeg;
      mLane.segments = mSegs;
      mLane.selectedSegment = segmentIndex;
      lanes[laneIndex] = mLane;
      lane = mLane;
    } else {
      KKTimingLane *mLane = [lane copy];
      mLane.selectedSegment = segmentIndex;
      lanes[laneIndex] = mLane;
      lane = mLane;
    }

    // 2. Save updated JSON with write-back + new selection.
    NSString *updated = [KKTimingLane jsonFromLanes:lanes];
    if (updated)
      [setAPI setStringParameterValue:updated
                          toParameter:kKKParamMultiStageData];

    // 3. Update snapshot + clear pending BEFORE endAction (which triggers
    //    parameterChanged: that would read stale snapshot).
    state.lanesSnapshot = [lanes copy];
    state.pendingLanes = nil;

    // 4. Sync new selection: write segment values → native params.
    if (prop.valueParamIDs.count > 0 && segmentIndex >= 0 &&
        (NSUInteger)segmentIndex < lane.segments.count) {
      NSArray<NSNumber *> *segValues = lane.segments[segmentIndex].values;
      for (NSUInteger i = 0;
           i < prop.valueParamIDs.count && i < segValues.count; i++) {
        [setAPI setFloatValue:segValues[i].doubleValue
                  toParameter:prop.valueParamIDs[i].unsignedIntValue
                       atTime:ct];
      }
    }

    [actAPI endAction:strongSelf];
    state.selectionInProgress = NO;
    [strongSelf timingGraphApplyState];
  };

  seqView.onLaneToggled = ^(NSInteger laneIndex, BOOL enabled) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    KKPluginInstanceState *state = KKInstanceStateForAPI(strongSelf.apiManager);
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI startAction:strongSelf];
    id<FxParameterRetrievalAPI_v6> getAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    CMTime ct = [actAPI currentTime];
    NSString *json = nil;
    [getAPI getStringParameterValue:&json fromParameter:kKKParamMultiStageData];
    NSArray<KKTimingLane *> *lanes = [KKTimingLane lanesFromJSON:json];
    if (lanes && (NSUInteger)laneIndex < lanes.count) {
      NSMutableArray *mutable = [lanes mutableCopy];
      KKTimingLane *lane = [mutable[laneIndex] copy];
      lane.enabled = enabled;
      if (!enabled) {
        lane.selectedSegment = -1;
      } else {
        lane.selectedSegment = -1;
        for (NSUInteger i = 0; i < lane.segments.count; i++) {
          if (lane.segments[i].type == KKSegmentTypeHold) {
            lane.selectedSegment = (NSInteger)i;
            break;
          }
        }
      }
      mutable[laneIndex] = lane;
      NSString *updated = [KKTimingLane jsonFromLanes:mutable];
      if (updated)
        [setAPI setStringParameterValue:updated
                            toParameter:kKKParamMultiStageData];

      // Enable-path: native params may have been edited while the lane was
      // disabled. The lane's own segment values are the source of truth, so
      // overwrite native params with the newly-selected segment's values.
      // Without this, the live-param-override in multiStageValuesAtTime:
      // would keep rendering the stale native-param values until the user
      // clicks the segment (which triggers write-back and sync).
      if (enabled && lane.selectedSegment >= 0 &&
          (NSUInteger)lane.selectedSegment < lane.segments.count) {
        NSArray<KKAnimatableProperty *> *props =
            [strongSelf animatableProperties];
        KKAnimatableProperty *prop = nil;
        for (KKAnimatableProperty *p in props) {
          if ([p.label isEqualToString:lane.propertyLabel]) {
            prop = p;
            break;
          }
        }
        if (state)
          state.selectionInProgress = YES;
        NSArray<NSNumber *> *segValues =
            lane.segments[lane.selectedSegment].values;
        for (NSUInteger i = 0;
             i < prop.valueParamIDs.count && i < segValues.count; i++) {
          [setAPI setFloatValue:segValues[i].doubleValue
                    toParameter:prop.valueParamIDs[i].unsignedIntValue
                         atTime:ct];
        }
        if (state) {
          state.lanesSnapshot = [mutable copy];
          state.pendingLanes = nil;
        }
      }
    }
    [actAPI endAction:strongSelf];
    if (state)
      state.selectionInProgress = NO;
    [strongSelf timingGraphApplyState];
  };

  seqView.onLaneChanged = ^(NSInteger laneIndex, KKTimingLane *updatedLane) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI startAction:strongSelf];
    id<FxParameterRetrievalAPI_v6> getAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    NSString *json = nil;
    [getAPI getStringParameterValue:&json fromParameter:kKKParamMultiStageData];
    NSMutableArray<KKTimingLane *> *lanes =
        [[KKTimingLane lanesFromJSON:json] mutableCopy];
    if (lanes && (NSUInteger)laneIndex < lanes.count) {
      lanes[laneIndex] = updatedLane;
      NSString *updated = [KKTimingLane jsonFromLanes:lanes];
      if (updated)
        [setAPI setStringParameterValue:updated
                            toParameter:kKKParamMultiStageData];
    }
    [actAPI endAction:strongSelf];
    [strongSelf timingGraphApplyState];
  };

  seqView.onSegmentAdded = ^(NSInteger laneIndex, double position) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI startAction:strongSelf];
    id<FxParameterRetrievalAPI_v6> getAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    NSString *json = nil;
    [getAPI getStringParameterValue:&json fromParameter:kKKParamMultiStageData];
    NSMutableArray<KKTimingLane *> *lanes =
        [[KKTimingLane lanesFromJSON:json] mutableCopy];
    if (!lanes || (NSUInteger)laneIndex >= lanes.count) {
      [actAPI endAction:strongSelf];
      return;
    }
    KKTimingLane *lane = [lanes[laneIndex] copy];
    NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];

    // Find which segment the click landed in and split it.
    NSInteger splitIdx = -1;
    for (NSUInteger i = 0; i < segs.count; i++) {
      if (position >= segs[i].start && position < segs[i].end) {
        splitIdx = (NSInteger)i;
        break;
      }
    }
    if (splitIdx < 0) {
      [actAPI endAction:strongSelf];
      return;
    }

    KKTimingSegment *orig = segs[splitIdx];
    double splitPoint = position;

    // Create two segments from the split.
    KKTimingSegment *left = [orig copy];
    left.end = splitPoint;
    KKTimingSegment *right = [orig copy];
    right.start = splitPoint;

    // If splitting a hold, the new right segment becomes a new hold with
    // same values. If splitting a transition, both halves stay transitions.
    [segs replaceObjectAtIndex:splitIdx withObject:left];
    [segs insertObject:right atIndex:splitIdx + 1];

    lane.segments = segs;
    lane.selectedSegment = splitIdx + 1;
    lanes[laneIndex] = lane;

    NSString *updated = [KKTimingLane jsonFromLanes:lanes];
    if (updated)
      [setAPI setStringParameterValue:updated
                          toParameter:kKKParamMultiStageData];
    [actAPI endAction:strongSelf];
    [strongSelf timingGraphApplyState];
  };

  seqView.onSegmentRemoved = ^(NSInteger laneIndex, NSInteger segmentIndex) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI startAction:strongSelf];
    id<FxParameterRetrievalAPI_v6> getAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    NSString *json = nil;
    [getAPI getStringParameterValue:&json fromParameter:kKKParamMultiStageData];
    NSMutableArray<KKTimingLane *> *lanes =
        [[KKTimingLane lanesFromJSON:json] mutableCopy];
    if (!lanes || (NSUInteger)laneIndex >= lanes.count) {
      [actAPI endAction:strongSelf];
      return;
    }
    KKTimingLane *lane = [lanes[laneIndex] copy];
    NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];
    if (segs.count <= 1 || (NSUInteger)segmentIndex >= segs.count) {
      [actAPI endAction:strongSelf];
      return;
    }

    KKTimingSegment *removed = segs[segmentIndex];
    // Expand the neighbor to fill the gap.
    if ((NSUInteger)segmentIndex + 1 < segs.count) {
      KKTimingSegment *next = [segs[segmentIndex + 1] copy];
      next.start = removed.start;
      segs[segmentIndex + 1] = next;
    } else if (segmentIndex > 0) {
      KKTimingSegment *prev = [segs[segmentIndex - 1] copy];
      prev.end = removed.end;
      segs[segmentIndex - 1] = prev;
    }
    [segs removeObjectAtIndex:segmentIndex];

    // Fix selection.
    if (lane.selectedSegment == segmentIndex) {
      lane.selectedSegment = -1;
      for (NSUInteger i = 0; i < segs.count; i++) {
        if (segs[i].type == KKSegmentTypeHold) {
          lane.selectedSegment = (NSInteger)i;
          break;
        }
      }
    } else if (lane.selectedSegment > segmentIndex) {
      lane.selectedSegment--;
    }

    lane.segments = segs;
    lanes[laneIndex] = lane;

    NSString *updated = [KKTimingLane jsonFromLanes:lanes];
    if (updated)
      [setAPI setStringParameterValue:updated
                          toParameter:kKKParamMultiStageData];
    [actAPI endAction:strongSelf];
    [strongSelf timingGraphApplyState];
  };

  seqView.onSegmentTypeToggled = ^(NSInteger laneIndex,
                                   NSInteger segmentIndex) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actAPI startAction:strongSelf];
    id<FxParameterRetrievalAPI_v6> getAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    id<FxParameterSettingAPI_v5> setAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    NSString *json = nil;
    [getAPI getStringParameterValue:&json fromParameter:kKKParamMultiStageData];
    NSMutableArray<KKTimingLane *> *lanes =
        [[KKTimingLane lanesFromJSON:json] mutableCopy];
    if (!lanes || (NSUInteger)laneIndex >= lanes.count) {
      [actAPI endAction:strongSelf];
      return;
    }
    KKTimingLane *lane = [lanes[laneIndex] copy];
    NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];
    if ((NSUInteger)segmentIndex >= segs.count) {
      [actAPI endAction:strongSelf];
      return;
    }
    KKTimingSegment *seg = [segs[segmentIndex] copy];
    seg.type = (seg.type == KKSegmentTypeHold) ? KKSegmentTypeTransition
                                               : KKSegmentTypeHold;
    segs[segmentIndex] = seg;
    lane.segments = segs;
    lanes[laneIndex] = lane;

    NSString *updated = [KKTimingLane jsonFromLanes:lanes];
    if (updated)
      [setAPI setStringParameterValue:updated
                          toParameter:kKKParamMultiStageData];
    [actAPI endAction:strongSelf];
    [strongSelf timingGraphApplyState];
  };

  seqView.onSegmentEditRequested =
      ^(NSInteger laneIndex, NSInteger segmentIndex, NSRect anchorRect) {
        __strong typeof(weakSelf) strongSelf = weakSelf;
        if (!strongSelf)
          return;
        [strongSelf _showSegmentEditPopoverForLane:laneIndex
                                        segmentIdx:segmentIndex
                                        anchorRect:anchorRect];
      };

  rulerView.onPlayheadScrub = ^(double fraction) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    id<FxCustomParameterActionAPI_v4> actAPI = [strongSelf.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    if (!actAPI)
      return;
    [actAPI startAction:strongSelf];
    id<FxTimingAPI_v4> timingAPI =
        [strongSelf.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
    id<FxCommandAPI_v2> commandAPI =
        [strongSelf.apiManager apiForProtocol:@protocol(FxCommandAPI_v2)];
    if (timingAPI && commandAPI) {
      CMTime effectStart = kCMTimeZero, effectDuration = kCMTimeZero;
      [timingAPI startTimeForEffect:&effectStart];
      [timingAPI durationTimeForEffect:&effectDuration];
      double startSec = CMTimeGetSeconds(effectStart);
      double durSec = CMTimeGetSeconds(effectDuration);
      double targetSec = startSec + fraction * durSec;
      CMTime targetTime = CMTimeMakeWithSeconds(targetSec, 600);
      [commandAPI movePlayheadToTime:targetTime error:nil];
    }
    [actAPI endAction:strongSelf];
  };

  // Seed sequencer with lane data if multi-stage is enabled.
  [actionAPI startAction:self];
  BOOL multiStageEnabled = NO;
  [paramGetAPI getBoolValue:&multiStageEnabled
              fromParameter:kKKParamMultiStageEnabled
                     atTime:[actionAPI currentTime]];
  if (multiStageEnabled) {
    seqContainer.hidden = NO;
    graphView.hidden = YES;
    NSString *json = nil;
    [paramGetAPI getStringParameterValue:&json
                           fromParameter:kKKParamMultiStageData];
    NSArray<KKTimingLane *> *lanes = [KKTimingLane lanesFromJSON:json];
    if (!lanes && seqProps.count > 0) {
      NSMutableArray<KKTimingLane *> *defaults =
          [NSMutableArray arrayWithCapacity:seqProps.count];
      for (KKAnimatableProperty *prop in seqProps) {
        NSMutableArray<NSNumber *> *baseVals =
            [NSMutableArray arrayWithCapacity:prop.valueParamIDs.count];
        for (NSNumber *pid in prop.valueParamIDs) {
          double v = 0;
          [paramGetAPI getFloatValue:&v
                       fromParameter:pid.unsignedIntValue
                              atTime:[actionAPI currentTime]];
          [baseVals addObject:@(v)];
        }
        if (!baseVals.count)
          [baseVals addObject:@(1.0)];
        [defaults addObject:[KKTimingLane defaultLaneForLabel:prop.label
                                                   baseValues:baseVals]];
      }
      lanes = defaults;
      NSString *seeded = [KKTimingLane jsonFromLanes:lanes];
      if (seeded) {
        id<FxParameterSettingAPI_v5> setAPI = [self.apiManager
            apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
        [setAPI setStringParameterValue:seeded
                            toParameter:kKKParamMultiStageData];
      }
    }
    if (lanes) {
      KKInstanceStateForAPI(self.apiManager).lanesSnapshot = [lanes copy];
      seqView.lanes = lanes;
    }

    id<FxTimingAPI_v4> timingAPI =
        [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
    if (timingAPI) {
      CMTime effectStart = kCMTimeZero, effectDuration = kCMTimeZero;
      [timingAPI startTimeForEffect:&effectStart];
      [timingAPI durationTimeForEffect:&effectDuration];
      double durSec = CMTimeGetSeconds(effectDuration);
      seqView.effectDuration = durSec;
      rulerView.effectDuration = durSec;
      double startSec = CMTimeGetSeconds(effectStart);
      double nowSec = CMTimeGetSeconds([actionAPI currentTime]);
      if (durSec > 0) {
        double frac = (nowSec - startSec) / durSec;
        seqView.playheadFraction = frac;
        playheadView.playheadFraction = frac;
      }
    }
  }

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

- (void)_applySlotState:(NSArray<KKTimingSlot *> *)slots
           withParamAPI:(id<FxParameterRetrievalAPI_v6>)paramAPI
                 atTime:(CMTime)time {
  for (KKTimingSlot *slot in slots)
    slot.applyState(paramAPI, time);
}

- (void)timingGraphApplyState {
  if (!self.timingGraph)
    return;
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  CMTime t = [actionAPI currentTime];

  // Sync sequencer visibility and lane data.
  BOOL multiStageEnabled = NO;
  [paramGetAPI getBoolValue:&multiStageEnabled
              fromParameter:kKKParamMultiStageEnabled
                     atTime:t];
  KKStageSequencerView *seq = self.stageSequencer;
  NSView *seqContainer = self.stageSequencerContainer;
  if (seq) {
    seqContainer.hidden = !multiStageEnabled;
    self.timingGraph.hidden = multiStageEnabled;
    if (multiStageEnabled) {
      NSString *json = nil;
      [paramGetAPI getStringParameterValue:&json
                             fromParameter:kKKParamMultiStageData];
      NSArray<KKTimingLane *> *lanes = [KKTimingLane lanesFromJSON:json];
      if (lanes) {
        KKInstanceStateForAPI(self.apiManager).lanesSnapshot = [lanes copy];
        seq.lanes = lanes;
      }

      id<FxTimingAPI_v4> timingAPI =
          [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
      if (timingAPI) {
        CMTime effectStart = kCMTimeZero, effectDuration = kCMTimeZero;
        [timingAPI startTimeForEffect:&effectStart];
        [timingAPI durationTimeForEffect:&effectDuration];
        double durSec = CMTimeGetSeconds(effectDuration);
        seq.effectDuration = durSec;
        self.stageSequencerRuler.effectDuration = durSec;

        double startSec = CMTimeGetSeconds(effectStart);
        double nowSec = CMTimeGetSeconds(t);
        if (durSec > 0) {
          double frac = (nowSec - startSec) / durSec;
          seq.playheadFraction = frac;
          KKStagePlayheadView *ph =
              KKInstanceStateForAPI(self.apiManager).playheadView;
          ph.playheadFraction = frac;
        }
      }
    }
  }

  [self _applyTimingParamsToGraph:self.timingGraph
                     withParamAPI:paramGetAPI
                           atTime:t];
  [self _applySlotState:self.timingGraph.globalSlots
           withParamAPI:paramGetAPI
                 atTime:t];
  [self _applySlotState:self.timingGraph.inSectionSlots
           withParamAPI:paramGetAPI
                 atTime:t];
  [self _applySlotState:self.timingGraph.holdSectionSlots
           withParamAPI:paramGetAPI
                 atTime:t];
  [self _applySlotState:self.timingGraph.outSectionSlots
           withParamAPI:paramGetAPI
                 atTime:t];
  if (self.timingGraph.holdPropertyApplyState)
    self.timingGraph.holdPropertyApplyState(paramGetAPI, t);
  [actionAPI endAction:self];
}

- (void)_timingGraphSetAnimateEnabled:(BOOL)enabled
                         forParameter:(UInt32)paramID
                      disabledSection:(KKTimingGraphSection)section {
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  CMTime t = [actAPI currentTime];
  [setAPI setBoolValue:enabled toParameter:paramID atTime:t];
  if (!enabled) {
    int sel = KKTimingGraphSectionHold;
    id<FxParameterRetrievalAPI_v6> getAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    [getAPI getIntValue:&sel
          fromParameter:kKKParamTimingSelectedSection
                 atTime:t];
    if (sel == (int)section)
      [setAPI setIntValue:KKTimingGraphSectionHold
              toParameter:kKKParamTimingSelectedSection
                   atTime:t];
  }
  [actAPI endAction:self];
  [self timingGraphApplyState];
}

- (void)timingGraphSelectSection:(KKTimingGraphSection)section {
  if (section == KKTimingGraphSectionIn && !self.timingGraph.inEnabled)
    return;
  if (section == KKTimingGraphSectionOut && !self.timingGraph.outEnabled)
    return;

  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  [setAPI setIntValue:(int)section
          toParameter:kKKParamTimingSelectedSection
               atTime:[actAPI currentTime]];
  [actAPI endAction:self];
  [self timingGraphApplyState];
}

- (void)timingGraphSetIntValue:(int)value forParameter:(UInt32)paramID {
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  [setAPI setIntValue:value toParameter:paramID atTime:[actAPI currentTime]];
  [actAPI endAction:self];
  [self timingGraphApplyState];
}

- (void)timingGraphSetFloatValue:(double)value forParameter:(UInt32)paramID {
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  [setAPI setFloatValue:value toParameter:paramID atTime:[actAPI currentTime]];
  [actAPI endAction:self];
  [self timingGraphApplyState];
}

- (void)_mutateMultiStageSegmentAtLane:(NSInteger)laneIndex
                            segmentIdx:(NSInteger)segmentIndex
                                 using:(void (^)(KKTimingSegment *))mutator {
  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
  NSString *json = nil;
  [getAPI getStringParameterValue:&json fromParameter:kKKParamMultiStageData];
  NSMutableArray<KKTimingLane *> *lanes =
      [[KKTimingLane lanesFromJSON:json] mutableCopy];
  if (!lanes || (NSUInteger)laneIndex >= lanes.count) {
    [actAPI endAction:self];
    return;
  }
  KKTimingLane *lane = [lanes[laneIndex] copy];
  NSMutableArray<KKTimingSegment *> *segs = [lane.segments mutableCopy];
  if ((NSUInteger)segmentIndex >= segs.count) {
    [actAPI endAction:self];
    return;
  }
  KKTimingSegment *seg = [segs[segmentIndex] copy];
  mutator(seg);
  segs[segmentIndex] = seg;
  lane.segments = segs;
  lanes[laneIndex] = lane;

  NSString *updated = [KKTimingLane jsonFromLanes:lanes];
  if (updated)
    [setAPI setStringParameterValue:updated toParameter:kKKParamMultiStageData];
  [actAPI endAction:self];
  [self timingGraphApplyState];
}

- (void)_showSegmentEditPopoverForLane:(NSInteger)laneIndex
                            segmentIdx:(NSInteger)segmentIndex
                            anchorRect:(NSRect)anchorRect {
  KKStageSequencerView *seq = self.stageSequencer;
  if (!seq)
    return;

  // Snapshot current segment state for the popover.
  __block KKSegmentEditKind kind = KKSegmentEditKindTransition;
  __block NSInteger curveType = 0;
  __block double intensity = 0.5;
  __block double frequency = 0.5;
  __block uint32_t seed = 0;

  id<FxCustomParameterActionAPI_v4> actAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSString *json = nil;
  [getAPI getStringParameterValue:&json fromParameter:kKKParamMultiStageData];
  [actAPI endAction:self];

  NSArray<KKTimingLane *> *lanes = [KKTimingLane lanesFromJSON:json];
  if (!lanes || (NSUInteger)laneIndex >= lanes.count)
    return;
  KKTimingLane *lane = lanes[laneIndex];
  if ((NSUInteger)segmentIndex >= lane.segments.count)
    return;
  KKTimingSegment *seg = lane.segments[segmentIndex];

  kind = (seg.type == KKSegmentTypeHold) ? KKSegmentEditKindHold
                                         : KKSegmentEditKindTransition;
  curveType = (kind == KKSegmentEditKindHold) ? (NSInteger)seg.holdEffect
                                              : (NSInteger)seg.easing;
  intensity = seg.intensity;
  frequency = seg.frequency;
  seed = seg.seed;

  KKSegmentEditView *content = [[KKSegmentEditView alloc] initWithKind:kind];
  content.curveType = curveType;
  content.intensity = intensity;
  content.frequency = frequency;
  content.seed = seed;
  content.animateOut = (kind == KKSegmentEditKindTransition) &&
                       (segmentIndex == (NSInteger)lane.segments.count - 1);

  __weak typeof(self) weakSelf = self;
  content.onCurveTypeChanged = ^(NSInteger ct) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    [strongSelf _mutateMultiStageSegmentAtLane:laneIndex
                                    segmentIdx:segmentIndex
                                         using:^(KKTimingSegment *s) {
                                           if (s.type == KKSegmentTypeHold)
                                             s.holdEffect = (KKHoldEffect)ct;
                                           else
                                             s.easing = (KKEasingCurve)ct;
                                         }];
  };
  content.onIntensityChanged = ^(double v) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    [strongSelf _mutateMultiStageSegmentAtLane:laneIndex
                                    segmentIdx:segmentIndex
                                         using:^(KKTimingSegment *s) {
                                           s.intensity = v;
                                         }];
  };
  content.onFrequencyChanged = ^(double v) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    [strongSelf _mutateMultiStageSegmentAtLane:laneIndex
                                    segmentIdx:segmentIndex
                                         using:^(KKTimingSegment *s) {
                                           s.frequency = v;
                                         }];
  };
  content.onSeedChanged = ^(uint32_t newSeed) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    [strongSelf _mutateMultiStageSegmentAtLane:laneIndex
                                    segmentIdx:segmentIndex
                                         using:^(KKTimingSegment *s) {
                                           s.seed = newSeed;
                                         }];
  };
  __weak KKSegmentEditView *weakContent = content;
  content.onSeedReroll = ^{
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf)
      return;
    uint32_t newSeed = arc4random();
    [strongSelf _mutateMultiStageSegmentAtLane:laneIndex
                                    segmentIdx:segmentIndex
                                         using:^(KKTimingSegment *s) {
                                           s.seed = newSeed;
                                         }];
    weakContent.seed = newSeed;
  };

  NSViewController *vc = [[NSViewController alloc] init];
  vc.view = content;

  NSPopover *popover = [[NSPopover alloc] init];
  popover.behavior = NSPopoverBehaviorTransient;
  popover.animates = YES;
  popover.contentViewController = vc;
  popover.contentSize = content.frame.size;

  [self.segmentEditPopover close];
  self.segmentEditPopover = popover;

  [popover showRelativeToRect:anchorRect
                       ofView:seq
                preferredEdge:NSRectEdgeMaxY];
}

@end
