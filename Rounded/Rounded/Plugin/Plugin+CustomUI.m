/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import "RoundedInspectorView+Guides.h"
#import "RoundedInspectorView.h"
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKHelpSection.h>
#import <KeyframelessKit/KKTimingStage.h>

@implementation RoundedPlugin (CustomUI)

- (BOOL)usesMotionBlur {
  return YES;
}

+ (NSArray<KKLane *> *)availableLanes {
  KKLane *radius = [KKLane laneWithLabel:@"Radius"];
  radius.valueType = KKLaneValueTypeFloat;
  radius.componentMin = @[ @0.0 ];
  radius.componentMax = @[ @100.0 ];

  KKLane *box = [KKLane laneWithLabel:@"Box"];
  box.valueType = KKLaneValueTypeBox;
  box.componentMin = @[ @0.0, @0.0, @-0.5, @-0.5 ];
  box.componentMax = @[ @1.0, @1.0, @0.5, @0.5 ];

  return @[ radius, box ];
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kParamInspectorUI) {
    id<FxCustomParameterActionAPI_v4> actionAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actionAPI startAction:self];
    id<FxParameterRetrievalAPI_v6> getAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];

    NSString *uiJson = KKReadCustomParamString(getAPI, kParamUIState);
    NSDictionary *uiState =
        uiJson.length
            ? [NSJSONSerialization
                  JSONObjectWithData:[uiJson
                                         dataUsingEncoding:NSUTF8StringEncoding]
                             options:0
                               error:nil]
                  ?: @{}
            : @{};
    BOOL loopEnabled = [uiState[@"loopEnabled"] boolValue];
    NSInteger activeTab = [uiState[@"activeTab"] integerValue];

    NSString *timelineJson =
        KKReadCustomParamString(getAPI, kKKParamTimelineData);
    KKTimeline *timeline =
        (timelineJson.length ? [KKTimeline timelineFromJSON:timelineJson] : nil)
            ?: [KKTimeline timeline];

    [actionAPI endAction:self];

    NSArray<KKLane *> *available = [RoundedPlugin availableLanes];
    RoundedInspectorView *view =
        [[RoundedInspectorView alloc] initWithAPIManager:self.apiManager
                                             loopEnabled:loopEnabled
                                               activeTab:activeTab
                                          availableLanes:available
                                                timeline:timeline];
    __weak typeof(self) weak = self;

    view.onLoopToggled = ^(BOOL enabled) {
      __strong typeof(weak) strong = weak;
      if (!strong)
        return;
      [strong patchUIStateKey:@"loopEnabled"
                        value:@(enabled)
                      paramID:kParamUIState];
    };
    view.onTabChanged = ^(NSInteger tab) {
      __strong typeof(weak) strong = weak;
      if (!strong)
        return;
      [strong patchUIStateKey:@"activeTab" value:@(tab) paramID:kParamUIState];
    };
    view.onTimelineMutated = ^(KKTimeline *updated) {
      __strong typeof(weak) strong = weak;
      if (!strong)
        return;
      id<FxCustomParameterActionAPI_v4> act = [strong.apiManager
          apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
      if (!act)
        return;
      [act startAction:strong];
      id<FxParameterSettingAPI_v5> setAPI = [strong.apiManager
          apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
      NSString *json = [KKTimeline jsonFromTimeline:updated];
      if (json)
        KKWriteCustomParamString(setAPI, json, kKKParamTimelineData);
      [act endAction:strong];
    };

    view.effectHeaderRectProvider = ^NSRect {
      __strong typeof(weak) strong = weak;
      return strong ? [strong effectHeaderScreenRect] : NSZeroRect;
    };

    self.inspectorView = view;
    return view;
  }
  typedef NSView *(*ViewIMP)(id, SEL, UInt32);
  ViewIMP imp = (ViewIMP)[KKPlugin instanceMethodForSelector:_cmd];
  return imp(self, _cmd, parameterID);
}

- (NSArray<KKHelpGuide *> *)helpGuides {
  __weak typeof(self) weak = self;
  __block __weak KKHelpGuide *weakIntro = nil;
  KKHelpGuide *intro =
      [KKHelpGuide guideWithTitle:@"Introduction"
                         subtitle:@"Walk through the basics again"
                          onStart:^{
                            __strong typeof(weak) strong = weak;
                            strong.inspectorView.onGuideCompleted = ^{
                              [weakIntro markCompleted];
                            };
                            [strong.inspectorView restartIntroGuide];
                          }];
  weakIntro = intro;

  __block __weak KKHelpGuide *weakOSC = nil;
  KKHelpGuide *osc =
      [KKHelpGuide guideWithTitle:@"OSC Basics"
                         subtitle:@"Learn how the on-screen control works"
                          onStart:^{
                            __strong typeof(weak) strong = weak;
                            // This guide teaches the drag — require actually
                            // reaching the target before it advances.
                            strong.inspectorView.oscGuideRequireTargetHit = YES;
                            strong.inspectorView.onGuideCompleted = ^{
                              [weakOSC markCompleted];
                            };
                            [strong.inspectorView restartOSCGuide];
                          }];
  weakOSC = osc;
  osc.enabledProvider = ^BOOL {
    return RoundedHasCanvasReference();
  };
  osc.disabledSubtitle =
      @"Select a Rounded clip or, if it's already selected, move the "
      @"mouse over the viewer";
  // OSC guide has a zoom-to-fit + settle warm-up; spin the play button until
  // the overlay is actually on screen.
  osc.activeProvider = ^BOOL {
    __strong typeof(weak) strong = weak;
    return strong.inspectorView.oscGuideActive;
  };

  __block __weak KKHelpGuide *weakFull = nil;
  KKHelpGuide *full =
      [KKHelpGuide guideWithTitle:@"Full Walkthrough"
                         subtitle:@"Inspector and on-screen control, end to end"
                          onStart:^{
                            __strong typeof(weak) strong = weak;
                            // Ends on the OSC drag — enforce landing on the
                            // target, same as the standalone OSC guide.
                            strong.inspectorView.oscGuideRequireTargetHit = YES;
                            strong.inspectorView.onGuideCompleted = ^{
                              [weakFull markCompleted];
                            };
                            [strong.inspectorView restartFullWalkthroughGuide];
                          }];
  weakFull = full;
  // Starts on the inspector but ends in the viewer, so it needs the canvas
  // reference just like the OSC guide. No activeProvider: the zoom-to-fit
  // warm-up is mid-guide (entering the OSC portion), not at start, so there's
  // nothing to spin the play button for.
  full.enabledProvider = ^BOOL {
    return RoundedHasCanvasReference();
  };
  full.disabledSubtitle =
      @"Select a Rounded clip or, if it's already selected, move the "
      @"mouse over the viewer";
  return @[ intro, osc, full ];
}

- (NSNotificationName)helpGuideRefreshNotificationName {
  return kRoundedOSCPositionNotification;
}

- (NSArray<KKHelpSection *> *)helpSections {
  KKHelpSection *rounded = [KKHelpSection
      sectionWithTitle:@"Rounded"
             tipMarkup:@[
               (@"Round the corners of any clip with an animatable "
                @"<accent>Radius</accent>."),
               (@"<accent>Box</accent> crops and positions the clip — "
                @"animate it to reveal or hide content over time."),
             ]
             shortcuts:nil];
  rounded.icon = [NSImage imageWithSystemSymbolName:@"square.dotted"
                           accessibilityDescription:nil];
  return @[ rounded ];
}

@end
