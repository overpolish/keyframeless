/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import "RoundedInspectorView+Guides.h"
#import "RoundedInspectorView.h"
#import "RoundedLocalized.h"
#import "RoundedOSCRadiusMath.h"
#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKDataBlob.h>
#import <KeyframelessKit/KKHelpSection.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKTimingCompat.h>
#import <KeyframelessKit/KKTimingStage.h>
@import KeyframelessAI;

/// Plain-text coordinate-space description used by the AI agent's value
/// resolution pass. Kept tight on purpose: this is the only context the
/// values-pass LLM call sees, alongside the user's prompt. No timing words,
/// no in/out, no Basic/Advanced - just lanes and their numeric ranges.
static NSString *_RoundedAILaneSchemaText(void) {
  NSMutableString *s = [NSMutableString string];
  [s appendString:@"Lane labels and coordinate spaces:\n\n"];

  [s appendString:
          @"- \"Radius\": one numeric component.\n"
          @"    Range 0..100 (percentage of the clip's shorter edge).\n"
          @"    Default value: 20. 0 = square corners, 100 = fully rounded.\n"
          @"\n"
          @"- \"Crop\": four numeric components [width, height, x_offset, "
          @"y_offset].\n"
          @"    width, height: fractions of the clip image, range 0..1. "
          @"1.0 = full size, 0.5 = half size.\n"
          @"    x_offset, y_offset: center offsets in normalised SCREEN "
          @"space (Y-down image convention), range -0.5..+0.5.\n"
          @"    Axis convention (standard image / screen space):\n"
          @"      +x = RIGHT, -x = LEFT.\n"
          @"      +y = DOWN, -y = UP. (Yes, Y increases downward, like "
          @"every image / canvas / pixel API.)\n"
          @"    Default value: [1, 1, 0, 0] (full image, no crop).\n"
          @"\n"
          @"    Worked examples (verify the y_offset sign before using):\n"
          @"      full image:              [1.0, 1.0,  0.0,   0.0]\n"
          @"      top-left quadrant:       [0.5, 0.5, -0.25, -0.25]\n"
          @"      top-right quadrant:      [0.5, 0.5, +0.25, -0.25]\n"
          @"      bottom-left quadrant:    [0.5, 0.5, -0.25, +0.25]\n"
          @"      bottom-right quadrant:   [0.5, 0.5, +0.25, +0.25]\n"
          @"      top half:                [1.0, 0.5,  0.0,  -0.25]\n"
          @"      bottom half:             [1.0, 0.5,  0.0,  +0.25]\n"
          @"      left half:               [0.5, 1.0, -0.25,  0.0]\n"
          @"      right half:              [0.5, 1.0, +0.25,  0.0]\n"
          @"      centered square:         [0.5, 0.5,  0.0,   0.0]\n"];
  return s;
}

/// Returns a JSON timeline string for the current effect: the saved one, or
/// a fresh template built from the plugin's availableLanes when nothing is
/// saved. The LLM always needs to see real lane labels so it can target them.
static NSString *
_RoundedAICurrentTimelineJSON(id<FxParameterRetrievalAPI_v6> getAPI) {
  NSString *saved = KKReadCustomParamString(getAPI, kKKParamTimelineData);
  if (saved.length && [saved containsString:@"\"label\""])
    return saved;
  KKTimeline *fresh = [KKTimeline timeline];
  fresh.lanes = [RoundedPlugin availableLanes];
  NSString *json = [KKTimeline jsonFromTimeline:fresh];
  return json ?: @"{\"lanes\":[]}";
}

