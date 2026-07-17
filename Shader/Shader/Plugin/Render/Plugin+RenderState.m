/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "Plugin+Render_Internal.h"
#import "ShaderAudioPool.h" // ShaderFillAudioPool (the Sonar spectrogram)
#import "ShaderDirectives.h"
#import "ShaderInspectorView.h"
#import "ShaderStateBlob.h"

#import <KeyframelessKit/KKMotionBlur.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

// The interpolated component values of the lane named `label` at clip fraction
// `frac`, or nil if there's no such lane.
static NSArray<NSNumber *> *
ShaderLaneValuesAtFraction(KKTimeline *timeline, NSString *label, double frac) {
  for (KKLane *lane in timeline.lanes) {
    if ([lane.label isEqualToString:label])
      return KKTimelineLaneValueAtVisualFractionSmoothed(lane, frac);
  }
  return nil;
}

// Build the full plugin state from the timeline at one clip fraction. Pure (no
// timing/cache work) so a caller can refresh the render cache once and evaluate
// many sub-frame fractions cheaply (motion blur samples).
static void ShaderEvalStateAtFrac(KKTimeline *timeline, double frac,
                                  double durSec, double timelineSec,
                                  ShaderPluginState *outState) {
  memset(outState, 0, sizeof(*outState));

  NSArray<NSNumber *> *speedV =
      ShaderLaneValuesAtFraction(timeline, @"Speed", frac);
  float speed =
      speedV.count ? speedV[0].floatValue : KK_SHADER_GRAD_DEFAULT_SPEED;
  NSArray<NSNumber *> *seedV =
      ShaderLaneValuesAtFraction(timeline, @"Seed", frac);
  float seed = seedV.count ? seedV[0].floatValue : KK_SHADER_GRAD_DEFAULT_SEED;
  float timeSec = (float)(frac * durSec);

  NSArray<NSNumber *> *grainV =
      ShaderLaneValuesAtFraction(timeline, @"Grain", frac);
  NSArray<NSNumber *> *grainSizeV =
      ShaderLaneValuesAtFraction(timeline, @"Grain Size", frac);
  // Only the shared params survive (Speed / Seed / Grain / Grain Size + time).
  // The user shader source drives everything else and rides in the blob tail.
  ShaderCommonUniforms common = ShaderCommonDefault();
  common.speed = speed;
  common.seed = seed;
  common.time = timeSec;
  common.progress = (float)frac;
  common.grain =
      grainV.count ? grainV[0].floatValue / 100.0f : KK_CORE_GRAIN_DEFAULT;
  common.grainSize =
      grainSizeV.count ? grainSizeV[0].floatValue : KK_CORE_GRAINSIZE_DEFAULT;
  outState->common = common;

  // A shader's `// #color` properties -> the colour pool (the transpiled
  // block's std140 tail). Values come from the per-property lanes (fallback:
  // directive default count + the default palette). The directives are parsed
  // from the "Shader" code lane.
  NSString *shaderSrc = nil;
  for (KKLane *l in timeline.lanes)
    if ([l.label isEqualToString:@"Shader"] && l.codeString.length) {
      shaderSrc = l.codeString;
      break;
    }
  NSArray<NSNumber *> * (^values)(NSString *) =
      ^NSArray<NSNumber *> *(NSString *label) {
    return ShaderLaneValuesAtFraction(timeline, label, frac);
  };
  int poolN = ShaderFillColorPool(shaderSrc, outState->colorPool, values);
  poolN = ShaderFillScalarPool(shaderSrc, outState->colorPool, poolN, values);
  // `// #audio` props: sampled from the bound Sonar spectrogram at the TIMELINE
  // time, not the clip fraction - the grid is keyed by timeline seconds. That
  // is NOT the render time: `timelineSec` comes from
  // `timelineTime:fromInputTime:`, because an FxPlug render time in FCP is the
  // input's native media clock.
  poolN = ShaderFillAudioPool(shaderSrc, outState->colorPool, poolN,
                              timelineSec, values);
  outState->colorPoolCount = poolN;
}

@implementation ShaderPlugin (RenderState)

// The timeline the params currently hold, or nil when nothing is persisted yet.
- (KKTimeline *)_timelineFromParams:(id<FxParameterRetrievalAPI_v6>)paramAPI {
  NSString *json = KKReadCustomParamString(paramAPI, kKKParamTimelineData);
  return json.length ? [KKTimeline timelineFromJSON:json] : nil;
}

// Tell the inspector where this clip sits in PROJECT time, so its mini-viewer
// can sample `// #audio` at the playhead instead of previewing silence. The
// render tick is the only place the clip's position surfaces; the value is a
// view's, so it lands on main.
- (void)_publishClipTimelineStart:(id<FxTimingAPI_v4>)timingAPI {
  ShaderInspectorView *iv = (ShaderInspectorView *)self.inspectorView;
  if (!iv)
    return;
  // Converted, not raw: effectStartSec is native-media time in FCP.
  CMTime effStartTL = kCMTimeZero;
  [timingAPI timelineTime:&effStartTL
            fromInputTime:CMTimeMakeWithSeconds(self.renderCache.effectStartSec,
                                                600)];
  double projectStart = CMTimeGetSeconds(effStartTL);
  dispatch_async(dispatch_get_main_queue(), ^{
    iv.clipTimelineStartSec = projectStart;
  });
}

