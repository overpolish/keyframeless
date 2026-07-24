/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageInspectorView.h"

#import "Constants.h"      // MirageCustomDefaultShaderSource
#import "Plugin_Private.h" // +availableLanesForShaderSource:
#import "MirageCategory.h"
#import "MirageDirectives.h" // #color / #float ... default parsing
#import "MirageInspectorView+Guides.h"
#import "MirageInspectorView_Private.h"
#import "MirageLocalCatalog.h"
#import "MirageLocalized.h"
#import "MirageMiniViewerRenderer.h"
#import "MirageThumbnailRenderer.h"
#import <KeyframelessKit/KKTimelineInspectorView+Guide.h>
#import <KeyframelessKit/KKTimingGuide.h>
@import KKCommunity;

static NSString *const kMirageIntroSeenKey = @"MirageIntroSeen";

// Default keypose values a directive lane seeds for `label`, given a shader
// `source` - the SAME seed the lane catalog uses (MirageMakeColorLane /
// MirageAppendScalarLanes): a colour honours `default="#hex"` else the built-in
// palette; a scalar honours its `default=`. Returns nil when `label` isn't a
// directive lane this source declares (a Core lane, or an untracked label) or
// when the lane's default isn't a single constant to compare (the #progress
// ramp) - callers leave those untouched.
static NSArray<NSNumber *> *
MirageDirectiveDefaultValuesForLabel(NSString *source, NSString *label) {
  if (!source.length || !label.length)
    return nil;

  // Scalars: identity is the uniform name.
  MirageShaderModel *model = [MirageShaderModel modelForSource:source];
  const MirageScalarProp *sp = model.scalarProps;
  for (int i = 0; i < model.scalarCount; i++) {
    if (![label isEqualToString:@(sp[i].name)])
      continue;
    if (sp[i].isProgress)
      return nil; // a ramp, not a constant - leave it alone
    if (sp[i].isPoint)
      return @[ @(sp[i].pdefx), @(sp[i].pdefy) ];
    if (sp[i].isMulti) {
      NSMutableArray<NSNumber *> *d = [NSMutableArray array];
      for (int k = 0; k < sp[i].fieldCount && k < 4; k++)
        [d addObject:@(sp[i].mdef[k])];
      return d;
    }
    return @[ @(sp[i].isChoice ? (double)sp[i].cdefault : sp[i].fdefault) ];
  }

  // Colours: single = uniform name; array = "<name> Count" + "<name> N". Match
  // the catalog seed (defColors else palette; a single colour uses the prop
  // index, a swatch its own index).
  const MirageColorProp *cp = model.colorProps;
  for (int i = 0; i < model.colorCount; i++) {
    NSString *name = @(cp[i].name);
    if (!cp[i].isArray) {
      if ([label isEqualToString:name]) {
        const float *d = cp[i].hasDefColors ? cp[i].defColors[0]
                                            : kMirageDefaultPalette[i % 10];
        return @[ @(d[0]), @(d[1]), @(d[2]), @(d[3]) ];
      }
      continue;
    }
    if ([label isEqualToString:[NSString stringWithFormat:@"%@ Count", name]])
      return @[ @(cp[i].defaultCount) ];
    for (int n = 1; n <= cp[i].maxCount; n++)
      if ([label
              isEqualToString:[NSString stringWithFormat:@"%@ %d", name, n]]) {
        const float *d = (cp[i].hasDefColors && (n - 1) < cp[i].defColorCount)
                             ? cp[i].defColors[n - 1]
                             : kMirageDefaultPalette[(n - 1) % 10];
        return @[ @(d[0]), @(d[1]), @(d[2]), @(d[3]) ];
      }
  }
  return nil;
}

static BOOL MirageValueArraysApproxEqual(NSArray<NSNumber *> *a,
                                         NSArray<NSNumber *> *b) {
  if (a.count != b.count)
    return NO;
  for (NSUInteger i = 0; i < a.count; i++)
    if (fabs(a[i].doubleValue - b[i].doubleValue) > 1e-4)
      return NO;
  return YES;
}

