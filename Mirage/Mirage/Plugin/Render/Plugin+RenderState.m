/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "Constants.h"
#import "MirageAudioPool.h" // MirageFillAudioPool (the Sonar spectrogram)
#import "MirageDirectives.h"
#import "MirageInspectorView.h"
#import "MirageLocalized.h"
#import "MirageRack.h"
#import "MirageStateBlob.h"
#import "MirageSurfaceResponse.h" // MirageSurfacePreviewOwnedKeys
#import "Plugin+Render_Internal.h"
#import <KeyframelessKit/KKLog.h>

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
    if ([lane.key isEqualToString:label]) {
      return KKLinkResolvedLaneValue(lane, frac, timelineSec, durSec);
    }
  }
  return nil;
}

// Whether rack entry `entryID` is switched on at this fraction. The lane is new
// with the rack, so an entry that has never had one written renders - a rack
// that has never been touched behaves exactly like the single template it grew
// out of.
static BOOL MirageEntryEnabledAtFraction(KKTimeline *timeline,
                                         NSString *entryID, double frac,
                                         double timelineSec, double durSec) {
  NSArray<NSNumber *> *v = MirageLaneValuesAtFraction(
      timeline, MirageRackEnabledLaneKey(entryID), frac, timelineSec, durSec);
  return v.count ? v[0].doubleValue > 0.5 : MirageRackEntryEnabledDefault;
}

// Build the full plugin state from the timeline at one clip fraction. Pure (no
// timing/cache work) so a caller can refresh the render cache once and evaluate
// many sub-frame fractions cheaply (motion blur samples). Lane linking is
// handled inside MirageLaneValuesAtFraction via the kit resolver, keyed on the
// absolute `timelineSec`.
//
// `entryID` scopes the DIRECTIVE half of the evaluation to one rack entry: its
// own code lane, its own uniform lanes, its own `#slots` registries. The shared
// built-ins (Speed / Seed / Grain / Grain Size / Transition Mode) stay
// instance-wide bare keys - they drive the common uniform block, which the
// whole chain shares. For the sentinel every one of those keys is bare anyway
// (MirageRackLaneKey passes it through), so this evaluates a pre-rack project
// exactly as it did before the rack existed.
static void MirageEvalStateAtFrac(KKTimeline *timeline, double frac,
                                  double durSec, double timelineSec,
                                  NSString *entryID,
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
  // No lane = the shader never opted into `// #grain`, so no grain at all.
  common.grain = grainV.count ? grainV[0].floatValue / 100.0f : 0.0f;
  common.grainSize =
      grainSizeV.count ? grainSizeV[0].floatValue : KK_CORE_GRAINSIZE_DEFAULT;
  outState->common = common;
  NSArray<NSNumber *> *transitionModeV = MirageLaneValuesAtFraction(
      timeline, @"Transition Mode", frac, timelineSec, durSec);
  outState->transitionMode =
      transitionModeV.count
          ? (int)MAX(0, MIN(2, lround(transitionModeV[0].doubleValue)))
          : 0;

  // A shader's `// #color` properties -> the colour pool (the transpiled
  // block's std140 tail). Values come from the per-property lanes (fallback:
  // directive default count + the default palette). The directives are parsed
  // from the "Mirage" code lane.
  // Source for the directive pool. MUST match the blob codec's Image section
  // (MirageStateBlobEncode, which
  // supplies the Image the pool binds against): a MISSING "Mirage" lane falls
  // back to the baked default so the pool's directive uniforms (uCenter/uScale/
  // …) are still filled; a present-but-empty lane is passthrough (no
  // directives). Without the fallback, a timeline that drops the code lane
  // (e.g. a guide seed) transpiles the default shader but binds a ZERO pool -
  // every directive reads 0, flattening the preview.
  //
  // The seed is the SENTINEL's alone, matching the codec: a later rack entry
  // only exists because its registry entry was persisted, so a missing code
  // lane there means no shader, not an unwritten one.
  KKLane *shaderLane =
      MirageRackCodeLaneForEntry(timeline, entryID, kMirageCodeLaneLabel);
  BOOL sentinel = [entryID isEqualToString:kMirageRackSentinelEntryID];
  NSString *shaderSrc =
      shaderLane.codeString.length
          ? shaderLane.codeString
          : ((!shaderLane && sentinel) ? MirageCustomDefaultShaderSource()
                                       : nil);
  // The controls the Color panel owns read their DECLARED DEFAULT here and
  // nothing else, whatever the timeline happens to contain.
  //
  // Not merely tidy - it is what keeps a project made before these became
  // session state from being stuck. Such a project may still carry a
  // `uShowSelection` lane sitting at true, and the catalog no longer builds a
  // template for it, so `hidesLanesWithoutTemplate` drops the ROW while the
  // lane stays in the blob. Without this the render would keep reading that
  // true and Final Cut would show a grey matte with no control anywhere to turn
  // it off. Returning nothing falls through to the prop's own default in
  // MirageScalarPoolValue, which is the off the author declared.
  NSSet<NSString *> *panelOwned = MirageSurfacePreviewOwnedKeys(shaderSrc);
  NSArray<NSNumber *> * (^values)(NSString *) =
      ^NSArray<NSNumber *> *(NSString *label) {
    if (label.length && [panelOwned containsObject:label])
      return @[];
    // The model asks by BARE label - what the directive declared - and this is
    // where that becomes the entry's real lane key. The panel-owned test above
    // stays on the bare label: it is a question about the source, not about
    // which entry is running it.
    return MirageLaneValuesAtFraction(
        timeline, MirageRackLaneKey(entryID, label), frac, timelineSec, durSec);
  };
  // A `// #slots` group's instances, in the order the registry (not the lane
  // list) puts them: that order IS which array element each instance packs
  // into. Scoped to the entry, so two entries running the same template keep
  // separate instance registries.
  NSArray<NSString *> * (^slotInstances)(NSString *) =
      ^NSArray<NSString *> *(NSString *groupName) {
    return KKTimelineSlotInstanceIDs(
        timeline, MirageRackScopedSlotGroupName(entryID, groupName));
  };
  MirageShaderModel *model = [MirageShaderModel modelForSource:shaderSrc];
  int poolN = [model fillColorPool:outState->colorPool
                    valuesForLabel:values
                     slotInstances:slotInstances];
  poolN = [model fillScalarPool:outState->colorPool
                 valuesForLabel:values
                  slotInstances:slotInstances];
  // `// #audio` props: sampled from the bound Sonar spectrogram at the TIMELINE
  // time, not the clip fraction - the grid is keyed by timeline seconds. That
  // is NOT the render time: `timelineSec` comes from
  // `timelineTime:fromInputTime:`, because an FxPlug render time in FCP is the
  // input's native media clock.
  poolN = MirageFillAudioPool(model, outState->colorPool, timelineSec, values);
  // `// #gradient` ramps last, so the three pools above keep their offsets.
  poolN = [model fillGradientPool:outState->colorPool valuesForLabel:values];
  // The injected `#slots` counts sit after everything else, so they close the
  // pool and their fill returns what gets bound.
  poolN = [model fillSlotCountPool:outState->colorPool
                     slotInstances:slotInstances];
  outState->colorPoolCount = poolN;
}

