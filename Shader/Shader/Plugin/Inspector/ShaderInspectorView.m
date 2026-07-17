/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "ShaderInspectorView.h"

#import "Constants.h" // ShaderCustomDefaultShaderSource
#import "ShaderCategory.h"
#import "ShaderInspectorView+Guides.h"
#import "ShaderInspectorView_Private.h"
#import "ShaderLocalCatalog.h"
#import "ShaderLocalized.h"
#import "ShaderMiniViewerRenderer.h"
#import "ShaderThumbnailRenderer.h"
#import <KeyframelessKit/KKTimelineInspectorView+Guide.h>
#import <KeyframelessKit/KKTimingGuide.h>
@import KKCommunity;

static NSString *const kShaderIntroSeenKey = @"ShaderIntroSeen";

@implementation ShaderInspectorView

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
    _miniViewerRenderer = [[ShaderMiniViewerRenderer alloc] init];
    // Negative until the render tick says otherwise: unknown must read as
    // silence, not as the clip's first frame.
    _clipTimelineStartSec = -1.0;
    _miniViewerRenderer.audioTimelineTimeSec = -1.0;
    // On a fresh instance the persisted param timeline is nil, but the super
    // reconstructs a working timeline from availableLanes (carrying the
    // plasma-seeded Shader lane) - that's what the editor shows. Seed the mini
    // from that reconstructed timeline, not the raw nil arg, so the mini
    // renders the default plasma (and _loadEntry, which bails on a nil mini
    // timeline, works for browser swaps on a never-touched instance).
    _miniViewerRenderer.timeline =
        self.basicLanesView.currentTimeline ?: timeline;
    self.miniViewerDelegate = _miniViewerRenderer;
    self.miniViewerDescriptorPath = ShaderMiniViewerDescriptorPath;
    self.miniViewerRequestPath = ShaderMiniViewerRequestPath;
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
        [[ShaderBrowserController alloc] initWithLanesView:self.basicLanesView];
    _browserController.onDeleteEntry = ^(ShaderCatalogEntry *e) {
      __strong typeof(weak) s = weak;
      [[ShaderLocalCatalog shared] deleteEntryID:e.entryID];
      [s->_browserController refreshLocal]; // local change, don't re-fetch
    };
    _browserController.onPublishEntry = ^(ShaderCatalogEntry *e) {
      __strong typeof(weak) s = weak;
      [s _publishEntry:e];
    };
    _browserController.onSelectEntry = ^(ShaderCatalogEntry *e) {
      __strong typeof(weak) s = weak;
      [s _loadEntry:e];
    };
    _browserController.onRenameEntry =
        ^(ShaderCatalogEntry *e, NSString *name) {
          __strong typeof(weak) s = weak;
          [[ShaderLocalCatalog shared] renameEntryID:e.entryID toName:name];
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
    for (ShaderCatalogEntry *e in
         [[ShaderLocalCatalog shared] builtinEntries]) {
      if (e.thumbnail || !e.sections[@"Image"].length)
        continue;
      ShaderMiniViewerRenderer *r = [[ShaderMiniViewerRenderer alloc] init];
      KKTimeline *t = [KKTimeline timeline];
      KKLane *lane = [KKLane laneWithLabel:@"Shader"];
      lane.valueType = KKLaneValueTypeCode;
      lane.codeString = e.sections[@"Image"];
      t.lanes = @[ lane ];
      r.timeline = t;
      NSData *png = ShaderRenderThumbnailPNG(r, 320, 180);
      if (png)
        [ShaderLocalCatalog
            setBuiltinThumbnail:[[NSImage alloc] initWithData:png]
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
  NSData *preview = ShaderRenderThumbnailPNG(_miniViewerRenderer, 320, 180);
  // No author by default - never derive it from the account name (privacy). The
  // user can add an author when publishing.
  [[ShaderLocalCatalog shared]
      saveShaderNamed:name
               author:@""
             category:ShaderCategoryAtIndex(
                          note.userInfo[KKCodeEditorSaveCategoryIndexKey])
             sections:dict
           previewPNG:preview];
  [_browserController
      refreshLocal]; // local save; show the new card, no re-fetch
}

// Publish a saved entry to the community repo as a PR (after a confirm).
- (void)_publishEntry:(ShaderCatalogEntry *)entry {
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
      [[ShaderLocalCatalog shared] publishFilesForEntry:entry];
  NSDictionary *meta = @{
    @"id" : entry.entryID,
    @"name" : entry.name,
    @"author" : author ?: @"",
    @"category" : entry.category ?: kShaderCategoryDefault,
    @"version" : @(entry.version),
    @"preview" : @"preview.png",
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

// Load a saved entry into the Shader code lane (Image = codeString, other
// sections = codeTabs) and persist via the inspector's onTimelineMutated
// channel (the host writes the timeline param in an action scope).
- (void)_loadEntry:(ShaderCatalogEntry *)entry {
  KKTimeline *current = _miniViewerRenderer.timeline;
  KKLogInfo(@"Shader[apply] load '%@' sections=%lu currentTimeline=%@ "
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
    if (![lanes[i].label isEqualToString:@"Shader"])
      continue;
    KKLane *lane = [lanes[i] copy];
    lane.codeString = image;
    lane.codeTabs = tabs.count ? tabs : nil;
    lanes[i] = lane;
    found = YES;
  }
  if (!found)
    return;

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
  // Re-wire the source-derived OSC set (the cog checklist) whenever the
  // effective shader source changes - the SAME re-wire a code-editor commit /
  // browser load does (via onCodeCommitted). Mirrors -shaderSourceFromTimeline:
  // exactly: a present-with-code Shader lane uses its code, otherwise the baked
  // default. A guide seed drops the code lane => the default => its OSC
  // controls (Center/Scale) load, so the cog isn't stuck on the previous clip's
  // set.
  NSString *effective = ShaderCustomDefaultShaderSource();
  for (KKLane *l in timeline.lanes)
    if ([l.label isEqualToString:@"Shader"] && l.codeString.length) {
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
  }
}

- (void)viewDidMoveToWindow {
  [super viewDidMoveToWindow];
  if (!self.isDetachedCopy)
    [self autostartIntroGuideOnceWithSeenKey:kShaderIntroSeenKey];
}

- (instancetype)beginDetachedCopy {
  return [super beginDetachedCopy];
}

- (void)setClipProjectStartSec:(double)seconds {
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
  [self _pushAudioTimeToMiniViewer];
}

- (void)_pushAudioTimeToMiniViewer {
  // Unknown clip position stays negative: that reads as outside the spectrogram
  // (silence), which is honest, where 0 would confidently show the project's
  // first frame no matter where this clip sits.
  if (_clipTimelineStartSec < 0) {
    _miniViewerRenderer.audioTimelineTimeSec = -1.0;
    return;
  }
  double dur = [self clipDurationSeconds];
  _miniViewerRenderer.audioTimelineTimeSec =
      _clipTimelineStartSec + _playheadFraction * (dur > 0 ? dur : 0);
}

@end