// A lane sits at its plain default when it holds exactly one keypose, at t=0,
// whose values match `values`. An animated lane (>1 keypose) or one whose
// constant was changed reads as user-touched and is left alone.
static BOOL MirageLaneIsAtConstant(KKLane *lane, NSArray<NSNumber *> *values) {
  if (lane.keyposes.count != 1)
    return NO;
  KKKeyPose *kp = lane.keyposes.firstObject;
  if (fabs(kp.time) > 1e-6)
    return NO;
  return MirageValueArraysApproxEqual(kp.values, values);
}

@implementation MirageInspectorView

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                       loopEnabled:(BOOL)loopEnabled
             maintainTimingEnabled:(BOOL)maintainTimingEnabled
                         activeTab:(NSInteger)activeTab
                    availableLanes:(NSArray<KKLane *> *)availableLanes
                          timeline:(KKTimeline *)timeline {
  self = [super initWithAPIManager:apiManager
                       loopEnabled:loopEnabled
             maintainTimingEnabled:maintainTimingEnabled
                         activeTab:activeTab
                    availableLanes:availableLanes
                          timeline:timeline];
  if (self) {
    _thumbAPIManager = apiManager;
    _miniViewerRenderer = [[MirageMiniViewerRenderer alloc] init];
    // Identity for the live-drag ref override: a `${uuid...}` expression ref
    // only resolves against the local timeline when it targets THIS clip.
    _miniViewerRenderer.linkSelfUUID = KKInstanceUUIDForAPI(apiManager);
    // Negative until the render tick says otherwise: unknown must read as
    // silence, not as the clip's first frame.
    _clipTimelineStartSec = -1.0;
    _miniViewerRenderer.audioTimelineTimeSec = -1.0;
    _miniViewerRenderer.linkTimelineSec = -1.0;
    _miniViewerRenderer.clipTimelineStartSec = -1.0;
    // On a fresh instance the persisted param timeline is nil, but the super
    // reconstructs a working timeline from availableLanes (carrying the
    // plasma-seeded Mirage lane) - that's what the editor shows. Seed the mini
    // from that reconstructed timeline, not the raw nil arg, so the mini
    // renders the default plasma (and _loadEntry, which bails on a nil mini
    // timeline, works for browser swaps on a never-touched instance).
    _miniViewerRenderer.timeline =
        self.basicLanesView.currentTimeline ?: timeline;
    self.miniViewerDelegate = _miniViewerRenderer;
    self.miniViewerDescriptorPath = MirageMiniViewerDescriptorPath;
    self.miniViewerRequestPath = MirageMiniViewerRequestPath;
    self.managePopoverSpotlightLabel = @"Speed";
    // The kit's restart/autostart machinery pulls a fresh config from here.
    __weak typeof(self) weak = self;
    self.timingGuideConfigProvider = ^KKTimingGuideConfig * {
      __strong typeof(weak) s = weak;
      return s ? [s _timingGuideConfig] : nil;
    };
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(_shaderSaveRequested:)
               name:KKCodeEditorSaveRequestedNotification
             object:nil];

    _browserController =
        [[MirageBrowserController alloc] initWithLanesView:self.basicLanesView];
    _browserController.onDeleteEntry = ^(MirageCatalogEntry *e) {
      __strong typeof(weak) s = weak;
      [[MirageLocalCatalog shared] deleteEntryID:e.entryID];
      [s->_browserController refreshLocal]; // local change, don't re-fetch
    };
    _browserController.onPublishEntry = ^(MirageCatalogEntry *e) {
      __strong typeof(weak) s = weak;
      [s _publishEntry:e];
    };
    _browserController.onSelectEntry = ^(MirageCatalogEntry *e) {
      __strong typeof(weak) s = weak;
      [s _loadEntry:e];
    };
    _browserController.onRenameEntry =
        ^(MirageCatalogEntry *e, NSString *name) {
          __strong typeof(weak) s = weak;
          [[MirageLocalCatalog shared] renameEntryID:e.entryID toName:name];
          [s->_browserController refreshLocal]; // local change, don't re-fetch
        };
    [self _bakeBuiltinThumbnails];
  }
  return self;
}