@implementation MiragePlugin (RenderState)

// The timeline the params currently hold, or nil when nothing is persisted yet.
//
// Both halves are expensive at rack scale and BOTH are per render tick: the
// read crosses XPC carrying the whole persisted blob (which a chain multiplies
// by its entry count, code sections and all), and the decode rebuilds every
// lane and keypose object in it. One tick used to do this three times over -
// here, again for the manifest's display name, and again to encode the state
// blob. It is done ONCE now and handed on (`_tickTimeline` /
// `_tickTimelineJSON`, valid only within the -pluginState: callback that filled
// them).
- (KKTimeline *)_timelineFromParams:(id<FxParameterRetrievalAPI_v6>)paramAPI {
  NSString *json = KKReadCustomParamString(paramAPI, kKKParamTimelineData);
  KKTimeline *timeline = json.length ? [KKTimeline timelineFromJSON:json] : nil;
  self.tickTimelineJSON = json;
  self.tickTimeline = timeline;
  return timeline;
}

// The timeline this tick already read, decoding only if nothing has.
- (KKTimeline *)_tickTimelineFromParams:
    (id<FxParameterRetrievalAPI_v6>)paramAPI {
  KKTimeline *cached = self.tickTimeline;
  return cached ?: [self _timelineFromParams:paramAPI];
}

// The fallback name for a rack entry that has never been named - the same
// string, key for key, that the strip's boxes fall back to, so the picker and
// the strip call an unnamed entry the same thing.
static NSString *MirageRackFallbackEntryName(void) {
  return RLoc(@"Shader", @"Generic GLSL code lane display name (the code "
                         @"editor's caption).");
}

