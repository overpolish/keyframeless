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

@interface KKScrollShadowView : NSView
@end
@implementation KKScrollShadowView
- (NSView *)hitTest:(NSPoint)point {
  return nil;
}
@end

@interface KKSequencerScrollView : NSScrollView
@end
@implementation KKSequencerScrollView
// AppKit calls this private method to find the ancestor scroll view that wants
// forwarded at-boundary scroll events. Returning nil makes the search fail, so
// FCP's OZViewCtrlRootScrollView never receives our overscroll and the
// inspector stays put.
- (NSResponder *)_recursiveResponderThatWantsForwardedScrollEventsForAxis:
                     (NSEventGestureAxis)axis
                                                         intendedForSwipe:
                                                             (BOOL)forSwipe {
  return nil;
}
@end

@interface KKRemoteWindowKeyHandlerView : NSView
@property(nonatomic, copy, nullable) void (^onTogglePlayback)(void);
@property(nonatomic, strong, nullable) id eventMonitor;
@end
@implementation KKRemoteWindowKeyHandlerView
- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (self.window && !self.eventMonitor) {
    __weak typeof(self) weakSelf = self;
    self.eventMonitor = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                     handler:^NSEvent *(NSEvent *evt) {
                                       __strong typeof(weakSelf) s = weakSelf;
                                       if (!s)
                                         return evt;
                                       if (evt.window == s.window &&
                                           [evt.charactersIgnoringModifiers
                                               isEqualToString:@" "] &&
                                           s.onTogglePlayback) {
                                         s.onTogglePlayback();
                                         return nil;
                                       }
                                       return evt;
                                     }];
  } else if (!self.window && self.eventMonitor) {
    [NSEvent removeMonitor:self.eventMonitor];
    self.eventMonitor = nil;
  }
}
- (void)dealloc {
  if (_eventMonitor)
    [NSEvent removeMonitor:_eventMonitor];
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

- (NSView *)_createTimingGraphViewUncapped:(BOOL)uncapped {
  NSArray<KKTimingSlot *> *globalSlots = [self timingGlobalSlots];
  NSArray<KKTimingSlot *> *inSlots =
      [self timingSlotsForSection:KKTimingGraphSectionIn];
  NSArray<KKTimingSlot *> *holdSlots =
      [self timingSlotsForSection:KKTimingGraphSectionHold];
  NSArray<KKTimingSlot *> *outSlots =
      [self timingSlotsForSection:KKTimingGraphSectionOut];

  NSArray<KKAnimatableProperty *> *seqProps = [self animatableProperties];
  CGFloat fullLanesH = [KKStageSequencerView heightForLaneCount:seqProps.count];
  CGFloat lanesH;
  if (uncapped || seqProps.count <= 2) {
    lanesH = fullLanesH;
  } else {
    CGFloat h2 = [KKStageSequencerView heightForLaneCount:2];
    CGFloat h3 = [KKStageSequencerView heightForLaneCount:3];
    lanesH = h2 + (h3 - h2) * 0.5;
  }
  CGFloat rulerH = [KKStageSequencerRulerView preferredHeight];
  // Top inset + ruler + lanes area (which has its own bottom inset).
  CGFloat seqContainerH = KKPaddingSM + rulerH + lanesH;
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

  if (!uncapped)
    self.timingGraph = graphView;

  // Stage sequencer container — sticky ruler + vertically-scrolled lanes
  // (capped at 2.5 lanes) with top/bottom shadow overlays. Hidden until
  // multi-stage is enabled.
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

  KKStageSequencerRulerView *rulerView =
      [[KKStageSequencerRulerView alloc] initWithFrame:NSZeroRect];
  rulerView.translatesAutoresizingMaskIntoConstraints = NO;
  [seqContainer addSubview:rulerView];

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

  KKStagePlayheadView *playheadView =
      [[KKStagePlayheadView alloc] initWithFrame:NSZeroRect];
  playheadView.translatesAutoresizingMaskIntoConstraints = NO;
  playheadView.rulerHeight = rulerH;
  playheadView.topPadding = KKPaddingSM;
  [seqContainer addSubview:playheadView];

  // Inspector mode: fixed height. Window mode: pin top+bottom and let the
  // container shrink with the wrapper — scroll view inside picks up the
  // overflow once the container is smaller than natural.
  NSMutableArray<NSLayoutConstraint *> *containerAnchorConstraints =
      [NSMutableArray arrayWithArray:@[
        [seqContainer.leadingAnchor
            constraintEqualToAnchor:wrapper.leadingAnchor
                           constant:KKInspectorHorizontalInset],
        [seqContainer.trailingAnchor
            constraintEqualToAnchor:wrapper.trailingAnchor
                           constant:-KKInspectorHorizontalInset],
        [seqContainer.topAnchor constraintEqualToAnchor:wrapper.topAnchor],
      ]];
  if (!uncapped) {
    [containerAnchorConstraints
        addObject:[seqContainer.heightAnchor
                      constraintEqualToConstant:seqContainerH]];
  }
  [NSLayoutConstraint activateConstraints:containerAnchorConstraints];
  [NSLayoutConstraint activateConstraints:@[

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

    [playheadView.leadingAnchor
        constraintEqualToAnchor:seqContainer.leadingAnchor],
    [playheadView.trailingAnchor
        constraintEqualToAnchor:seqContainer.trailingAnchor],
    [playheadView.topAnchor constraintEqualToAnchor:seqContainer.topAnchor],
    [playheadView.bottomAnchor
        constraintEqualToAnchor:seqContainer.bottomAnchor],
  ]];

  if (uncapped) {
    // Let the sequencer container stretch vertically with the wrapper so each
    // lane grows once all lanes are visible.
    [seqContainer.bottomAnchor constraintEqualToAnchor:wrapper.bottomAnchor
                                              constant:-KKPaddingLG]
        .active = YES;
  }

  if (!uncapped) {
    self.stageSequencer = seqView;
    self.stageSequencerContainer = seqContainer;
    self.stageSequencerRuler = rulerView;
    [self _registerMultiStageSequencerView:seqView
                                 rulerView:rulerView
                              playheadView:playheadView];
  } else {
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
    // Sync the newly-created secondary set with current state so it opens
    // showing the right data rather than an empty view.
    [self timingGraphApplyState];
  }

  [self _wireStageSequencerCallbacksFor:seqView
                              rulerView:rulerView
                           playheadView:playheadView];

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
        NSArray<NSNumber *> *baseVals =
            [prop readValuesWithGetAPI:paramGetAPI
                                atTime:[actionAPI currentTime]];
        if (!baseVals.count)
          baseVals = @[ @(1.0) ];
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
      KKPluginInstanceState *instState = KKInstanceStateForAPI(self.apiManager);
      instState.lanesSnapshot = [lanes copy];
      NSSet<NSString *> *hidden =
          [self hiddenAnimatablePropertyLabels] ?: [NSSet set];
      instState.hiddenLaneLabels = hidden;
      seqView.lanes = KKFilterLanesForVisibility(lanes, hidden);
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

- (void)_applyStateToTimingGraph:(KKTimingGraphView *)graph
                         seqView:(KKStageSequencerView *)seq
                    seqContainer:(NSView *)seqContainer
                           ruler:(KKStageSequencerRulerView *)ruler
                        playhead:(KKStagePlayheadView *)playhead
                    multiEnabled:(BOOL)multiStageEnabled
                           lanes:(NSArray<KKTimingLane *> *)lanes
                    effectDurSec:(double)durSec
                    playheadFrac:(double)frac
                       hasTiming:(BOOL)hasTiming
                    withParamAPI:(id<FxParameterRetrievalAPI_v6>)paramGetAPI
                          atTime:(CMTime)t {
  if (!graph)
    return;
  if (seq) {
    seqContainer.hidden = !multiStageEnabled;
    graph.hidden = multiStageEnabled;
    if (multiStageEnabled) {
      if (lanes) {
        NSSet<NSString *> *hidden =
            [self hiddenAnimatablePropertyLabels] ?: [NSSet set];
        seq.lanes = KKFilterLanesForVisibility(lanes, hidden);
      }
      if (hasTiming) {
        seq.effectDuration = durSec;
        ruler.effectDuration = durSec;
        if (durSec > 0) {
          seq.playheadFraction = frac;
          playhead.playheadFraction = frac;
        }
      }
    }
  }

  [self _applyTimingParamsToGraph:graph withParamAPI:paramGetAPI atTime:t];
  [self _applySlotState:graph.globalSlots withParamAPI:paramGetAPI atTime:t];
  [self _applySlotState:graph.inSectionSlots withParamAPI:paramGetAPI atTime:t];
  [self _applySlotState:graph.holdSectionSlots
           withParamAPI:paramGetAPI
                 atTime:t];
  [self _applySlotState:graph.outSectionSlots
           withParamAPI:paramGetAPI
                 atTime:t];
  if (graph.holdPropertyApplyState)
    graph.holdPropertyApplyState(paramGetAPI, t);
}

- (void)timingGraphApplyState {
  KKPluginInstanceState *instState = KKInstanceStateForAPI(self.apiManager);
  if (!self.timingGraph && instState.additionalTimingViews.count == 0)
    return;
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  CMTime t = [actionAPI currentTime];

  // Read the shared state once and broadcast to every registered view set.
  BOOL multiStageEnabled = NO;
  [paramGetAPI getBoolValue:&multiStageEnabled
              fromParameter:kKKParamMultiStageEnabled
                     atTime:t];

  // Push loop state to every ruler unconditionally. The sync pump's early-
  // out skips pushing when state.loopEnabled is already correct, which
  // leaves freshly-opened window rulers out of date. Doing it here matches
  // how lane data is pushed — once per view set, every apply tick.
  BOOL loopEnabled = instState.loopEnabled;
  self.stageSequencerRuler.loopEnabled = loopEnabled;
  for (KKTimingViewRefs *refs in instState.additionalTimingViews)
    refs.ruler.loopEnabled = loopEnabled;

  NSArray<KKTimingLane *> *lanes = nil;
  if (multiStageEnabled) {
    NSString *json = nil;
    [paramGetAPI getStringParameterValue:&json
                           fromParameter:kKKParamMultiStageData];
    lanes = [KKTimingLane lanesFromJSON:json];
    if (lanes)
      KKInstanceStateForAPI(self.apiManager).lanesSnapshot = [lanes copy];
  }

  double durSec = 0, frac = 0;
  BOOL hasTiming = NO;
  if (multiStageEnabled) {
    id<FxTimingAPI_v4> timingAPI =
        [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
    if (timingAPI) {
      CMTime effectStart = kCMTimeZero, effectDuration = kCMTimeZero;
      [timingAPI startTimeForEffect:&effectStart];
      [timingAPI durationTimeForEffect:&effectDuration];
      durSec = CMTimeGetSeconds(effectDuration);
      if (durSec > 0)
        frac = (CMTimeGetSeconds(t) - CMTimeGetSeconds(effectStart)) / durSec;
      hasTiming = YES;
    }
  }

  // Primary (inspector) set.
  [self _applyStateToTimingGraph:self.timingGraph
                         seqView:self.stageSequencer
                    seqContainer:self.stageSequencerContainer
                           ruler:self.stageSequencerRuler
                        playhead:KKInstanceStateForAPI(self.apiManager)
                                     .playheadView
                    multiEnabled:multiStageEnabled
                           lanes:lanes
                    effectDurSec:durSec
                    playheadFrac:frac
                       hasTiming:hasTiming
                    withParamAPI:paramGetAPI
                          atTime:t];

  // Secondary (window) sets. Prune any dead (deallocated) entries.
  NSMutableArray *pruned = [NSMutableArray array];
  for (KKTimingViewRefs *refs in instState.additionalTimingViews) {
    if (!refs.isAlive)
      continue;
    [pruned addObject:refs];
    [self _applyStateToTimingGraph:refs.graphView
                           seqView:refs.seqView
                      seqContainer:refs.seqContainer
                             ruler:refs.ruler
                          playhead:refs.playhead
                      multiEnabled:multiStageEnabled
                             lanes:lanes
                      effectDurSec:durSec
                      playheadFrac:frac
                         hasTiming:hasTiming
                      withParamAPI:paramGetAPI
                            atTime:t];
  }
  instState.additionalTimingViews = pruned;

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
                            anchorRect:(NSRect)anchorRect
                            sourceView:(KKStageSequencerView *)sourceView {
  KKStageSequencerView *seq = sourceView ?: self.stageSequencer;
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
  KKPluginInstanceState *state = KKInstanceStateForAPI(self.apiManager);
  // Translate view index → JSON index up front; forward the JSON index to
  // every callback below so they don't have to repeat the translation.
  NSInteger jsonLaneIdx =
      KKLaneJSONIndexForViewIndex(laneIndex, lanes, state.hiddenLaneLabels);
  if (!lanes || jsonLaneIdx < 0)
    return;
  laneIndex = jsonLaneIdx;
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