// Render each shipped built-in shader (Plasma) to a thumbnail once per process,
// using a throwaway renderer whose timeline holds just that shader's code.
- (void)_bakeBuiltinThumbnails {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    for (MirageCatalogEntry *e in
         [[MirageLocalCatalog shared] builtinEntries]) {
      if (e.thumbnail || !e.sections[@"Image"].length)
        continue;
      MirageMiniViewerRenderer *r = [[MirageMiniViewerRenderer alloc] init];
      KKTimeline *t = [KKTimeline timeline];
      KKLane *lane = [KKLane laneWithKey:kMirageCodeLaneLabel label:kMirageCodeLaneLabel];
      lane.valueType = KKLaneValueTypeCode;
      lane.codeString = e.sections[@"Image"];
      t.lanes = @[ lane ];
      r.timeline = t;
      NSData *jpeg = MirageRenderThumbnailJPEG(r, 320, 180);
      if (jpeg)
        [MirageLocalCatalog
            setBuiltinThumbnail:[[NSImage alloc] initWithData:jpeg]
                        forName:e.name];
    }
  });
}

- (void)dealloc {
  [[NSNotificationCenter defaultCenter] removeObserver:self];
  [_browserController invalidate];
}

// The code editor's save bar (a `codeSavable` lane) fired: persist the current
// sections as a named local catalog entry. Thumbnail rendering + browser
// refresh are wired next.
- (void)_shaderSaveRequested:(NSNotification *)note {
  NSString *name = note.userInfo[KKCodeEditorSaveNameKey];
  NSArray<NSDictionary<NSString *, NSString *> *> *sections =
      note.userInfo[KKCodeEditorSaveSectionsKey];
  if (!name.length)
    return;
  NSMutableDictionary<NSString *, NSString *> *dict =
      [NSMutableDictionary dictionary];
  for (NSDictionary<NSString *, NSString *> *s in sections) {
    NSString *sName = s[@"name"], *code = s[@"code"];
    if (sName.length && code.length)
      dict[sName] = code;
  }
  NSData *preview = MirageRenderThumbnailJPEG(_miniViewerRenderer, 320, 180);
  // No author by default - never derive it from the account name (privacy). The
  // user can add an author when publishing.
  [[MirageLocalCatalog shared]
      saveShaderNamed:name
               author:@""
             category:MirageCategoryAtIndex(
                          note.userInfo[KKCodeEditorSaveCategoryIndexKey])
             sections:dict
          previewJPEG:preview];
  [_browserController
      refreshLocal]; // local save; show the new card, no re-fetch
}

// Publish a saved entry to the community repo as a PR (after a confirm).
- (void)_publishEntry:(MirageCatalogEntry *)entry {
  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = RLoc(@"Publish shader?", @"Publish confirm title.");
  alert.informativeText = [NSString
      stringWithFormat:RLoc(@"\"%@\" will be shared to the community shader "
                            @"catalog. It'll be reviewed before it appears.",
                            @"Publish confirm body."),
                       entry.name];
  // Optional author credit (never auto-filled from the account name).
  NSTextField *authorField =
      [[NSTextField alloc] initWithFrame:NSMakeRect(0, 0, 240, 24)];
  authorField.placeholderString =
      RLoc(@"Author (optional)", @"Publish author field placeholder.");
  authorField.stringValue = entry.author ?: @"";
  alert.accessoryView = authorField;
  [alert addButtonWithTitle:RLoc(@"Publish", @"Publish confirm button.")];
  [alert addButtonWithTitle:RLoc(@"Cancel", @"Cancel button.")];
  if ([alert runModal] != NSAlertFirstButtonReturn)
    return;

  NSString *author = [authorField.stringValue
      stringByTrimmingCharactersInSet:NSCharacterSet
                                          .whitespaceAndNewlineCharacterSet];
  NSDictionary<NSString *, NSData *> *files =
      [[MirageLocalCatalog shared] publishFilesForEntry:entry];
  // Name the preview after whatever the entry actually shipped (the sole
  // non-`.glsl` file), so a legacy `preview.png` save and a new `preview.jpg`
  // one both publish metadata that resolves to the real file.
  NSString *previewName = @"preview.jpg";
  for (NSString *f in files)
    if (![f.pathExtension isEqualToString:@"glsl"]) {
      previewName = f;
      break;
    }
  NSDictionary *meta = @{
    @"id" : entry.entryID,
    @"name" : entry.name,
    @"author" : author ?: @"",
    @"category" : entry.category ?: kMirageCategoryDefault,
    @"version" : @(entry.version),
    @"preview" : previewName,
  };
  NSData *metaJSON =
      [NSJSONSerialization dataWithJSONObject:meta
                                      options:NSJSONWritingSortedKeys
                                        error:nil];
  KKCommunityClient *client =
      [[KKCommunityClient alloc] initWithCatalogFolder:@"Shaders"];
  [client publishWithEntryID:entry.entryID
                        name:entry.name
                      author:author ?: @""
                     version:entry.version
                       files:files
                metadataJSON:metaJSON
                  completion:^(NSString *_Nullable error) {
                    NSAlert *result = [[NSAlert alloc] init];
                    if (error) {
                      result.messageText =
                          RLoc(@"Publish failed", @"Publish failure title.");
                      result.informativeText = error;
                    } else {
                      result.messageText =
                          RLoc(@"Submitted", @"Publish success title.");
                      result.informativeText =
                          RLoc(@"Your shader will appear once it's been "
                               @"reviewed.",
                               @"Publish success body.");
                    }
                    [result runModal];
                  }];
}