// Link-source opt-in (see KKPlugin -writeLinkManifest): the EFFECTIVE directive
// lane set for the current shader, so a fresh clip advertises its full param
// set (constants) before it's ever edited - NOT the persisted timeline (empty
// on a fresh instance).
//
// EVERY rack entry, not just the first: a chain's later entries are as
// referenceable as its head, and their lane keys are already globally unique
// (`~Rack#<id>.<key>`), so the published curves and the stored `${uuid.key}`
// tokens need nothing new. Only the DISPLAY side needs help - two entries
// running the same template both call a control "Amount" - so a racked clip
// qualifies each param with its entry's deduped name ("Grade 2: Amount"). An
// unracked clip is left exactly as it was, down to the label, so no existing
// project's picker rows move.
- (NSArray<KKLane *> *)linkableLanesForManifest {
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!getAPI)
    return nil;
  // The tick's own read when a render is what asked - see -_timelineFromParams:
  // on why re-reading this per tick is not free.
  NSString *json = self.tickTimelineJSON
                       ?: KKReadCustomParamString(getAPI, kKKParamTimelineData);
  // Memo: the manifest is rebuilt on EVERY render tick, and a rack multiplies
  // the directive parse behind `availableLanesForShaderSource:` by its entry
  // count. The lane set is a pure function of the persisted blob and this
  // instance's audio bindings, so it is rebuilt when one of those moves rather
  // than once a frame.
  NSString *signature = [NSString
      stringWithFormat:@"%@|%@", json ?: @"", self.audioTickets.description];
  if (self.linkManifestLanesCache &&
      [signature isEqualToString:self.linkManifestLanesSignature]) {
    return self.linkManifestLanesCache;
  }

  KKTimeline *timeline =
      (json == self.tickTimelineJSON && self.tickTimeline)
          ? self.tickTimeline
          : (json.length ? [KKTimeline timelineFromJSON:json] : nil);
  // Overlay the user's REAL keyposes / expression onto each template lane so
  // the auto-published curves (KKPlugin -writeLinkManifest) carry the values
  // the render actually uses, not just defaults - while keeping each
  // template's label/metadata (the template's display name is canonical) so
  // the manifest's friendly param names survive. Unedited params keep the
  // template default; edited ones (constant or animated) get their real curve.
  NSMutableDictionary<NSString *, KKLane *> *persisted =
      [NSMutableDictionary dictionaryWithCapacity:timeline.lanes.count];
  for (KKLane *l in timeline.lanes)
    if (l.key)
      persisted[l.key] = l;

  // ONE build for the WHOLE chain: the rack-aware lane set already walks every
  // entry and hands back the union, each entry's keys scoped to it. Asking it
  // once per entry returned that same union N times over, so the manifest
  // carried N duplicates of every lane and attributed the FIRST copy of ALL of
  // them to the FIRST entry ("Dynamic Grid: Scanlines" for a lane belonging to
  // CRT), while the duplicates collided on display name and got respelled by
  // their raw key (KKLinkKeySpelledParamNames) - which is how `~Rack#<id>.
  // Enabled` reached the picker.
  //
  // Attribution comes off the lane itself: the same build stamps `layerLabel`
  // with the entry's deduped display name, so the qualified label can never
  // disagree with what the strip and the inspector call that entry. It is nil
  // for an unracked project, which is exactly the case whose rows must not
  // move.
  NSArray<KKLane *> *templates =
      [MiragePlugin availableLanesForShaderSource:nil
                                     audioTickets:self.audioTickets
                                         timeline:timeline];
  NSMutableArray<KKLane *> *merged =
      [NSMutableArray arrayWithCapacity:templates.count];
  for (KKLane *t in templates) {
    KKLane *m = [t copy];
    KKLane *p = persisted[t.key];
    if (p.keyposes.count) {
      m.keyposes = p.keyposes;
      m.linkExpression = p.linkExpression;
    }
    if (m.layerLabel.length)
      m.label =
          [NSString stringWithFormat:@"%@: %@", m.layerLabel, m.label ?: @""];
    [merged addObject:m];
  }
  self.linkManifestLanesSignature = signature;
  self.linkManifestLanesCache = merged;
  return merged;
}