/// For any new hold interval (endpoints_linked:true) that has no modulation,
/// scan the old lane's intervals for any hold interval with modulation whose
/// time range overlaps the new interval's time range, and copy its modulation
/// fields onto the new one. The LLM is told to preserve modulation across
/// unchanged regions but routinely forgets; this is the deterministic
/// backstop.
static NSArray *_RoundedAIPreserveModulation(NSArray *newKps, NSArray *oldKps) {
  if (![newKps isKindOfClass:[NSArray class]] || newKps.count < 2)
    return newKps;
  if (![oldKps isKindOfClass:[NSArray class]] || oldKps.count < 2)
    return newKps;

  NSMutableArray *out = [NSMutableArray arrayWithCapacity:newKps.count];
  for (NSUInteger i = 0; i < newKps.count; i++) {
    id raw = newKps[i];
    if (![raw isKindOfClass:[NSDictionary class]]) {
      [out addObject:raw];
      continue;
    }
    NSMutableDictionary *kp = [raw mutableCopy];
    NSDictionary *outgoing = kp[@"outgoing"];
    if (![outgoing isKindOfClass:[NSDictionary class]] ||
        i + 1 >= newKps.count) {
      [out addObject:kp];
      continue;
    }
    BOOL linked = [outgoing[@"endpoints_linked"] boolValue];
    NSInteger newMod = [outgoing[@"modulation"] integerValue];
    if (!linked || newMod != 0) {
      [out addObject:kp];
      continue;
    }
    // This is a hold with no modulation. Look for a matching old hold
    // interval whose time range overlaps AND whose value matches this
    // keypose's value (so we only preserve modulation on "the same hold
    // resegmented", not on a new differently-valued hold the user just
    // introduced inside the old region).
    double newStart = [kp[@"time"] doubleValue];
    double newEnd = [((NSDictionary *)newKps[i + 1])[@"time"] doubleValue];
    NSArray *newVals = kp[@"values"];
    for (NSUInteger j = 0; j + 1 < oldKps.count; j++) {
      NSDictionary *oldKp = oldKps[j];
      if (![oldKp isKindOfClass:[NSDictionary class]])
        continue;
      NSDictionary *oldOut = oldKp[@"outgoing"];
      if (![oldOut isKindOfClass:[NSDictionary class]])
        continue;
      BOOL oldLinked = [oldOut[@"endpoints_linked"] boolValue];
      NSInteger oldMod = [oldOut[@"modulation"] integerValue];
      if (!oldLinked || oldMod == 0)
        continue;
      double oldStart = [oldKp[@"time"] doubleValue];
      double oldEnd = [((NSDictionary *)oldKps[j + 1])[@"time"] doubleValue];
      // Time overlap AND matching held value. The value check is what
      // separates "outer wiggle-hold resegmented around a new bump" from
      // "a new quiet middle hold sitting inside the old wiggle region".
      BOOL overlaps = (newStart < oldEnd) && (newEnd > oldStart);
      if (!overlaps)
        continue;
      NSArray *oldVals = oldKp[@"values"];
      if (![newVals isKindOfClass:[NSArray class]] ||
          ![oldVals isKindOfClass:[NSArray class]] ||
          newVals.count != oldVals.count)
        continue;
      BOOL sameValues = YES;
      for (NSUInteger k = 0; k < newVals.count; k++) {
        if (fabs([newVals[k] doubleValue] - [oldVals[k] doubleValue]) > 1e-6) {
          sameValues = NO;
          break;
        }
      }
      if (!sameValues)
        continue;
      NSMutableDictionary *mergedOut = [outgoing mutableCopy];
      mergedOut[@"modulation"] = @(oldMod);
      if (oldOut[@"modulation_intensity"])
        mergedOut[@"modulation_intensity"] = oldOut[@"modulation_intensity"];
      if (oldOut[@"modulation_frequency"])
        mergedOut[@"modulation_frequency"] = oldOut[@"modulation_frequency"];
      if (oldOut[@"modulation_seed"])
        mergedOut[@"modulation_seed"] = oldOut[@"modulation_seed"];
      if (oldOut[@"modulation_linked"] != nil)
        mergedOut[@"modulation_linked"] = oldOut[@"modulation_linked"];
      kp[@"outgoing"] = mergedOut;
      break;
    }
    [out addObject:kp];
  }
  return out;
}