// Load a saved entry into the Mirage code lane (Image = codeString, other
// sections = codeTabs) and persist via the inspector's onTimelineMutated
// channel (the host writes the timeline param in an action scope).
- (void)_loadEntry:(MirageCatalogEntry *)entry {
  KKTimeline *current = _miniViewerRenderer.timeline;
  KKLogInfo(@"Mirage[apply] load '%@' sections=%lu currentTimeline=%@ "
            @"onTimelineMutated=%@",
            entry.name, (unsigned long)entry.sections.count,
            current ? @"yes" : @"NIL",
            self.onTimelineMutated ? @"yes" : @"NIL");
  if (!current || !entry.sections.count)
    return;

  NSString *image = entry.sections[@"Image"] ?: @"";
  NSMutableArray<NSDictionary<NSString *, NSString *> *> *tabs =
      [NSMutableArray array];
  for (NSString *name in
       @[ @"Common", @"Buffer A", @"Buffer B", @"Buffer C", @"Buffer D" ])
    if (entry.sections[name].length)
      [tabs addObject:@{@"name" : name, @"code" : entry.sections[name]}];

  NSMutableArray<KKLane *> *lanes = [current.lanes mutableCopy];
  BOOL found = NO;
  for (NSUInteger i = 0; i < lanes.count; i++) {
    if (![lanes[i].key isEqualToString:kMirageCodeLaneLabel])
      continue;
    KKLane *lane = [lanes[i] copy];
    lane.codeString = image;
    lane.codeTabs = tabs.count ? tabs : nil;
    lanes[i] = lane;
    found = YES;
  }
  if (!found)
    return;

  // Reset every shader-declared control (colours, #float / #point / ... props)
  // to the loaded template's defaults. Switching shaders is a compare-looks
  // activity, so each one should come up AS AUTHORED rather than carrying the
  // previous shader's palette/values (which rarely mean the same thing on a
  // different shader). The shared Core lanes (Speed / Seed / Grain) are left
  // alone - they're a global feel the user dials in, not part of any shader's
  // look, so the helper returns nil for them and we skip them.
  NSString *newSource =
      image.length ? image : MirageCustomDefaultShaderSource();
  for (NSUInteger i = 0; i < lanes.count; i++) {
    KKLane *lane = lanes[i];
    if (lane.valueType == KKLaneValueTypeCode)
      continue;
    NSArray<NSNumber *> *def =
        MirageDirectiveDefaultValuesForLabel(newSource, lane.key);
    if (!def)
      continue; // Core lane, or not declared by the new source
    if (MirageLaneIsAtConstant(lane, def))
      continue; // already at the new default - no-op
    KKLane *reset = [lane copy];
    reset.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:def] ];
    lanes[i] = reset;
  }

  KKTimeline *updated = [current copy];
  updated.lanes = lanes;
  if (self.onTimelineMutated)
    self.onTimelineMutated(updated);
  [self applyTimeline:updated];

  // onTimelineMutated only persists kKKParamTimelineData. FCP serves a cached
  // frame at a static playhead and won't re-render off a hidden-param write
  // alone, so the swapped-in shader wouldn't show until the next unrelated
  // render (e.g. editing a lane). Fire the render nudge (fresh nonce -> scratch
  // param) so the viewer refreshes to the loaded shader immediately.
  if (self.onBoundaryPreviewNeedsRender)
    self.onBoundaryPreviewNeedsRender();

  // (The source-derived OSC set re-wires via -applyTimeline: above, which fires
  // onCodeCommitted when the effective shader source changes.)

  // Refresh the open code editor so the loaded shader's code shows + is
  // editable.
  NSMutableArray<NSDictionary<NSString *, NSString *> *> *sections =
      [NSMutableArray arrayWithObject:@{@"name" : @"Image", @"code" : image}];
  [sections addObjectsFromArray:tabs];
  [[NSNotificationCenter defaultCenter]
      postNotificationName:KKCodeEditorReloadNotification
                    object:nil
                  userInfo:@{KKCodeEditorSaveSectionsKey : sections}];
}

