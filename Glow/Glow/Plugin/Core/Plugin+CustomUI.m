/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "GlowInspectorView.h"
#import "Plugin_Private.h"
#import <KeyframelessKit/KKPlugin+InspectorCallbacks.h>
#import <KeyframelessKit/KKTimingStage.h>

@implementation GlowPlugin (CustomUI)

- (BOOL)usesMotionBlur {
  return YES;
}

+ (NSArray<KKLane *> *)availableLanes {
  // M1: a single 2-component aspect-linked Radius lane [X, Y] in canonical
  // pixels, modelled on MagicMove's Scale lane. Later milestones add the
  // remaining lanes (Intensity, Falloff, Noise, Position, Color, ...).
  KKLane *radius = [KKLane laneWithLabel:@"Radius"];
  radius.valueType = KKLaneValueTypeFloat;
  radius.componentMin = @[ @0.0, @0.0 ];
  radius.componentMax = @[ @500.0, @500.0 ];
  // "px" here is a purely cosmetic suffix: radius is stored AND rendered as
  // absolute canonical pixels (the shader's blur sigma). We deliberately do
  // NOT set componentsScaleWithMedia, so the field shows the literal value
  // (e.g. "100 px") with no media transform - unlike Crop/Position which are
  // normalised 0..1 and opt into the pixel display scaling.
  radius.componentUnits = @[ @"px", @"px" ];
  radius.componentLabels = @[ @"X", @"Y" ];
  radius.aspectLinkable = YES;
  radius.aspectLinked = YES;
  [radius
      insertKeypose:[KKKeyPose
                        keyposeAtTime:0.0
                               values:@[ @(kGlowM1Radius), @(kGlowM1Radius) ]]];
  return @[ radius ];
}

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kParamInspectorUI) {
    id<FxCustomParameterActionAPI_v4> actionAPI = [self.apiManager
        apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
    [actionAPI startAction:self];
    id<FxParameterRetrievalAPI_v6> getAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];

    KKInspectorPersistedState *st =
        [self kkReadInspectorPersistedStateWithGetAPI:getAPI
                                       uiStateParamID:kParamUIState];
    BOOL loopEnabled = st.loopEnabled;
    NSInteger activeTab = st.activeTab;
    BOOL motionBlurEnabled = st.motionBlurEnabled;
    double motionBlurShutterAngle = st.motionBlurShutterAngle;
    NSInteger motionBlurSamples = st.motionBlurSamples;
    NSInteger motionBlurMode = st.motionBlurMode;
    KKTimeline *timeline = [self timelineStampedWithClipDuration:st.timeline];

    // Frame + clip duration for the keypose-snap epsilon and the basic-view
    // scrubber clamp. FxTimingAPI resolves inside this action scope; we also
    // push them into the view right after construction to avoid the
    // render-push race documented in Rounded.
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
    }

    // Per-instance state: mint the UUID inside the action scope where the
    // setting API resolves.
    KKInstanceStateEnsureForAPI(self.apiManager);

    [actionAPI endAction:self];

    NSArray<KKLane *> *available = [GlowPlugin availableLanes];
    GlowInspectorView *view =
        [[GlowInspectorView alloc] initWithAPIManager:self.apiManager
                                          loopEnabled:loopEnabled
                                            activeTab:activeTab
                                       availableLanes:available
                                             timeline:timeline];
    if (seedClipDurSec > 0)
      [view setClipDurationSeconds:seedClipDurSec];
    if (seedFrameDurSec > 0)
      [view setFrameDurationSeconds:seedFrameDurSec];
    [view setMotionBlurEnabled:motionBlurEnabled];
    [view setMotionBlurShutterAngle:motionBlurShutterAngle
                            samples:motionBlurSamples];
    [view setMotionBlurMode:(KKMotionBlurMode)motionBlurMode];

    [self kkWireStandardInspectorCallbacksForView:view
                                   uiStateParamID:kParamUIState
                               renderNudgeParamID:kParamRenderNudge
                                    dragUndoLabel:@"Adjust Radius"
                               detachedWindowSize:CGSizeMake(720.0, 460.0)];

    self.inspectorView = view;
    if (!self.playheadPoller) {
      self.playheadPoller =
          [[KKPlayheadPoller alloc] initWithAPIManager:self.apiManager
                                          actionTarget:self
                                           renderCache:self.renderCache];
    }
    [self.playheadPoller setInspectorView:view];
    if (self.renderCache.effectDurSec > 0.0)
      [self.playheadPoller ensureRunning];
    return view;
  }
  typedef NSView *(*ViewIMP)(id, SEL, UInt32);
  ViewIMP imp = (ViewIMP)[KKPlugin instanceMethodForSelector:_cmd];
  return imp(self, _cmd, parameterID);
}

@end