- (NSString *)linkManifestEffectName {
  // The bus's scoping key, NOT a label: +reconcileEffectName: uses it to find
  // this plugin's orphaned manifests, so it stays constant per plugin even
  // though the display name below varies per instance.
  return @"Mirage";
}

- (NSString *)linkManifestDisplayName {
  // What another clip's reference picker shows. A project with six Mirage
  // clips otherwise lists six identical "Mirage @ <tc>" rows, distinguishable
  // only by timecode, so name each by the shader it's running - and a RACKED
  // clip by its whole chain, in the order the strip draws it ("Grade > Bloom >
  // Grade 2"), since the one shader it is "running" is all of them.
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  if (!getAPI)
    return [self linkManifestEffectName];
  // The tick's own copy when a render is what asked (the overwhelmingly common
  // caller): naming the chain is not worth a second cross-process read of the
  // whole blob and a second full decode of it.
  KKTimeline *timeline = [self _tickTimelineFromParams:getAPI];
  NSArray<NSString *> *entryIDs = MirageRackEntryIDs(timeline);
  if (entryIDs.count > 1)
    return [MirageRackDisplayNames(timeline, entryIDs, kMirageCodeLaneLabel,
                                   MirageRackFallbackEntryName())
        componentsJoinedByString:@" > "];
  for (KKLane *l in timeline.lanes)
    if ([l.key isEqualToString:kMirageCodeLaneLabel] && l.codeSaveName.length)
      return l.codeSaveName;
  return [self linkManifestEffectName];
}

// Whether this tick has to advertise the clip on the link bus at all.
//
// -writeLinkManifest is not a cheap call to make once a frame. Before it
// serializes anything it derives the chain's display name, and then takes three
// FxTimingAPI round trips plus a documentID resolve - every one of them a
// synchronous re-entry into Final Cut, from the render thread, while Final Cut
// is busy playing back. Then it serializes EVERY referenceable lane of EVERY
// entry to compare against what it last wrote, and a rack multiplies that lane
// count by its entry count. Measured on a four-entry chain, all of that came to
// 40-150 ms per tick at 14-24 ticks a second: the render thread spent most of
// playback re-advertising a clip that had not changed - which also starved the
// inspector's mini viewer, since its frames come from this same render.
//
// What the manifest says is a pure function of the persisted timeline and this
// instance's audio bindings - the same fingerprint the lane memo already keys
// on, and one this tick has in hand without another read. So an unchanged tick
// publishes nothing at all.
//
// Still refreshed every kMirageLinkRepublishSeconds: an idle clip's manifest
// file has to keep its mtime recent or KKLinkBus's orphan sweep collects it
// (it prunes anything not touched within its window). The interval matches the
// bus's own touch interval, so the GC behaviour is exactly what it was - this
// only stops the 20-odd redundant publishes in between.
static const double kMirageLinkRepublishSeconds = 10.0;

- (BOOL)_shouldPublishLinkManifestForJSON:(NSString *)timelineJSON {
  NSString *signature =
      [NSString stringWithFormat:@"%@|%@", timelineJSON ?: @"",
                                 self.audioTickets.description];
  double now = CACurrentMediaTime();
  BOOL changed = ![signature isEqualToString:self.linkPublishSignature];
  BOOL stale = self.linkPublishTime <= 0.0 ||
               (now - self.linkPublishTime) > kMirageLinkRepublishSeconds;
  if (!changed && !stale)
    return NO;
  self.linkPublishSignature = signature;
  self.linkPublishTime = now;
  return YES;
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
  return [self buildStates:outStates
                   atTimes:times
                     count:count
               rackEntries:NULL
                     error:error];
}