- (BOOL)showsOSCVisibilityRow {
  return YES;
}

- (void)applyTimeline:(KKTimeline *)timeline {
  [super applyTimeline:timeline];
  _miniViewerRenderer.timeline = timeline;
  // Refresh this clip's reference-menu thumbnail when its look changes.
  [self _scheduleThumbnailBake];
  // Re-wire the source-derived OSC set (the cog checklist) whenever the
  // effective shader source changes - the SAME re-wire a code-editor commit /
  // browser load does (via onCodeCommitted). Mirrors -shaderSourceFromTimeline:
  // exactly: a present-with-code Mirage lane uses its code, otherwise the baked
  // default. A guide seed drops the code lane => the default => its OSC
  // controls (Center/Scale) load, so the cog isn't stuck on the previous clip's
  // set.
  NSString *effective = MirageCustomDefaultShaderSource();
  for (KKLane *l in timeline.lanes)
    if ([l.key isEqualToString:kMirageCodeLaneLabel] && l.codeString.length) {
      effective = l.codeString;
      break;
    }
  if (![effective isEqualToString:(_lastEffectiveShaderSource ?: @"")]) {
    _lastEffectiveShaderSource = [effective copy];
    // Route through the lanes view's code-commit block (not just the plugin's
    // onCodeCommitted): it re-derives the available-lane set from the source
    // (so the cog checklist resolves display names - Center/Scale, not the raw
    // uCenter/uScale keys) AND forwards to the plugin's OSC re-wire. The base
    // -applyTimeline: skips its own lane re-derive here because the seed's code
    // lane is empty; this uses the resolved effective source instead.
    void (^commit)(NSString *) = self.basicLanesView.onCodeCommitted;
    if (commit)
      commit(effective);
    // A uniform that just became a POSITION OSC (osc=position) can't be
    // expression-driven - its value is authored by the on-screen editable
    // path. Strip any stale link expression a prior `osc=point` (or none) left
    // on such a lane, so the render stops honouring it and the inline
    // expression editor closes. Once-off at the transition (guarded so it
    // doesn't re-persist on every apply).
    NSMutableSet<NSString *> *pathDriven = [NSMutableSet set];
    for (KKLane *t in [MiragePlugin availableLanesForShaderSource:effective])
      if (t.positionPathDriven && t.key)
        [pathDriven addObject:t.key];
    if (pathDriven.count) {
      NSMutableArray<KKLane *> *lanes = [timeline.lanes mutableCopy];
      BOOL changed = NO;
      for (NSUInteger i = 0; i < lanes.count; i++) {
        KKLane *l = lanes[i];
        if (l.linkExpression != nil && [pathDriven containsObject:l.key]) {
          KKLane *c = [l copy];
          c.linkExpression = nil;
          c.positionPathDriven = YES;
          lanes[i] = c;
          changed = YES;
        }
      }
      if (changed && self.onTimelineMutated) {
        KKTimeline *stripped = [timeline copy];
        stripped.lanes = lanes;
        _miniViewerRenderer.timeline = stripped;
        self.onTimelineMutated(stripped);
      }
    }
  }
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (!self.isDetachedCopy)
    [self autostartIntroGuideOnceWithSeenKey:kMirageIntroSeenKey];
  // Bake this clip's thumbnail when it appears on-screen (plain selection,
  // which -applyTimeline: does NOT cover - that only fires on a param change).
  // The detached copy is a mirror, not the source instance.
  if (self.window && !self.isDetachedCopy)
    [self _scheduleThumbnailBake];
}

