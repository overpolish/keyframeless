/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "MagicMoveLocalized.h"
#import "MagicMoveMiniCanvasRenderer.h"
#import "OSC.h"
#import "Plugin_Private.h"
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KeyframelessKit.h>

/// MagicMove draws Position + Rotation on-screen controls, so it opts into the
/// inspector's "On-Screen Controls" visibility row (other plugins default off).
@interface MagicMoveInspectorView : KKTimelineInspectorView
@end

@implementation MagicMoveInspectorView
- (BOOL)showsOSCVisibilityRow {
  return YES;
}
@end

@implementation MagicMovePlugin (CustomUI)

- (BOOL)usesMotionBlur {
  return YES;
}

- (KKClipWrappingMode)clipWrappingMode {
  return KKClipWrappingModeCompound;
}

+ (NSArray<KKLane *> *)availableLanes {
  KKLane *position = [KKLane laneWithLabel:@"Position"];
  position.valueType = KKLaneValueTypeGeneric;
  // Position is allowed off-canvas, so no min/max - empty = unconstrained.
  position.componentMin = @[];
  position.componentMax = @[];
  position.componentUnits = @[ @"px", @"px" ];
  position.componentLabels = @[ @"X", @"Y" ];
  // 2D spatial path: keyposes can be smooth (curved). Lights the per-keypose
  // corner/smooth toggle in the value popover and curves the motion path.
  position.spatialCurvable = YES;
  [position insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.5, @0.5 ]]];

  KKLane *rotation = [KKLane laneWithLabel:@"Rotation"];
  rotation.valueType = KKLaneValueTypeAngle;
  // Knobs cover one revolution visually but model values accumulate past
  // 360° (FCP behaviour - 2 full turns = 720°). Empty min/max = unconstrained.
  rotation.componentMin = @[];
  rotation.componentMax = @[];
  rotation.componentUnits = @[ @"°", @"°", @"°" ];
  rotation.componentLabels = @[ @"X", @"Y", @"Z" ];
  // Standard 3D-axis tint convention (Motion / Blender / Maya): X=red,
  // Y=green, Z=blue. Slightly desaturated so they don't shout against the
  // inspector background.
  rotation.componentLabelColors = @[
    [NSColor colorWithSRGBRed:0.95 green:0.35 blue:0.35 alpha:1.0],
    [NSColor colorWithSRGBRed:0.40 green:0.85 blue:0.45 alpha:1.0],
    [NSColor colorWithSRGBRed:0.40 green:0.60 blue:0.95 alpha:1.0],
  ];
  [rotation insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                            values:@[ @0.0, @0.0, @0.0 ]]];

  KKLane *scale = [KKLane laneWithLabel:@"Scale"];
  scale.valueType = KKLaneValueTypeFloat;
  // Percentage of the clip's own size; 100 = identity. Floor at 0 (no flip),
  // no upper cap (empty max = unconstrained), same as Position's open fields.
  scale.componentMin = @[ @0.0, @0.0 ];
  scale.componentMax = @[];
  scale.componentUnits = @[ @"%", @"%" ];
  scale.componentLabels = @[ @"X", @"Y" ];
  scale.integerValued = YES; // whole percentages only

  // Aspect lock: link glyph in the value popover, on by default (most apps
  // constrain proportions out of the box). Preserves the current X:Y ratio.
  scale.aspectLinkable = YES;
  scale.aspectLinked = YES;
  [scale insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                         values:@[ @100.0, @100.0 ]]];

  KKLane *opacity = [KKLane laneWithLabel:@"Opacity"];
  opacity.valueType = KKLaneValueTypeFloat;
  // Percentage like FCP's opacity control; 100 = fully opaque. Hard 0-100
  // bounds (unlike Scale's open top) - there's no meaningful overshoot.
  opacity.componentMin = @[ @0.0 ];
  opacity.componentMax = @[ @100.0 ];
  opacity.componentUnits = @[ @"%" ];
  opacity.integerValued = YES; // whole percentages only
  [opacity insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @100.0 ]]];

  KKLane *anchor = [KKLane laneWithLabel:@"Anchor"];
  anchor.valueType = KKLaneValueTypeGeneric;
  // The pivot rotation and scale swing around, in the same normalized object
  // space as Position (0.5,0.5 = clip center). No min/max - the anchor can sit
  // off the clip just like Position can go off-canvas.
  anchor.componentMin = @[];
  anchor.componentMax = @[];
  anchor.componentUnits = @[ @"px", @"px" ];
  anchor.componentLabels = @[ @"X", @"Y" ];
  [anchor insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @0.5, @0.5 ]]];

  return @[ position, scale, rotation, opacity, anchor ];
}

