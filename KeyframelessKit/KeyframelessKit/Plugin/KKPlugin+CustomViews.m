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
#import "../Views/KKSeparatorView.h"
#import "../Views/KKStageSequencerView.h"

extern NSArray<KKTimingLane *> *KKMultiStageLanesSnapshot;
extern NSArray<KKTimingLane *> *KKMultiStagePendingLanes;
extern void KKSetMultiStageSequencerView(KKStageSequencerView *_Nullable view);
extern KKStageSequencerView *_Nullable KKGetMultiStageSequencerView(void);
extern BOOL KKMultiStageSelectionInProgress;
#import "../Views/KKAnimatableProperty.h"
#import "../Views/KKPillToggleRowView.h"
#import "../Views/KKTimingGraphView.h"
#import "../Views/KKTimingSlot.h"
#import "../Views/KKUpdateBannerView.h"
#import "KKConstants.h"
#import "KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>

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
  CGFloat seqHeight = 10.0 + 10.0 + seqProps.count * (30.0 + 10.0) +
                      (seqProps.count - 1) * 2.0 + 2 * KKPaddingSM;
  CGFloat wrapperHeight = seqHeight + KKPaddingLG;

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

  // Stage sequencer — sits below graph, hidden until multi-stage is enabled.
  KKStageSequencerView *seqView =
      [[KKStageSequencerView alloc] initWithFrame:NSZeroRect];
  seqView.translatesAutoresizingMaskIntoConstraints = NO;
  seqView.hidden = YES;
  [wrapper addSubview:seqView];
  [NSLayoutConstraint activateConstraints:@[
    [seqView.leadingAnchor constraintEqualToAnchor:wrapper.leadingAnchor
                                          constant:KKInspectorHorizontalInset],
    [seqView.trailingAnchor
        constraintEqualToAnchor:wrapper.trailingAnchor
                       constant:-KKInspectorHorizontalInset],
    [seqView.topAnchor constraintEqualToAnchor:wrapper.topAnchor],
    [seqView.heightAnchor constraintEqualToConstant:seqHeight],
  ]];
  self.stageSequencer = seqView;
  KKSetMultiStageSequencerView(seqView);

  seqView.onSegmentSelected = ^(NSInteger laneIndex, NSInteger segmentIndex) {
    __strong typeof(weakSelf) strongSelf = weakSelf;
    if (!strongSelf || laneIndex < 0)
      return;
    KKMultiStageSelectionInProgress = YES;
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
    KKMultiStageLanesSnapshot = [lanes copy];
    KKMultiStagePendingLanes = nil;

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
    KKMultiStageSelectionInProgress = NO;
    [strongSelf timingGraphApplyState];
  };

  seqView.onLaneToggled = ^(NSInteger laneIndex, BOOL enabled) {
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
    }
    [actAPI endAction:strongSelf];
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

  seqView.onPlayheadScrub = ^(double fraction) {
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
    seqView.hidden = NO;
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
      KKMultiStageLanesSnapshot = [lanes copy];
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
      double startSec = CMTimeGetSeconds(effectStart);
      double nowSec = CMTimeGetSeconds([actionAPI currentTime]);
      if (durSec > 0)
        seqView.playheadFraction = (nowSec - startSec) / durSec;
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
  if (seq) {
    seq.hidden = !multiStageEnabled;
    self.timingGraph.hidden = multiStageEnabled;
    if (multiStageEnabled) {
      NSString *json = nil;
      [paramGetAPI getStringParameterValue:&json
                             fromParameter:kKKParamMultiStageData];
      NSArray<KKTimingLane *> *lanes = [KKTimingLane lanesFromJSON:json];
      if (lanes) {
        KKMultiStageLanesSnapshot = [lanes copy];
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

        double startSec = CMTimeGetSeconds(effectStart);
        double nowSec = CMTimeGetSeconds(t);
        if (durSec > 0)
          seq.playheadFraction = (nowSec - startSec) / durSec;
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

@end