// Coalesced one-shot bake: bump the generation, fire ~0.8s later only if still
// the latest (so appear + a burst of edits collapse to one bake, and the mini
// has had a moment to render). No repeating poll.
- (void)_scheduleThumbnailBake {
  if (self.isDetachedCopy)
    return;
  NSInteger gen = ++_thumbBakeGeneration;
  __weak typeof(self) weak = self;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.8 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        __strong typeof(weak) s = weak;
        if (s && s->_thumbBakeGeneration == gen)
          [s _bakeLinkThumbnail];
      });
}

// Capture the mini-viewer's current frame as this clip's reference-menu
// thumbnail, keyed by the instance UUID (matching the manifest).
// writeThumbnailJPEG skips a byte-identical rewrite.
- (void)_bakeLinkThumbnail {
  NSString *uuid = KKInstanceUUIDForAPI(_thumbAPIManager);
  if (uuid.length == 0)
    return; // instance UUID not created yet (lazy); a later bake will catch it
  // The inspector has no live mini-viewer canvas, so instead of capturing a
  // displayed frame we re-render on this clip's OWN source - loaded headless
  // from the same per-UUID mini-viewer feed the preview reads (real footage).
  // Pinned to fraction 0.5 for a deterministic poster. A generator publishes no
  // source (src==nil) and re-renders on the bundled reference, which it ignores
  // anyway.
  id<MTLDevice> device = MTLCreateSystemDefaultDevice();
  id<MTLTexture> src = KKMiniViewerFeedLoadPrimarySource(
      MirageMiniViewerDescriptorPathForUUID(uuid), device);
  NSData *jpeg =
      MirageRenderThumbnailJPEGFromSource(_miniViewerRenderer, 320, 180, src);
  if (jpeg.length)
    [KKLinkBus writeThumbnailJPEG:jpeg forUUID:uuid];
}

- (instancetype)beginDetachedCopy {
  return [super beginDetachedCopy];
}

- (void)setClipProjectStartSec:(double)seconds {
  // Base stores it + feed-locks parameter-link timing into the mini
  // generically; we still keep _clipTimelineStartSec for the audio
  // (spectrogram) preview below.
  [super setClipProjectStartSec:seconds];
  if (_clipTimelineStartSec == seconds)
    return;
  _clipTimelineStartSec = seconds;
  [self _pushAudioTimeToMiniViewer];
}

- (double)clipTimelineStartSec {
  return _clipTimelineStartSec;
}

/// The playhead moved: the mini viewer's `// #audio` preview follows it, so the
/// bars show the same instant the viewer does.
- (void)setPlayheadFraction:(double)frac {
  [super setPlayheadFraction:frac];
  _playheadFraction = frac;
  // iProgress in the preview: a transition shader has to show the blend at the
  // playhead, not sit on its outgoing clip.
  _miniViewerRenderer.playheadFraction = frac;
  // iTime in the preview scales the edit/playhead fraction by the clip duration
  // to match the FCP render (frac * durSec); without it the preview crawls.
  _miniViewerRenderer.clipDurationSeconds = [self clipDurationSeconds];
  [self _pushAudioTimeToMiniViewer];
}

- (void)_pushAudioTimeToMiniViewer {
  // Unknown clip position stays negative: that reads as outside the spectrogram
  // (silence), which is honest, where 0 would confidently show the project's
  // first frame no matter where this clip sits.
  if (_clipTimelineStartSec < 0) {
    _miniViewerRenderer.audioTimelineTimeSec = -1.0;
    _miniViewerRenderer.linkTimelineSec = -1.0;
    _miniViewerRenderer.clipTimelineStartSec = -1.0;
    return;
  }
  double dur = [self clipDurationSeconds];
  double projectSec =
      _clipTimelineStartSec + _playheadFraction * (dur > 0 ? dur : 0);
  _miniViewerRenderer.audioTimelineTimeSec = projectSec;
  // Same project time drives parameter-link `${refs}` in the mini-viewer so its
  // preview matches the render. This is the fallback for scrub/static; during
  // live playback the draw path feed-locks the link time from the frame's own
  // fraction (see clipTimelineStartSec) because this poller only fires ~2/sec.
  _miniViewerRenderer.linkTimelineSec = projectSec;
  // Constant clip position (not the moving playhead), so it isn't starved by
  // the poller - the draw path pairs it with the 60fps feed fraction.
  _miniViewerRenderer.clipTimelineStartSec = _clipTimelineStartSec;
}

@end
