/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "../Math/KKEasing.h"
#import "../Style/KKTokens.h"
#import "../Views/KKAlertView.h"
#import "../Views/KKCustomGroupHeaderView.h"
#import "../Views/KKSeparatorView.h"
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

  if (parameterID == kKKParamColorCustomUI)
    return [self _createColorCustomUI:parameterID];

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

static CGFloat KKTotalSlotHeight(NSArray<KKTimingSlot *> *slots) {
  CGFloat h = 0;
  for (KKTimingSlot *s in slots)
    h += s.height;
  return h;
}

- (NSView *)_createTimingGraphView {
  // pill(24) + ticks(16) + spacing(8) + graph(60) + labels(20) + slider(28) +
  // ticks(16)
  static const CGFloat kBaseHeight = 172.0;

  NSArray<KKTimingSlot *> *globalSlots = [self timingGlobalSlots];
  NSArray<KKTimingSlot *> *inSlots =
      [self timingSlotsForSection:KKTimingGraphSectionIn];
  NSArray<KKTimingSlot *> *holdSlots =
      [self timingSlotsForSection:KKTimingGraphSectionHold];
  NSArray<KKTimingSlot *> *outSlots =
      [self timingSlotsForSection:KKTimingGraphSectionOut];

  CGFloat globalHeight = KKTotalSlotHeight(globalSlots);
  CGFloat maxSectionHeight =
      MAX(KKTotalSlotHeight(inSlots),
          MAX(KKTotalSlotHeight(holdSlots), KKTotalSlotHeight(outSlots)));
  CGFloat slotHeight = globalHeight + maxSectionHeight;
  CGFloat totalHeight =
      kBaseHeight + (slotHeight > 0 ? KKPaddingSM + slotHeight : 0);

  NSView *wrapper =
      [[NSView alloc] initWithFrame:NSMakeRect(0, 0, 300, totalHeight)];
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

  self.timingGraph = graphView;

  [actionAPI startAction:self];
  CMTime t = [actionAPI currentTime];
  [self _applySlotState:globalSlots withParamAPI:paramGetAPI atTime:t];
  [self _applySlotState:inSlots withParamAPI:paramGetAPI atTime:t];
  [self _applySlotState:holdSlots withParamAPI:paramGetAPI atTime:t];
  [self _applySlotState:outSlots withParamAPI:paramGetAPI atTime:t];
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