/// Merge the AI agent's compiled mutation JSON of shape
/// `{"operations":[{"lane":"<label>","keyposes":[...]}]}` into the current
/// full timeline JSON. The merge preserves each lane's stable fields
/// (id, value_type, component_min/max/units) and only replaces keyposes.
/// Lanes not mentioned in operations are left untouched. Unknown lane
/// labels are dropped silently.
static NSString *_RoundedAIMergedTimelineJSON(NSString *currentTimelineJSON,
                                              NSString *mutationJSON) {
  NSData *curD = [currentTimelineJSON dataUsingEncoding:NSUTF8StringEncoding];
  NSError *err = nil;
  NSMutableDictionary *current =
      [NSJSONSerialization JSONObjectWithData:curD
                                      options:NSJSONReadingMutableContainers
                                        error:&err];
  if (![current isKindOfClass:[NSMutableDictionary class]])
    return nil;
  NSData *mutD = [mutationJSON dataUsingEncoding:NSUTF8StringEncoding];
  NSDictionary *mut = [NSJSONSerialization JSONObjectWithData:mutD
                                                      options:0
                                                        error:&err];
  if (![mut isKindOfClass:[NSDictionary class]])
    return nil;
  NSArray *ops = mut[@"operations"];
  NSMutableArray *curLanes = current[@"lanes"];
  if (![ops isKindOfClass:[NSArray class]] ||
      ![curLanes isKindOfClass:[NSMutableArray class]])
    return nil;

  NSMutableDictionary *byLabel = [NSMutableDictionary dictionary];
  for (NSUInteger i = 0; i < curLanes.count; i++) {
    NSDictionary *L = curLanes[i];
    if (![L isKindOfClass:[NSDictionary class]])
      continue;
    NSString *label = L[@"label"];
    if ([label isKindOfClass:[NSString class]])
      byLabel[label] = @(i);
  }

  for (id op in ops) {
    if (![op isKindOfClass:[NSDictionary class]])
      continue;
    NSString *label = op[@"lane"];
    if (![label isKindOfClass:[NSString class]])
      continue;
    NSNumber *idxN = byLabel[label];
    if (!idxN) {
      KKLogWarn(@"AI tried to write unknown lane label: %@", label);
      continue;
    }
    NSMutableDictionary *target =
        [curLanes[idxN.unsignedIntegerValue] mutableCopy];
    if (op[@"keyposes"]) {
      // Crop schema exposed to the LLM as screen-space (Y-down). The data
      // model is also Y-down empirically (manually editing y=+0.5 in the
      // inspector moves the crop center DOWN), regardless of what comments
      // elsewhere claim. So LLM output flows straight through.
      NSArray *newKps = op[@"keyposes"];
      NSArray *oldKps = curLanes[idxN.unsignedIntegerValue][@"keyposes"];
      target[@"keyposes"] = _RoundedAIPreserveModulation(newKps, oldKps);
    }
    if (op[@"hold_shape"])
      target[@"hold_shape"] = op[@"hold_shape"];
    target[@"enabled"] = @YES;
    curLanes[idxN.unsignedIntegerValue] = target;
  }

  current[@"lanes"] = curLanes;
  NSData *outD = [NSJSONSerialization dataWithJSONObject:current
                                                 options:0
                                                   error:&err];
  return [[NSString alloc] initWithData:outD encoding:NSUTF8StringEncoding];
}

@implementation RoundedPlugin (CustomUI)

- (BOOL)usesMotionBlur {
  return YES;
}