- (BOOL)buildStates:(MiragePluginState *)outStates
            atTimes:(const CMTime *)times
              count:(NSInteger)count
        rackEntries:(NSArray<MirageStateBlobEntry *> **)outRackEntries
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
  NSString *timelineJSON = self.tickTimelineJSON;

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
  if (hasTiming && [self _shouldPublishLinkManifestForJSON:timelineJSON])
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
                                       nudgeParamID:kKKParamRenderNudgeString];
    KKLinkWatcher *watcher = self.linkWatcher;
    dispatch_async(dispatch_get_main_queue(), ^{
      [watcher setSourceNames:linkSources]; // empty stops it
    });
  }

  // Cache refreshed once above; evaluate each requested (sub-frame) time. The
  // per-time work (frac + lane eval + type builders) lives in
  // MirageEvalStateAtFrac. The fraction and timeline second of each sample are
  // kept, because a rack evaluates every entry at those same instants.
  double *fracs = malloc(sizeof(double) * (size_t)MAX(count, (NSInteger)1));
  double *tlSecs = malloc(sizeof(double) * (size_t)MAX(count, (NSInteger)1));
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
    fracs[i] = frac;
    tlSecs[i] = CMTimeGetSeconds(tlTime);
    MirageEvalStateAtFrac(timeline, frac, durSec, tlSecs[i],
                          kMirageRackSentinelEntryID, &outStates[i]);
  }

  // SHADER RACK: every entry, at the same instants. Asked for only when the
  // caller wants it AND the timeline actually holds a chain - a project with
  // the implicit single entry never allocates any of this, and the states
  // above are the whole answer.
  if (outRackEntries) {
    NSArray<NSString *> *entryIDs = MirageRackEntryIDs(timeline);
    *outRackEntries = nil;
    if (entryIDs.count > 1) {
      NSMutableArray<MirageStateBlobEntry *> *rack =
          [NSMutableArray arrayWithCapacity:entryIDs.count];
      for (NSString *entryID in entryIDs) {
        NSMutableData *states =
            [NSMutableData dataWithLength:sizeof(MiragePluginState) *
                                          (NSUInteger)MAX(count, (NSInteger)1)];
        NSMutableData *enabled =
            [NSMutableData dataWithLength:(NSUInteger)MAX(count, (NSInteger)1)];
        MiragePluginState *s = (MiragePluginState *)states.mutableBytes;
        uint8_t *en = (uint8_t *)enabled.mutableBytes;
        for (NSInteger i = 0; i < count; i++) {
          MirageEvalStateAtFrac(timeline, fracs[i], durSec, tlSecs[i], entryID,
                                &s[i]);
          en[i] = MirageEntryEnabledAtFraction(timeline, entryID, fracs[i],
                                               tlSecs[i], durSec)
                      ? 1
                      : 0;
        }
        MirageStateBlobEntry *e = [MirageStateBlobEntry new];
        e.entryID = entryID;
        e.states = states;
        e.enabled = enabled;
        [rack addObject:e];
      }
      *outRackEntries = rack;
    }
  }
  free(fracs);
  free(tlSecs);
  return YES;
}

- (BOOL)pluginState:(NSData **)pluginState
             atTime:(CMTime)renderTime
            quality:(FxQuality)qualityLevel
              error:(NSError **)error {
  // Motion blur (Accurate / sample-accumulate): a generator owns every pixel,
  // so instead of requesting extra source frames we re-render the shader at N
  // sub-frame times across the shutter and average them (KKMotionBlur).
  // Sample 0 is the render time; MirageStateBlobEncode owns the byte layout.
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
  NSArray<MirageStateBlobEntry *> *rackEntries = nil;
  BOOL ok = [self buildStates:states
                      atTimes:ct
                        count:n
                  rackEntries:&rackEntries
                        error:error];
  free(ct);
  if (!ok) {
    free(states);
    self.tickTimelineJSON = nil;
    self.tickTimeline = nil;
    return NO;
  }

  // Technique is forced to Accurate for the WHEN-gating it derives (Always -
  // blur every animated frame), which is what both engines want here: a
  // procedural shader owns every pixel and its own animation clock, so there is
  // no "value changing" signal to gate on.
  if (mbState.enabled)
    mbState.technique = KKMotionBlurTechniqueAccurate;

  // -buildStates: above already read and decoded this on this tick.
  KKTimeline *timeline = [self _tickTimelineFromParams:paramAPI];
  // A chain writes the rack layout; anything else writes the pre-rack one. Both
  // ends of that choice live in MirageStateBlob - the encoder emits the legacy
  // bytes for a lone sentinel entry anyway, so this only decides which call to
  // make, not which layout comes out.
  NSData *data =
      rackEntries.count > 1
          ? MirageStateBlobEncodeRack(&mbState, rackEntries, timeline)
          : MirageStateBlobEncode(&mbState, states, n, timeline);
  free(states);

  *pluginState = data;
  // The tick's read is only good for the tick: dropped here so anything asking
  // OUTSIDE a render callback (the add-to-document manifest write, an AI
  // author) reads the params for itself rather than inheriting a stale answer.
  self.tickTimelineJSON = nil;
  self.tickTimeline = nil;
  return (*pluginState != nil);
}

@end

#pragma clang diagnostic pop
