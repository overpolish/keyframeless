/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "MirageAudioPool.h" // MirageFillAudioPool (the Sonar spectrogram)
#import "MirageDirectives.h"
#import "MirageInspectorView.h"
#import "MirageStateBlob.h"
#import "Plugin+Render_Internal.h"

#import <KeyframelessKit/KKLinkBus.h>
#import <KeyframelessKit/KKMotionBlur.h>

#pragma clang diagnostic push
#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

// The resolved component values of the lane named `label` at clip fraction
// `frac`, or nil if there's no such lane. Routes through the kit's
// KKLinkResolvedLaneValue so an expression-driven lane reads its computed value
// (evaluated at the absolute `timelineSec`), and a plain lane evaluates exactly
// as before. This is the ONE place Mirage plugs its lane evaluation into the
// shared link engine.
static NSArray<NSNumber *> *
MirageLaneValuesAtFraction(KKTimeline *timeline, NSString *label, double frac,
                           double timelineSec, double durSec) {
  for (KKLane *lane in timeline.lanes) {
    if ([lane.label isEqualToString:label])
      return KKLinkResolvedLaneValue(lane, frac, timelineSec, durSec);
  }
  return nil;
}

// Build the full plugin state from the timeline at one clip fraction. Pure (no
// timing/cache work) so a caller can refresh the render cache once and evaluate
// many sub-frame fractions cheaply (motion blur samples). Lane linking is
// handled inside MirageLaneValuesAtFraction via the kit resolver, keyed on the
// absolute `timelineSec`.
static void MirageEvalStateAtFrac(KKTimeline *timeline, double frac,
                                  double durSec, double timelineSec,
                                  MiragePluginState *outState) {
  memset(outState, 0, sizeof(*outState));

  NSArray<NSNumber *> *speedV =
      MirageLaneValuesAtFraction(timeline, @"Speed", frac, timelineSec, durSec);
  float speed =
      speedV.count ? speedV[0].floatValue : KK_SHADER_GRAD_DEFAULT_SPEED;
  NSArray<NSNumber *> *seedV =
      MirageLaneValuesAtFraction(timeline, @"Seed", frac, timelineSec, durSec);
  float seed = seedV.count ? seedV[0].floatValue : KK_SHADER_GRAD_DEFAULT_SEED;
  float timeSec = (float)(frac * durSec);

  NSArray<NSNumber *> *grainV =
      MirageLaneValuesAtFraction(timeline, @"Grain", frac, timelineSec, durSec);
  NSArray<NSNumber *> *grainSizeV = MirageLaneValuesAtFraction(
      timeline, @"Grain Size", frac, timelineSec, durSec);
  // Only the shared params survive (Speed / Seed / Grain / Grain Size + time).
  // The user shader source drives everything else and rides in the blob tail.
  MirageCommonUniforms common = MirageCommonDefault();
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
  // from the "Mirage" code lane.
  // Source for the directive pool. MUST match MirageAppendCodeSections (which
  // supplies the Image the pool binds against): a MISSING "Mirage" lane falls
  // back to the baked default so the pool's directive uniforms (uCenter/uScale/
  // …) are still filled; a present-but-empty lane is passthrough (no
  // directives). Without the fallback, a timeline that drops the code lane
  // (e.g. a guide seed) transpiles the default shader but binds a ZERO pool -
  // every directive reads 0, flattening the preview.
  KKLane *shaderLane = nil;
  for (KKLane *l in timeline.lanes)
    if ([l.label isEqualToString:@"Mirage"]) {
      shaderLane = l;
      break;
    }
  NSString *shaderSrc =
      shaderLane.codeString.length
          ? shaderLane.codeString
          : (shaderLane ? nil : MirageCustomDefaultShaderSource());
  NSArray<NSNumber *> * (^values)(NSString *) =
      ^NSArray<NSNumber *> *(NSString *label) {
    return MirageLaneValuesAtFraction(timeline, label, frac, timelineSec,
                                      durSec);
  };
  int poolN = MirageFillColorPool(shaderSrc, outState->colorPool, values);
  poolN = MirageFillScalarPool(shaderSrc, outState->colorPool, poolN, values);
  // `// #audio` props: sampled from the bound Sonar spectrogram at the TIMELINE
  // time, not the clip fraction - the grid is keyed by timeline seconds. That
  // is NOT the render time: `timelineSec` comes from
  // `timelineTime:fromInputTime:`, because an FxPlug render time in FCP is the
  // input's native media clock.
  poolN = MirageFillAudioPool(shaderSrc, outState->colorPool, poolN,
                              timelineSec, values);
  outState->colorPoolCount = poolN;
}

@implementation MiragePlugin (RenderState)

// The timeline the params currently hold, or nil when nothing is persisted yet.
- (KKTimeline *)_timelineFromParams:(id<FxParameterRetrievalAPI_v6>)paramAPI {
  NSString *json = KKReadCustomParamString(paramAPI, kKKParamTimelineData);
  return json.length ? [KKTimeline timelineFromJSON:json] : nil;
}