+ (NSArray<NSArray<NSString *> *> *)oscCompounds {
  return @[
    @[ @"Position" ],
    @[ @"Path" ],
    @[ @"Scale" ],
    @[ @"Rotation", @"Rotation.X", @"Rotation.Y", @"Rotation.Z" ],
    @[ @"Anchor" ],
  ];
}

+ (NSArray<NSString *> *)oscElementKeys {
  NSMutableArray<NSString *> *flat = [NSMutableArray array];
  for (NSArray<NSString *> *c in [self oscCompounds])
    [flat addObjectsFromArray:c];
  return flat;
}

- (void)applyOSCElementsFromUIState:(NSDictionary *)uiState {
  [self kkApplyOSCVisibilityFromState:uiState
                          elementKeys:[MagicMovePlugin oscElementKeys]
                             renderer:self.miniCanvasRenderer];
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID != kParamInspectorUI) {
    typedef NSView *(*ViewIMP)(id, SEL, UInt32);
    ViewIMP imp = (ViewIMP)[KKPlugin instanceMethodForSelector:_cmd];
    return imp(self, _cmd, parameterID);
  }

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
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
  // On-screen-control master visibility: default visible when the key is
  // absent (existing clips have never written it).
  BOOL oscMasterVisible = uiState[@"oscMasterVisible"]
                              ? [uiState[@"oscMasterVisible"] boolValue]
                              : YES;
  KKMiniCanvasRenderMode renderMode = KKMiniCanvasRenderModeOff;
  if (uiState[@"renderMode"])
    renderMode = (KKMiniCanvasRenderMode)[uiState[@"renderMode"] integerValue];

  NSString *mbJson = KKReadCustomParamString(getAPI, kKKParamMotionBlurData);
  NSDictionary *mbState =
      (mbJson.length
           ? [NSJSONSerialization
                 JSONObjectWithData:[mbJson
                                        dataUsingEncoding:NSUTF8StringEncoding]
                            options:0
                              error:nil]
           : nil)
          ?: @{};
  BOOL motionBlurEnabled = [mbState[@"enabled"] boolValue];
  double motionBlurShutterAngle =
      mbState[@"shutterAngle"] ? [mbState[@"shutterAngle"] doubleValue] : 180.0;
  NSInteger motionBlurSamples =
      mbState[@"samples"] ? [mbState[@"samples"] integerValue] : 16;
  NSInteger motionBlurMode =
      mbState[@"mode"] ? [mbState[@"mode"] integerValue] : 0;

  NSString *timelineJson =
      KKReadCustomParamString(getAPI, kKKParamTimelineData);
  KKTimeline *timeline =
      (timelineJson.length ? [KKTimeline timelineFromJSON:timelineJson] : nil)
          ?: [KKTimeline timeline];
  timeline = [self timelineStampedWithClipDuration:timeline];

  // Cold-boot seed for the OSC. Without this the first drawOSC tick after FCP
  // relaunch reads nil → handle snaps to (0.5, 0.5) regardless of saved state.
  KKSetProcessTimelineSnapshot(timeline);
  // Per-instance OSC visibility lives in KKPluginInstanceState (the OSC reads
  // it via the shared kKKParamInstanceID UUID, NOT a process singleton, so two
  // instances on one clip stay independent). Ensure mints the UUID here, inside
  // the action scope where the setting API resolves.
  KKPluginInstanceState *instState =
      KKInstanceStateEnsureForAPI(self.apiManager);
  instState.oscMasterVisible = oscMasterVisible;

  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  double seedFrameDurSec = 0.0;
  double seedClipDurSec = 0.0;
  if (timingAPI) {
    CMTime frameDur = kCMTimeZero, clipDur = kCMTimeZero;
    [timingAPI frameDuration:&frameDur];
    [timingAPI durationTimeForEffect:&clipDur];
    seedFrameDurSec = CMTimeGetSeconds(frameDur);
    seedClipDurSec = CMTimeGetSeconds(clipDur);
    if (seedFrameDurSec > 0)
      KKSetProcessFrameDurationSeconds(seedFrameDurSec);
  }

  [actionAPI endAction:self];

  NSArray<KKLane *> *available = [MagicMovePlugin availableLanes];
  KKTimelineInspectorView *view =
      [[MagicMoveInspectorView alloc] initWithAPIManager:self.apiManager
                                             loopEnabled:loopEnabled
                                               activeTab:activeTab
                                          availableLanes:available
                                                timeline:timeline];

  if (!self.miniCanvasRenderer) {
    self.miniCanvasRenderer = [[MagicMoveMiniCanvasRenderer alloc] init];
  }
  self.miniCanvasRenderer.timeline = timeline;
  self.miniCanvasRenderer.handlesHidden = !oscMasterVisible;
  [self applyOSCElementsFromUIState:uiState];
  // Wire the master tick + per-element pills + mini-canvas opt-click in one
  // call (shared glue in KKPlugin (OSCVisibility)).
  [self kkWireOSCVisibilityForView:view
                          renderer:self.miniCanvasRenderer
                         compounds:[MagicMovePlugin oscCompounds]
                           paramID:kParamUIState];
  view.miniCanvasDelegate = self.miniCanvasRenderer;
  view.miniCanvasDescriptorPath = MagicMoveMiniCanvasDescriptorPath;
  view.miniCanvasRequestPath = MagicMoveMiniCanvasRequestPath;
  if (seedClipDurSec > 0)
    [view setClipDurationSeconds:seedClipDurSec];
  if (seedFrameDurSec > 0)
    [view setFrameDurationSeconds:seedFrameDurSec];
  [view setMotionBlurEnabled:motionBlurEnabled];
  [view setMotionBlurShutterAngle:motionBlurShutterAngle
                          samples:motionBlurSamples];
  [view setMotionBlurMode:(KKMotionBlurMode)motionBlurMode];
  [view setRenderMode:renderMode];
  [view setOSCVisible:oscMasterVisible];

  __weak typeof(self) weak = self;

  view.onRenderModeChanged = ^(KKMiniCanvasRenderMode mode) {
    __strong typeof(weak) strong = weak;
    if (!strong)
      return;
    [strong patchUIStateKey:@"renderMode"
                      value:@((NSInteger)mode)
                    paramID:kParamUIState];
  };

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
  view.onMotionBlurChanged = ^(BOOL enabled, double shutterAngle,
                               NSInteger samples, KKMotionBlurMode mode) {
    __strong typeof(weak) strong = weak;
    if (!strong)
      return;
    id<FxCustomParameterActionAPI_v4> act = [strong.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    if (!act)
      return;
    [act startAction:strong];
    id<FxParameterSettingAPI_v5> setAPI =
        [strong.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    NSDictionary *mb = @{
      @"enabled" : @(enabled),
      @"shutterAngle" : @(shutterAngle),
      @"samples" : @(samples),
      @"mode" : @((NSInteger)mode)
    };
    NSData *data = [NSJSONSerialization dataWithJSONObject:mb
                                                   options:0
                                                     error:nil];
    NSString *json = [[NSString alloc] initWithData:data
                                           encoding:NSUTF8StringEncoding];
    if (json)
      KKWriteCustomParamString(setAPI, json, kKKParamMotionBlurData);
    [act endAction:strong];
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
    id<FxParameterSettingAPI_v5> setAPI =
        [strong.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    NSString *json = [KKTimeline jsonFromTimeline:updated];
    if (json)
      KKWriteCustomParamString(setAPI, json, kKKParamTimelineData);
    [act endAction:strong];
  };
  // Mini-canvas motion-path edits (anchor / handle drag) persist the whole
  // blob through the same writer as inspector timeline mutations.
  self.miniCanvasRenderer.onTimelinePersist = view.onTimelineMutated;
  view.onDragBegin = ^{
    __strong typeof(weak) strong = weak;
    if (!strong)
      return;
    id<FxCustomParameterActionAPI_v4> act = [strong.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    if (!act)
      return;
    [act startAction:strong];
    strong.miniDragUndoStarted =
        KKBeginUndoGroup(strong.apiManager, @"Adjust Magic Move");
    [act endAction:strong];
  };
  view.onDragEnd = ^{
    __strong typeof(weak) strong = weak;
    if (!strong)
      return;
    id<FxCustomParameterActionAPI_v4> act = [strong.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    if (act)
      [act startAction:strong];
    KKEndUndoGroup(strong.apiManager, strong.miniDragUndoStarted);
    if (act)
      [act endAction:strong];
    strong.miniDragUndoStarted = NO;
  };
  view.onBoundaryPreviewNeedsRender = ^{
    __strong typeof(weak) strong = weak;
    if (!strong)
      return;
    id<FxCustomParameterActionAPI_v4> act = [strong.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    if (!act)
      return;
    [act startAction:strong];
    id<FxParameterSettingAPI_v5> setAPI =
        [strong.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
    NSString *nonce = [[NSUUID UUID] UUIDString];
    KKWriteCustomParamString(setAPI, nonce, kParamRenderNudge);
    [act endAction:strong];
  };
  view.onScrub = ^(double frac) {
    __strong typeof(weak) strong = weak;
    if (!strong)
      return;
    id<FxCustomParameterActionAPI_v4> act = [strong.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    if (!act)
      return;
    [act startAction:strong];
    id<FxTimingAPI_v4> timing =
        [strong.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
    id<FxCommandAPI_v2> cmd =
        [strong.apiManager apiForProtocol:@protocol(FxCommandAPI_v2)];
    CMTime es = kCMTimeZero, ed = kCMTimeZero;
    [timing startTimeForEffect:&es];
    [timing durationTimeForEffect:&ed];
    double dsec = CMTimeGetSeconds(ed);
    double base;
    if ([KKHostInfo isRunningInFinalCut]) {
      CMTime src = kCMTimeZero, tl = kCMTimeZero;
      [timing startTimeOfInputToFilter:&src];
      [timing timelineTime:&tl fromInputTime:src];
      base = CMTimeGetSeconds(tl);
    } else {
      base = CMTimeGetSeconds(es);
    }
    if (dsec > 0.0)
      [cmd movePlayheadToTime:CMTimeMakeWithSeconds(base + frac * dsec, 600)
                        error:nil];
    [act endAction:strong];
  };
  view.onTogglePlayback = ^{
    __strong typeof(weak) strong = weak;
    if (!strong)
      return;
    id<FxCustomParameterActionAPI_v4> act = [strong.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    if (!act)
      return;
    [act startAction:strong];
    id<FxCommandAPI_v2> cmd =
        [strong.apiManager apiForProtocol:@protocol(FxCommandAPI_v2)];
    [cmd performCommand:kFxCommand_TogglePlayback error:nil];
    [act endAction:strong];
  };
  view.onToggleDetached = ^{
    __strong typeof(weak) strong = weak;
    if (!strong)
      return;
    KKTimelineInspectorView *insp = strong.inspectorView;
    if (!insp)
      return;
    if (insp.hasDetachedWindow) {
      [strong closeRemoteWindowIfSupported];
      return;
    }
    [strong presentRemoteWindowOfSize:CGSizeMake(720.0, 460.0)
                      contentProvider:^NSView * {
                        return [insp beginDetachedCopy];
                      }];
  };

  // Rotate-with-motion: per-interval toggle on the Position lane's gap
  // popovers (curve + hold-modulation, Advanced + Basic). Persisted under
  // the interval's userProperties dict. Disabled (and ignored) when the
  // gap has no actual motion - linear curves with no modulation produce no
  // tangent to rotate along.
  view.gapPopoverExtraRows = ^NSArray<NSView *> *(
      KKGapPopoverPhase phase, NSString *laneLabel, KKInterval *rep,
      KKGapIntervalReader read, KKGapIntervalMutator mutate) {
    if (![laneLabel isEqualToString:@"Position"])
      return @[];
    KKCheckboxRowView *row = [[KKCheckboxRowView alloc]
        initWithTitle:MMLoc(@"Rotate with motion",
                            @"Gap popover toggle: align rotation to the "
                            @"position-curve tangent during this gap.")
        tooltip:nil
        binding:^BOOL {
          KKInterval *live = read();
          return [live userBoolForKey:@"rotateWithMotion" default:NO];
        }
        disabledBinding:^BOOL {
          // Rotate-with-motion only needs the position to MOVE - the lean is
          // driven by acceleration, so a modulated gap's wobble drives it just
          // as well as a path tangent. Disable only when the gap is genuinely
          // static:
          // - Hold-modulation gaps wobble only if they actually have
          // modulation;
          //   a plain static hold does not move, so disable that.
          // - Transition gaps move unless they holdsFlat (Basic per-property
          //   phase-off) with no modulation to wobble them.
          KKInterval *live = read();
          BOOL hasModulation = (live.modulation != KKIntervalModulationNone);
          if (phase == KKGapPopoverPhaseHoldModulation)
            return !hasModulation;
          return live.holdsFlat && !hasModulation;
        }
        onToggle:^(BOOL isOn) {
          mutate(^(KKInterval *iv) {
            [iv setUserBool:isOn forKey:@"rotateWithMotion"];
          });
        }];
    return @[ row ];
  };

  self.inspectorView = view;
  if (!self.playheadPoller) {
    self.playheadPoller =
        [[KKPlayheadPoller alloc] initWithAPIManager:self.apiManager
                                        actionTarget:self
                                         renderCache:self.renderCache];
  }
  [self.playheadPoller setInspectorView:view];
  // The render tick may have already established timing before the
  // inspector view existed (poller was nil then, so ensureRunning was a
  // no-op nil-send). Kick it now so the scrubber appears without needing
  // the user to scrub.
  if (self.renderCache.effectDurSec > 0.0)
    [self.playheadPoller ensureRunning];
  return view;
}

- (NSArray<KKHelpSection *> *)helpSections {
  KKHelpSection *magicMove = [KKHelpSection
      sectionWithTitle:@"Magic Move"
             tipMarkup:@[
               (@"<accent>Position</accent>, <accent>Scale</accent>, and "
                @"<accent>Rotation</accent> all animate from the clip's "
                @"natural state to the values set here - drive each one on "
                @"canvas via the <symbol arcade.stick.console.fill /> "
                @"on-screen control."),
               (@"<accent>Opacity</accent> animates the same way, from a "
                @"slider in the inspector."),
               (@"<accent>Anchor Point</accent> sets the pivot rotations "
                @"and scale swing around."),
               (@"Toggle <accent>Rotate with Motion</accent> in the gap "
                @"popover to align the clip's heading with its motion path."),
               (@"When the Position lane has multiple keyposes a bezier "
                @"<accent>path</accent> draws between them on canvas - "
                @"reshape it by dragging anchors or their handles."),
               (@"Stacking with <accent>Crop</accent> or similar spatial "
                @"effects? Place them <accent>below</accent> Magic Move in "
                @"the inspector so they apply to the clip first, then move "
                @"with it - otherwise they anchor to the canvas and clip "
                @"around the moved content."),
             ]
             shortcuts:@[
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + drag"
                               descMarkup:@"Constrain motion to X or Y axis"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌃</kbd> + drag"
                                           descMarkup:@"Disable snapping"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>⌥</kbd>"
                               descMarkup:@"Reveal X and Y rotation rings"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>Shift</kbd> + scale"
                               descMarkup:@"Lock scale to X or Y axis"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"Double-click scale ring"
                                           descMarkup:@"Reset to 1:1"],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"Double-click path anchor"
                               descMarkup:@"Toggle between smooth and corner"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + click "
                                                      @"path anchor"
                                           descMarkup:@"Delete the anchor"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + click "
                                                      @"path curve"
                                           descMarkup:@"Insert a new anchor "
                                                      @"at the nearest spot"],
               [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌥</kbd> + drag "
                                                      @"handle"
                                           descMarkup:@"Break handle "
                                                      @"symmetry (move "
                                                      @"independently)"],
             ]];
  magicMove.icon =
      [NSImage imageWithSystemSymbolName:@"circle.dotted.and.circle"
                accessibilityDescription:nil];
  return @[ magicMove ];
}

@end