+ (NSArray<KKLane *> *)availableLanes {
  KKLane *radius = [KKLane laneWithLabel:@"Radius"];
  radius.valueType = KKLaneValueTypeFloat;
  radius.componentMin = @[ @0.0 ];
  radius.componentMax = @[ @100.0 ];
  radius.componentUnits = @[ @"%" ];
  // Template default == the product default constant (seeded when the
  // property has no lane yet; keeps the constants editor in sync with the
  // render fallback).
  [radius insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:@[ @20.0 ]]];

  KKLane *crop = [KKLane laneWithLabel:@"Crop"];
  crop.valueType = KKLaneValueTypeCrop;
  crop.componentMin = @[ @0.0, @0.0, @-0.5, @-0.5 ];
  crop.componentMax = @[ @1.0, @1.0, @0.5, @0.5 ];
  crop.componentUnits = @[ @"px", @"px", @"px", @"px" ];
  [crop insertKeypose:[KKKeyPose keyposeAtTime:0.0
                                        values:@[ @1.0, @1.0, @0.0, @0.0 ]]];

  return @[ radius, crop ];
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
    // Migration: legacy onionSkinEnabled BOOL → new renderMode enum
    // (0=Off, 1=Filmstrip, 2=Onion). Old true maps to Filmstrip.
    KKMiniCanvasRenderMode renderMode = KKMiniCanvasRenderModeOff;
    if (uiState[@"renderMode"]) {
      renderMode =
          (KKMiniCanvasRenderMode)[uiState[@"renderMode"] integerValue];
    } else if ([uiState[@"onionSkinEnabled"] boolValue]) {
      renderMode = KKMiniCanvasRenderModeFilmstrip;
    }

    NSString *mbJson = KKReadCustomParamString(getAPI, kKKParamMotionBlurData);
    NSDictionary *mbState =
        (mbJson.length ? [NSJSONSerialization
                             JSONObjectWithData:
                                 [mbJson dataUsingEncoding:NSUTF8StringEncoding]
                                        options:0
                                          error:nil]
                       : nil)
            ?: @{};
    BOOL motionBlurEnabled = [mbState[@"enabled"] boolValue];
    double motionBlurShutterAngle = mbState[@"shutterAngle"]
                                        ? [mbState[@"shutterAngle"] doubleValue]
                                        : 180.0;
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

    // Cold-boot seed for the OSC. Without this, the first drawOSC tick after
    // FCP relaunch sees an empty snapshot → falls through to "no lane =
    // constant", radius reads default 20, crop reads [1,1,0,0] → handle is
    // visible at the canvas TR regardless of saved state. parameterChanged
    // eventually catches up, but only after a redraw nudge.
    RoundedSetTimelineSnapshot(timeline);

    // Frame + clip duration for the keypose-snap epsilon AND the basic-view
    // scrubber clamp. FxTimingAPI resolves inside this action scope. We
    // also push these into the view itself right after construction (below)
    // because the Plugin+Render push is gated on lastPushedClipDuration and
    // can race with view creation: if the first render fires before the
    // inspector view exists, the push targets a nil weak ref and the basic
    // view never learns the frame duration for the lifetime of this session.
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
        RoundedSetFrameDurationSeconds(seedFrameDurSec);
    }

    [actionAPI endAction:self];

    NSArray<KKLane *> *available = [RoundedPlugin availableLanes];
    RoundedInspectorView *view =
        [[RoundedInspectorView alloc] initWithAPIManager:self.apiManager
                                             loopEnabled:loopEnabled
                                               activeTab:activeTab
                                          availableLanes:available
                                                timeline:timeline];
    // Seed the basic-view scrubber clamp immediately. Plugin+Render's
    // dispatch_async push runs once on first render - if it raced ahead
    // and weakSelf.inspectorView was still nil, the basic view would
    // never see the frame duration. Pushing here too is idempotent.
    if (seedClipDurSec > 0)
      [view setClipDurationSeconds:seedClipDurSec];
    if (seedFrameDurSec > 0)
      [view setFrameDurationSeconds:seedFrameDurSec];
    [view setMotionBlurEnabled:motionBlurEnabled];
    [view setMotionBlurShutterAngle:motionBlurShutterAngle
                            samples:motionBlurSamples];
    [view setMotionBlurMode:(KKMotionBlurMode)motionBlurMode];
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
      id<FxParameterSettingAPI_v5> setAPI = [strong.apiManager
          apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
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
    [view setRenderMode:renderMode];
    view.onRenderModeChanged = ^(KKMiniCanvasRenderMode mode) {
      __strong typeof(weak) strong = weak;
      if (!strong)
        return;
      [strong patchUIStateKey:@"renderMode"
                        value:@((NSInteger)mode)
                      paramID:kParamUIState];
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

    // Coalesce a continuous mini-canvas handle drag into one undo entry: the
    // per-tick onTimelineMutated writes nest inside this outer group.
    // FxUndoAPI resolves to nil outside an action scope, so the begin/end
    // of the coalescing group must run inside one (the per-tick mutate
    // writes then land in the still-open host undo group).
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
          KKBeginUndoGroup(strong.apiManager, @"Adjust Radius");
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

    // Boundary popover just opened and wrote its request file. FCP only
    // re-runs -scheduleInputs: on a render, and it serves a cached frame
    // for a static playhead (no scheduleInputs at all). Writing a fresh
    // random value to a hidden scratch param makes FCP treat it as a real
    // parameter change → it re-renders the current frame → scheduleInputs
    // runs and picks up the request file. Random (not incremented) so it
    // never collides with a previously cached value after undo/redo.
    view.onBoundaryPreviewNeedsRender = ^{
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
      NSString *nonce = [[NSUUID UUID] UUIDString];
      KKWriteCustomParamString(setAPI, nonce, kParamRenderNudge);
      [act endAction:strong];
    };

    // Scrub: drag the Basic playhead → move the host playhead. FxTimingAPI
    // resolves inside this action scope (it's nil in the render tick).
    // movePlayheadToTime: is timeline-time in FCP, effect-time in Motion.
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

    // Spacebar in the inspector → play/pause (FCP eats it otherwise).
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

    view.effectHeaderRectProvider = ^NSRect {
      __strong typeof(weak) strong = weak;
      return strong ? [strong effectHeaderScreenRect] : NSZeroRect;
    };

    view.onToggleDetached = ^{
      __strong typeof(weak) strong = weak;
      if (!strong)
        return;
      RoundedInspectorView *insp = strong.inspectorView;
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

    self.inspectorView = view;
    if (!self.playheadPoller) {
      self.playheadPoller =
          [[KKPlayheadPoller alloc] initWithAPIManager:self.apiManager
                                          actionTarget:self
                                           renderCache:self.renderCache];
    }
    [self.playheadPoller setInspectorView:view];
    return view;
  }
  typedef NSView *(*ViewIMP)(id, SEL, UInt32);
  ViewIMP imp = (ViewIMP)[KKPlugin instanceMethodForSelector:_cmd];
  return imp(self, _cmd, parameterID);
}

- (NSArray<KKHelpGuide *> *)helpGuides {
  __weak typeof(self) weak = self;
  __block __weak KKHelpGuide *weakIntro = nil;
  KKHelpGuide *intro = [KKHelpGuide
      guideWithTitle:RLoc(@"Introduction",
                          @"Help guide title: re-run the basics walkthrough.")
            subtitle:RLoc(@"Walk through the basics again",
                          @"Help guide subtitle: Introduction.")
             onStart:^{
               __strong typeof(weak) strong = weak;
               strong.inspectorView.onGuideCompleted = ^{
                 [weakIntro markCompleted];
               };
               [strong.inspectorView restartIntroGuide];
             }];
  weakIntro = intro;
  // Gate every guide on Rounded being the selected effect - consistent
  // expectation across all guides (the per-guide reasons differ in detail
  // but the user-facing requirement is the same). The section-level warning
  // pulls the first non-empty disabledSubtitle, so set it on intro too.
  intro.enabledProvider = ^BOOL {
    return RoundedHasCanvasReference();
  };
  intro.disabledSubtitle =
      RLoc(@"Guides are disabled. Please select a Rounded clip to enable them, "
           @"if already selected move your mouse over the viewer.",
           @"Intro guide disabled subtitle (no Rounded clip selected).");

  __block __weak KKHelpGuide *weakOSC = nil;
  KKHelpGuide *osc = [KKHelpGuide
      guideWithTitle:RLoc(@"OSC Basics",
                          @"Help guide title: on-screen control basics.")
            subtitle:RLoc(@"Learn how the on-screen control works",
                          @"Help guide subtitle: OSC Basics.")
             onStart:^{
               __strong typeof(weak) strong = weak;
               // This guide teaches the drag - require actually
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
      RLoc(@"Guides are disabled - select a Rounded clip to enable them",
           @"Help guide disabled subtitle (no Rounded clip selected).");
  // OSC guide has a zoom-to-fit + settle warm-up; spin the play button until
  // the overlay is actually on screen.
  osc.activeProvider = ^BOOL {
    __strong typeof(weak) strong = weak;
    return strong.inspectorView.oscGuideActive;
  };

  __block __weak KKHelpGuide *weakFull = nil;
  KKHelpGuide *full = [KKHelpGuide
      guideWithTitle:RLoc(
                         @"Full Walkthrough",
                         @"Help guide title: full inspector + OSC walkthrough.")
            subtitle:RLoc(@"Inspector and on-screen control, end to end",
                          @"Help guide subtitle: Full Walkthrough.")
             onStart:^{
               __strong typeof(weak) strong = weak;
               // Ends on the OSC drag - enforce landing on the
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
      RLoc(@"Guides are disabled - select a Rounded clip to enable them",
           @"Help guide disabled subtitle (no Rounded clip selected).");

  __block __weak KKHelpGuide *weakConstants = nil;
  KKHelpGuide *constants = [KKHelpGuide
      guideWithTitle:RLoc(@"Constants",
                          @"Help guide title: editing non-animating values.")
            subtitle:RLoc(@"Edit non-animating values in the mini-canvas",
                          @"Help guide subtitle: Constants.")
             onStart:^{
               __strong typeof(weak) strong = weak;
               strong.inspectorView.onGuideCompleted = ^{
                 [weakConstants markCompleted];
               };
               [strong.inspectorView restartConstantsGuide];
             }];
  weakConstants = constants;
  // Needs the live mini-canvas preview (radius handle + zoom/pan), so it
  // requires a Rounded clip just like the OSC guide.
  constants.enabledProvider = ^BOOL {
    return RoundedHasCanvasReference();
  };
  constants.disabledSubtitle =
      RLoc(@"Guides are disabled - select a Rounded clip to enable them",
           @"Help guide disabled subtitle (no Rounded clip selected).");

  __block __weak KKHelpGuide *weakBasicTiming = nil;
  KKHelpGuide *basicTiming = [KKHelpGuide
      guideWithTitle:RLoc(@"Timing Basics",
                          @"Help guide title: basic timing walkthrough.")
            subtitle:RLoc(@"Add animatable properties and turn on a transition",
                          @"Help guide subtitle: Timing Basics.")
             onStart:^{
               __strong typeof(weak) strong = weak;
               strong.inspectorView.onGuideCompleted = ^{
                 [weakBasicTiming markCompleted];
               };
               [strong.inspectorView restartBasicTimingGuide];
             }];
  weakBasicTiming = basicTiming;
  // The final step's cutout unions the play button with the FCP viewer
  // rect, which only resolves once the OSC bridge has a draw tick. Same
  // canvas-reference gate as the OSC + constants guides.
  basicTiming.enabledProvider = ^BOOL {
    return RoundedHasCanvasReference();
  };
  basicTiming.disabledSubtitle =
      RLoc(@"Guides are disabled - select a Rounded clip to enable them",
           @"Help guide disabled subtitle (no Rounded clip selected).");

  __block __weak KKHelpGuide *weakAdvancedTiming = nil;
  KKHelpGuide *advancedTiming = [KKHelpGuide
      guideWithTitle:RLoc(@"Advanced Timing",
                          @"Help guide title: advanced timing walkthrough.")
            subtitle:
                RLoc(
                    @"Add keyposes anywhere and shape transitions per property",
                    @"Help guide subtitle: Advanced Timing.")
             onStart:^{
               __strong typeof(weak) strong = weak;
               strong.inspectorView.onGuideCompleted = ^{
                 [weakAdvancedTiming markCompleted];
               };
               [strong.inspectorView restartAdvancedTimingGuide];
             }];
  weakAdvancedTiming = advancedTiming;
  advancedTiming.enabledProvider = ^BOOL {
    return RoundedHasCanvasReference();
  };
  advancedTiming.disabledSubtitle =
      RLoc(@"Guides are disabled - select a Rounded clip to enable them",
           @"Help guide disabled subtitle (no Rounded clip selected).");

  return @[ intro, osc, full, constants, basicTiming, advancedTiming ];
}

- (NSNotificationName)helpGuideRefreshNotificationName {
  return kRoundedOSCPositionNotification;
}

- (nullable NSView *)aiAccessoryView {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    [KKAIKnowledge registerSharedTimelineDocs];
    [KKAIKnowledge
        registerBundleDocsWithName:@"Rounded"
                            bundle:[NSBundle
                                       bundleForClass:[RoundedPlugin class]]
                      subdirectory:@"AIKnowledge"];
  });

  NSString *productContext = RLoc(
      @"Rounded, a Final Cut Pro plugin that rounds corners, crops with a box, "
      @"and animates with the shared Keyframeless timeline system (Basic and "
      @"Advanced timing, easing, motion blur). Always refer to yourself as "
      @"Rounded. Detailed feature information is in the reference docs below.",
      @"AI assistant product context for Rounded plugin.");

  NSArray<NSArray<NSString *> *> *examples = @[
    @[
      RLoc(@"Animate radius 0→100% with bounce",
           @"AI example chip: animate radius with bounce."),
      RLoc(@"Animate the radius from 0% to 100% over 1 second with bounce.",
           @"AI example value: animate radius with bounce.")
    ],
    @[
      RLoc(@"Crop to top right", @"AI example chip: crop to top right."),
      RLoc(@"Crop to the top right quadrant.",
           @"AI example value: crop to top right.")
    ],
    @[
      RLoc(@"Reveal then hide", @"AI example chip: in/out crop animation."),
      RLoc(@"Animate the crop in from the top right and back out at the "
           @"end, while the radius rounds over the whole clip.",
           @"AI example value: in/out crop animation.")
    ],
    @[
      RLoc(@"What's Basic vs Advanced?",
           @"AI example chip: Basic vs Advanced timing question."),
      RLoc(@"What's the difference between Basic and Advanced timing?",
           @"AI example value: Basic vs Advanced timing question.")
    ],
  ];

  NSString *placeholder = RLoc(@"Ask a question or describe an animation…",
                               @"AI prompt field placeholder for Rounded.");

  __weak typeof(self) weakSelf = self;
  return [KKAIBannerHost
      makePluginButtonWithProductContext:productContext
                            examplePairs:examples
                             placeholder:placeholder
                                   onRun:^(NSString *prompt) {
                                     __strong typeof(weakSelf) strong =
                                         weakSelf;
                                     if (!strong)
                                       return;
                                     [strong _runAIPrompt:prompt
                                           productContext:productContext];
                                   }];
}

- (void)_runAIPrompt:(NSString *)prompt
      productContext:(NSString *)productContext {
  [KKAIDraft setRouting:YES];
  [KKAIDraft setError:nil];

  // Read current timeline + clip duration inside an action scope.
  id<FxCustomParameterActionAPI_v4> readAct =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!readAct) {
    [KKAIDraft setRouting:NO];
    [KKAIDraft setError:@"Couldn't open the FCP action scope."];
    return;
  }
  [readAct startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  NSString *currentJSON = _RoundedAICurrentTimelineJSON(getAPI);
  NSString *uiJson = KKReadCustomParamString(getAPI, kParamUIState);
  NSDictionary *uiState =
      (uiJson.length
           ? [NSJSONSerialization
                 JSONObjectWithData:[uiJson
                                        dataUsingEncoding:NSUTF8StringEncoding]
                            options:0
                              error:nil]
           : nil)
          ?: @{};
  NSInteger activeTab = [uiState[@"activeTab"] integerValue];
  NSString *currentMode = (activeTab == 1) ? @"Advanced" : @"Basic";
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  CMTime clipDur = kCMTimeZero;
  if (timingAPI)
    [timingAPI durationTimeForEffect:&clipDur];
  double clipDurSec = CMTimeGetSeconds(clipDur);
  if (clipDurSec <= 0 || isnan(clipDurSec))
    clipDurSec = 5.0;
  [readAct endAction:self];

  NSString *schema = _RoundedAILaneSchemaText();

  __weak typeof(self) weakSelf = self;
  [KKAIPluginAgent
             runWithPrompt:prompt
            productContext:productContext
            laneSchemaText:schema
       currentTimelineJSON:currentJSON
       clipDurationSeconds:clipDurSec
      currentInspectorMode:currentMode
                completion:^(KKAIPluginResult *result, NSError *err) {
                  dispatch_async(dispatch_get_main_queue(), ^{
                    __strong typeof(weakSelf) strong = weakSelf;
                    if (!strong)
                      return;
                    [KKAIDraft setRouting:NO];
                    if (err) {
                      KKLogError(@"AI[err] %@", err.localizedDescription);
                      [KKAIDraft setError:err.localizedDescription];
                      return;
                    }
                    if (!result) {
                      KKLogError(@"AI[err] empty result");
                      [KKAIDraft setError:@"Empty AI response."];
                      return;
                    }
                    if (result.kind == KKAIPluginResultKindAnswer) {
                      [KKAIDraft setAnswer:result.answer];
                      return;
                    }
                    NSString *merged = _RoundedAIMergedTimelineJSON(
                        currentJSON, result.mutationJSON);
                    if (!merged) {
                      KKLogError(@"AI[err] merge returned nil");
                      [KKAIDraft
                          setError:
                              @"AI returned an invalid timeline mutation."];
                      return;
                    }
                    id<FxCustomParameterActionAPI_v4> writeAct =
                        [strong.apiManager
                            apiForProtocol:@protocol(
                                               FxCustomParameterActionAPI_v4)];
                    if (!writeAct) {
                      [KKAIDraft
                          setError:@"Couldn't open the FCP action scope to "
                                   @"apply the mutation."];
                      return;
                    }
                    [writeAct startAction:strong];
                    id<FxParameterSettingAPI_v5> setAPI = [strong.apiManager
                        apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
                    KKWriteCustomParamString(setAPI, merged,
                                             kKKParamTimelineData);

                    // If the new timeline isn't representable in Basic, force
                    // the inspector to Advanced so the user sees the actual
                    // structure. Keeping the activeTab on Basic when the data
                    // is Advanced-only shows the compatibility banner instead
                    // of the new animation.
                    KKTimeline *resultTimeline =
                        [KKTimeline timelineFromJSON:merged];
                    if (resultTimeline &&
                        !KKTimelineIsBasicCompatible(resultTimeline)) {
                      [strong patchUIStateKey:@"activeTab"
                                        value:@(1)
                                      paramID:kParamUIState];
                    }
                    [writeAct endAction:strong];
                    [KKAIDraft setAnswer:nil];
                    [KKAIDraft clearPrompt];
                  });
                }];
}

- (NSArray<KKHelpSection *> *)helpSections {
  KKHelpSection *rounded = [KKHelpSection
      sectionWithTitle:RLoc(@"Rounded",
                            @"Help section title (the plugin name).")
             tipMarkup:@[
               RLoc(@"Round the corners of any clip with an animatable "
                    @"<accent>Radius</accent>.",
                    @"Help tip: what the Radius property does."),
               RLoc(@"<accent>Box</accent> crops and positions the clip - "
                    @"animate it to reveal or hide content over time.",
                    @"Help tip: what the Box/Crop property does."),
             ]
             shortcuts:nil];
  rounded.icon = [NSImage imageWithSystemSymbolName:@"square.dotted"
                           accessibilityDescription:nil];
  return @[ rounded ];
}

@end