// Link-source opt-in (see KKPlugin -writeLinkManifest): the EFFECTIVE directive
// lane set for the current shader, so a fresh clip advertises its full param
// set (constants) before it's ever edited - NOT the persisted timeline (empty
// on a fresh instance). Source = the "Mirage" code lane, or the baked default.
- (NSArray<KKLane *> *)linkableLanesForManifest {
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!getAPI)
    return nil;
  KKTimeline *timeline = [self _timelineFromParams:getAPI];
  NSString *shaderSrc = nil;
  for (KKLane *lane in timeline.lanes)
    if ([lane.label isEqualToString:@"Mirage"] && lane.codeString.length) {
      shaderSrc = lane.codeString;
      break;
    }
  if (shaderSrc.length == 0)
    shaderSrc = MirageCustomDefaultShaderSource();
  NSArray<KKLane *> *templates =
      [MiragePlugin availableLanesForShaderSource:shaderSrc];
  // Overlay the user's REAL keyposes / expression onto each template lane so
  // the auto-published curves (KKPlugin -writeLinkManifest) carry the values
  // the render actually uses, not just defaults - while keeping each template's
  // displayLabel/metadata (the persisted lane's display name isn't serialized)
  // so the manifest's friendly param names survive. Unedited params keep the
  // template default; edited ones (constant or animated) get their real curve.
  NSMutableDictionary<NSString *, KKLane *> *persisted =
      [NSMutableDictionary dictionaryWithCapacity:timeline.lanes.count];
  for (KKLane *l in timeline.lanes)
    if (l.label)
      persisted[l.label] = l;
  NSMutableArray<KKLane *> *merged =
      [NSMutableArray arrayWithCapacity:templates.count];
  for (KKLane *t in templates) {
    KKLane *p = persisted[t.label];
    if (p.keyposes.count) {
      KKLane *m = [t copy];
      m.keyposes = p.keyposes;
      m.linkExpression = p.linkExpression;
      [merged addObject:m];
    } else {
      [merged addObject:t];
    }
  }
  return merged;
}

- (NSString *)linkManifestEffectName {
  return @"Mirage";
}

// Tell the inspector where this clip sits in PROJECT time, so its mini-viewer
// can sample `// #audio` at the playhead instead of previewing silence. The
// render tick is the only place the clip's position surfaces; the value is a
// view's, so it lands on main.
- (void)_publishClipTimelineStart:(id<FxTimingAPI_v4>)timingAPI {
  MirageInspectorView *iv = (MirageInspectorView *)self.inspectorView;
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

- (BOOL)buildStates:(MiragePluginState *)outStates
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

  // Advertise this clip as a link SOURCE via the shared base hook (see
  // -linkableLanesForManifest below for Mirage's effective directive lane set).
  if (hasTiming)
    [self writeLinkManifest];

  // Subscriber side: watch the sources THIS clip's expressions reference so a
  // cross-clip source edit forces us to re-render (FCP renders clips
  // independently and won't refresh a subscriber otherwise). Created lazily -
  // only clips that actually reference something pay for a timer. The nudge
  // (debounced) writes the hidden render-nudge scratch param in an action
  // scope.
  NSSet<NSString *> *linkSources = KKLinkTimelineSourceNames(timeline);
  // Drop SAME-clip references (`${selfUUID.label}`). This clip republishes its
  // own lanes on every render (writeLinkManifest above), which bumps their
  // change stamp - so watching them would nudge-loop forever (render ->
  // republish -> stamp bump -> nudge -> render), firing continuous ungrouped
  // render-nudge writes even while idle. A same-clip source is already live in
  // this clip's own timeline and re-renders with it, so it needs no cross-clip
  // nudge. Only TRUE cross-clip sources (another effect's uuid) get watched.
  NSString *selfLinkUUID = KKInstanceUUIDForAPI(self.apiManager);
  if (selfLinkUUID.length && linkSources.count) {
    NSString *selfPrefix = [selfLinkUUID stringByAppendingString:@"."];
    NSMutableSet<NSString *> *crossClip = [NSMutableSet set];
    for (NSString *name in linkSources)
      if (![name hasPrefix:selfPrefix])
        [crossClip addObject:name];
    linkSources = crossClip;
  }
  if (linkSources.count > 0 || self.linkWatcher) {
    if (!self.linkWatcher)
      self.linkWatcher =
          [[KKLinkWatcher alloc] initWithAPIManager:self.apiManager
                                       actionTarget:self
                                       nudgeParamID:kParamRenderNudge];
    KKLinkWatcher *watcher = self.linkWatcher;
    dispatch_async(dispatch_get_main_queue(), ^{
      [watcher setSourceNames:linkSources]; // empty stops it
    });
  }

  // Cache refreshed once above; evaluate each requested (sub-frame) time. The
  // per-time work (frac + lane eval + type builders) lives in
  // MirageEvalStateAtFrac.
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
    MirageEvalStateAtFrac(timeline, frac, durSec, CMTimeGetSeconds(tlTime),
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
  // i*sizeof(MiragePluginState).
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
  MiragePluginState *states = malloc(sizeof(MiragePluginState) * (size_t)n);
  BOOL ok = [self buildStates:states atTimes:ct count:n error:error];
  free(ct);
  if (!ok) {
    free(states);
    return NO;
  }

  // A procedural shader owns every pixel and its own animation clock
  // (iTime/iProgress), so motion blur is pure sample-accumulate: re-render the
  // shader at N sub-frame times across the shutter and average (render loops
  // states[0..n-1] through KKMotionBlur). There is no velocity buffer to
  // reconstruct from, so the Fast technique can't apply here - force Accurate
  // (which also derives mode = Always, blurring every animated frame).
  if (mbState.enabled)
    mbState.technique = KKMotionBlurTechniqueAccurate;

  NSMutableData *data = [NSMutableData
      dataWithCapacity:sizeof(mbState) + (size_t)n * sizeof(MiragePluginState)];
  [data appendBytes:&mbState length:sizeof(mbState)];
  [data appendBytes:states length:(size_t)n * sizeof(MiragePluginState)];
  free(states);

  // The user shader source follows the N state samples: the layout is
  // [mbState][state@0]...[state@n-1][sections...] and render reads the tail
  // from sizeof(mbState) + n*sizeof(MiragePluginState).
  MirageAppendCodeSections(data, [self _timelineFromParams:paramAPI]);

  *pluginState = data;
  return (*pluginState != nil);
}

@end

#pragma clang diagnostic pop