- (BOOL)buildStates:(ShaderPluginState *)outStates
            atTimes:(const CMTime *)times
              count:(NSInteger)count
              error:(NSError **)error {
  id<FxParameterRetrievalAPI_v6> paramGetAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (paramGetAPI == nil) {
    if (error != NULL) {
      *error =
          [NSError errorWithDomain:FxPlugErrorDomain
                              code:kFxError_ThirdPartyDeveloperStart + 20
                          userInfo:@{
                            NSLocalizedDescriptionKey :
                                @"Unable to retrieve FxParameterRetrievalAPI_v6"
                          }];
    }
    return NO;
  }
  KKTimeline *timeline = [self _timelineFromParams:paramGetAPI];

  // Cache the loop toggle (lives in the UI-state blob) so the main-queue
  // playhead poll can decide whether to wrap at the clip end.
  NSString *uiJSON = KKReadCustomParamString(paramGetAPI, kParamUIState);
  if (uiJSON.length) {
    NSDictionary *ui = [NSJSONSerialization
        JSONObjectWithData:[uiJSON dataUsingEncoding:NSUTF8StringEncoding]
                   options:0
                     error:nil];
    KKRenderCacheApplyUIState(self.renderCache, ui);
  }

  BOOL hasTiming = KKRefreshRenderCache(
      self.apiManager, (KKTimelineInspectorView *)self.inspectorView,
      self.renderCache);
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  [self bakeMaintainTimingForCache:self.renderCache
                   timelineParamID:kKKParamTimelineData
                    uiStateParamID:kParamUIState];
  double durSec = self.renderCache.effectDurSec;
  if (hasTiming)
    [self _publishClipTimelineStart:timingAPI];
  // Live scrubber: render ticks stop ~1s before the clip end (FCP pre-render
  // buffer - renderTime leads currentTime). Arm the self-terminating poll so it
  // follows currentTime through the tail.
  if (hasTiming) {
    KKPlayheadPoller *poller = self.playheadPoller;
    dispatch_async(dispatch_get_main_queue(), ^{
      [poller ensureRunning];
    });
  }

  // Cache refreshed once above; evaluate each requested (sub-frame) time. The
  // per-time work (frac + lane eval + type builders) lives in
  // ShaderEvalStateAtFrac.
  for (NSInteger i = 0; i < count; i++) {
    double frac = (hasTiming && durSec > 0.0)
                      ? MAX(0.0, MIN(1.0, (CMTimeGetSeconds(times[i]) -
                                           self.renderCache.effectStartSec) /
                                              durSec))
                      : 0.0;
    frac = KKMaintainTimingRemappedFraction(frac, self.renderCache);
    // TIMELINE time, which is NOT the render time. In FCP a render time is
    // relative to the object's native media start (Apple's docs are explicit:
    // "in Final Cut Pro this is the time the effect starts relative to the
    // input object's native start time"), so a clip 6s into a project
    // reports 63.9 if that's where it sits in its source.
    // `timelineTime:fromInputTime:` is the only thing that converts it - and it
    // returns the project's real timecode too (7206.083 for 6.05s into a
    // project starting at 02:00:00:00), which is exactly how Sonar keys the
    // spectrogram.
    CMTime tlTime = kCMTimeZero;
    [timingAPI timelineTime:&tlTime fromInputTime:times[i]];
    ShaderEvalStateAtFrac(timeline, frac, durSec, CMTimeGetSeconds(tlTime),
                          &outStates[i]);
  }
  return YES;
}

- (BOOL)pluginState:(NSData **)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error {
  // Motion blur (Accurate / sample-accumulate): a generator owns every pixel,
  // so instead of requesting extra source frames we re-render the shader at N
  // sub-frame times across the shutter and average them (KKMotionBlur). Layout:
  // [KKMotionBlurState][state@sample0 == renderTime][state@sample1]... Render
  // reads sample `sampleIndex` at sizeof(mbState) +
  // i*sizeof(ShaderPluginState).
  id<FxParameterRetrievalAPI_v6> paramAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  NSString *mbJSON = KKReadCustomParamString(paramAPI, kKKParamMotionBlurData);
  KKMotionBlurState mbState = [KKMotionBlur snapshotStateFromJSON:mbJSON
                                                        timingAPI:timingAPI
                                                           atTime:renderTime];

  NSArray<NSValue *> *times =
      mbState.enabled
          ? [KKMotionBlur sampleTimesForState:mbState renderTime:renderTime]
          : @[ [NSValue valueWithBytes:&renderTime objCType:@encode(CMTime)] ];
  NSInteger n = (NSInteger)times.count;
  if (n < 1)
    n = 1;

  CMTime *ct = malloc(sizeof(CMTime) * (size_t)n);
  for (NSInteger i = 0; i < n; i++)
    [times[i] getValue:&ct[i]];
  ShaderPluginState *states = malloc(sizeof(ShaderPluginState) * (size_t)n);
  BOOL ok = [self buildStates:states atTimes:ct count:n error:error];
  free(ct);
  if (!ok) {
    free(states);
    return NO;
  }

  // The Custom (GLSL) path is the only render path now: it owns its own
  // animation (the shader's own time via Speed) and its source rides in the
  // blob tail, so it never uses the sample-accumulate motion-blur path.
  mbState.enabled = NO;

  NSMutableData *data = [NSMutableData
      dataWithCapacity:sizeof(mbState) + sizeof(ShaderPluginState)];
  [data appendBytes:&mbState length:sizeof(mbState)];
  [data appendBytes:&states[0] length:sizeof(ShaderPluginState)];
  free(states);

  // Append the user shader source after the single state sample. MB is forced
  // off above, so the layout is a fixed [mbState][state][sections...] and
  // render reads the tail from a known offset.
  ShaderAppendCodeSections(data, [self _timelineFromParams:paramAPI]);

  *pluginState = data;
  return (*pluginState != nil);
}

@end

#pragma clang diagnostic pop
