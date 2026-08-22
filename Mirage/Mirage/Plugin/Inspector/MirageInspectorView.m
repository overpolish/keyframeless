/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "MirageInspectorView.h"
#import "MirageOSCSnapshot.h" // publish the OSC timeline snapshot

#import "Constants.h"
#import "KKGLSLTranspiler.h" // MirageMotionBlurDefaultsOnForSource
#import "MirageCategory.h"
#import "MirageColorSurfaceProps.h" // #color-surface opt-in
#import "MirageDirectives.h"        // #color / #float ... default parsing
#import "MirageInspectorView+Guides.h"
#import "MirageInspectorView_Private.h"
#import "MirageLocalCatalog.h"
#import "MirageLocalized.h"
#import "MirageMiniViewerRenderer.h"
#import "MirageRack.h" // rack entry ids + per-entry code lane keys
#import "MirageThumbnailRenderer.h"
#import "Plugin_Private.h" // +availableLanesForShaderSource:
#import <KeyframelessKit/KKCurveDefaults.h>
#import <KeyframelessKit/KKLog.h>
#import <KeyframelessKit/KKScopedDefaults.h>
#import <KeyframelessKit/KKSlotInstances.h>
#import <KeyframelessKit/KKTimelineInspectorView+Guide.h>
#import <KeyframelessKit/KKTimingGuide.h>
@import KKCommunity;

static NSString *const kMirageIntroSeenKey = @"MirageIntroSeen";

// The rack-derived lane templates carry each entry's display name into the
// Animated owner menu, filter, Advanced headers, Parameter Order and the OSC
// owner dropdown. A save-name edit changes none of the source/slot signatures
// that normally rebuild those templates, so fingerprint the persisted names
// separately. Length-prefixing keeps the signature unambiguous even when a
// user puts punctuation in a name.
static NSString *MirageRackNameSignature(KKTimeline *timeline) {
  NSMutableString *signature = [NSMutableString string];
  for (NSString *entryID in MirageRackEntryIDs(timeline)) {
    NSString *name = MirageRackCodeLaneForEntry(
                         timeline, entryID, kMirageCodeLaneLabel)
                         .codeSaveName ?: @"";
    [signature appendFormat:@"%lu:%@=%lu:%@;", (unsigned long)entryID.length,
                            entryID, (unsigned long)name.length, name];
  }
  return signature;
}

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

  // Gradients: identity is the uniform name; the seed is the directive's
  // `default="#hex@pos,..."` else the black -> white ramp, flattened the same
  // way MirageAppendGradientLanes seeds the lane.
  const MirageGradientProp *gp = model.gradientProps;
  for (int i = 0; i < model.gradientCount; i++) {
    if (![label isEqualToString:@(gp[i].name)])
      continue;
    NSMutableArray<NSNumber *> *flat = [NSMutableArray array];
    for (int s = 0; s < gp[i].defStopCount; s++)
      for (int k = 0; k < KK_GRADIENT_STOP_STRIDE; k++)
        [flat addObject:@(gp[i].defStops[s][k])];
    return flat;
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
    // chosen default's Mirage lane) - that's what the editor shows. Seed the mini
    // from that reconstructed timeline, not the raw nil arg, so the mini
    // renders the same default (and _loadEntry, which bails on a nil mini
    // timeline, works for browser swaps on a never-touched instance).
    _miniViewerRenderer.timeline =
        self.basicLanesView.currentTimeline ?: timeline;
    self.miniViewerDelegate = _miniViewerRenderer;
    // Let the popover mini take key focus on click, the same opt-in Canvas
    // makes for its bare Delete. It is what puts this process's window in the
    // key position, and therefore what lets the Color panel's B, S and M reach
    // a LOCAL key monitor - the only kind that can return nil and stop FCP
    // seeing the letter too. Without it the panel's shortcuts fired from an
    // observe-only global monitor: the matte flipped AND FCP took the M as
    // "add marker". Focus is held only while in the mini, so clicking back into
    // FCP hands the keyboard straight back and host shortcuts keep working.
    self.miniGrabsKeyFocusOnClick = YES;
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
    _colorPanelController = [[MirageColorPanelController alloc]
        initWithLanesView:self.basicLanesView
               apiManager:apiManager];
    self.basicLanesView.onEditorCompactModeChanged = ^(BOOL compact) {
      __strong typeof(weak) s = weak;
      [s->_colorPanelController presentationContextDidChange];
    };
    // Mirage opts into the shared right-panel header control; Canvas and other
    // plugins leave this capability off, so no dead button appears for them.
    self.basicLanesView.editorRightPanelToggleSupported = YES;
    self.basicLanesView.editorRightPanelToggleAvailable = NO;
    _colorPanelController.onSurfaceAvailabilityChanged = ^(BOOL available) {
      __strong typeof(weak) s = weak;
      s.basicLanesView.editorRightPanelToggleAvailable = available;
    };
    self.basicLanesView.onEditorRightPanelVisibilityChanged = ^(BOOL visible) {
      __strong typeof(weak) s = weak;
      if (s)
        s->_colorPanelController.userVisible = visible;
    };
    _colorPanelController.userVisible =
        self.basicLanesView.editorRightPanelVisible;
    // The puck writes real controls, so it persists through the same chain as
    // any other edit, and brackets its drag so the burst collapses to one undo
    // entry.
    _colorPanelController.onTimelineMutated = ^(KKTimeline *updated) {
      __strong typeof(weak) s = weak;
      if (s.onTimelineMutated)
        s.onTimelineMutated(updated);
      [s applyTimeline:updated];
    };
    _colorPanelController.onDragBegin = ^{
      __strong typeof(weak) s = weak;
      if (s.onDragBegin)
        s.onDragBegin();
    };
    _colorPanelController.onDragEnd = ^{
      __strong typeof(weak) s = weak;
      if (s.onDragEnd)
        s.onDragEnd();
    };
    // The compare row goes with the PREVIEW, not with the panel: a template
    // with no `#color-surface` has no panel at all, and before/after is exactly
    // what such a template (a denoise above all) is judged by. Its selection
    // switch is asserted through the panel's one preview-override push, so the
    // matte and the panel's active key can never contradict each other.
    _compareControls =
        [[MirageMiniCompareControls alloc] initWithLanesView:self.basicLanesView
                                                  apiManager:apiManager];
    _compareControls.onSelectionChanged = ^(BOOL showing) {
      __strong typeof(weak) s = weak;
      if (s) {
        s->_miniViewerRenderer.selectionMatteActive = showing;
        s->_colorPanelController.showSelectionActive = showing;
      }
    };
    _compareControls.shortcutsSuppressed = ^BOOL {
      __strong typeof(weak) s = weak;
      return s ? s->_colorPanelController.gestureInFlight : NO;
    };
    [self _bakeBuiltinThumbnails];
    // The shader chain sits in the parameter popover, between the preview and
    // the controls - where the picture it produces and the controls that shape
    // it are both already on screen. The popover asks for the strip each time
    // it opens and owns it until it closes.
    self.basicLanesView.staticValuesAccessoryHeight =
        [MirageShaderRackView stripHeight];
    self.basicLanesView.staticValuesAccessoryProvider = ^NSView * {
      __strong typeof(weak) s = weak;
      return s ? [s buildRackStrip] : nil;
    };
    // ...and the rows below the strip are the SELECTED entry's, not the whole
    // chain's. The graphs still show every entry (a chain is one animation),
    // so the scope is the constants editor's alone - and it is a display
    // filter over lanes that keep their full prefixed keys, so no write path,
    // link resolution or value popover changes with the selection.
    // A rack entry's keyposes are ONE co-timed set, so a keypose popover only
    // ever edits the params actually keyed there - the rest are dimmed, not
    // offered an "Animate" button (Canvas's independently-keyed layers keep
    // that affordance, which is why it is opt-in).
    self.basicLanesView.keyposeStrictCoTimed = YES;
    self.basicLanesView.constantsLaneFilter = ^BOOL(KKLane *lane) {
      __strong typeof(weak) s = weak;
      return s ? [s rackShowsLaneInConstants:lane] : YES;
    };
    // Clicking a keypose belonging to another entry moves the strip's selection
    // to it, so the popover the click opened, the constants scope and the color
    // panel all agree on which shader is being edited. The kit already stored
    // the layer on itself before this fires; _rackSelectEntry re-asserting the
    // same value is idempotent.
    self.basicLanesView.onKeyposeLayerActivated = ^(NSString *layerKey) {
      __strong typeof(weak) s = weak;
      if (!s || !layerKey.length)
        return;
      // User-driven, so it persists and is undoable exactly like a box click.
      [s _rackSelectEntry:layerKey persist:YES];
      [s refreshRack];
    };
  }
  return self;
}

- (void)refreshColorReferencePickerAvailability {
  [_colorPanelController presentationContextDidChange];
}

// Render each shipped built-in shader to a thumbnail once per process, using a
// throwaway renderer whose timeline holds that shader's code plus whatever card
// values the entry declares. Everything not overridden draws at its DECLARED
// default, which is what makes a filter's thumbnail meaningful - it lands on
// the bundled PreviewSource frame rather than on black. The overrides exist for
// the shaders whose defaults are visually inert (see `thumbnailValues`).
- (void)_bakeBuiltinThumbnails {
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    for (MirageCatalogEntry *e in
         [[MirageLocalCatalog shared] builtinEntries]) {
      if (e.thumbnail || !e.sections[@"Image"].length)
        continue;
      MirageMiniViewerRenderer *r = [[MirageMiniViewerRenderer alloc] init];
      KKTimeline *t = [KKTimeline timeline];
      KKLane *lane = [KKLane laneWithKey:kMirageCodeLaneLabel
                                   label:kMirageCodeLaneLabel];
      lane.valueType = KKLaneValueTypeCode;
      lane.codeString = e.sections[@"Image"];
      // Carry the entry's OTHER sections too, exactly as _loadEntry does. An
      // Image section is not necessarily self-contained: Frame keeps its shared
      // helpers in Common and its glow blur in Buffer B/C/D, so baking Image
      // alone failed to compile and the card rendered the red error shader.
      NSMutableArray<NSDictionary<NSString *, NSString *> *> *tabs =
          [NSMutableArray array];
      for (NSString *name in
           @[ @"Common", @"Buffer A", @"Buffer B", @"Buffer C", @"Buffer D" ])
        if (e.sections[name].length)
          [tabs addObject:@{@"name" : name, @"code" : e.sections[name]}];
      lane.codeTabs = tabs.count ? tabs : nil;
      // Card values, where the entry declares them: one minimal lane per
      // override, keyed by the UNIFORM NAME (which is the lane identity the
      // render resolves against, so no other metadata is needed - a missing
      // lane falls back to the directive default, which is exactly what every
      // un-overridden control still does).
      NSMutableArray<KKLane *> *laneSet = [NSMutableArray arrayWithObject:lane];
      [e.thumbnailValues
          enumerateKeysAndObjectsUsingBlock:^(
              NSString *uniform, NSArray<NSNumber *> *values, BOOL *stop) {
            if (!uniform.length || !values.count)
              return;
            KKLane *seed = [KKLane laneWithKey:uniform label:uniform];
            [seed insertKeypose:[KKKeyPose keyposeAtTime:0.0 values:values]];
            [laneSet addObject:seed];
          }];
      t.lanes = laneSet;
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
  [_colorPanelController invalidate];
  [_compareControls invalidate];
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
  if (!MirageCategoryForSource(dict[@"Image"]).length) {
    NSAlert *alert = [NSAlert new];
    alert.messageText =
        RLoc(@"Template type required", @"Missing template directive alert.");
    alert.informativeText =
        RLoc(@"Add exactly one `// #template generator`, `filter`, `layout`, "
             @"or `transition` line to the Image shader before saving.",
             @"Missing template directive alert detail.");
    [alert runModal];
    return;
  }
  NSData *preview = MirageRenderThumbnailJPEG(_miniViewerRenderer, 320, 180);
  // No author by default - never derive it from the account name (privacy). The
  // user can add an author when publishing.
  MirageCatalogEntry *saved =
      [[MirageLocalCatalog shared] saveShaderNamed:name
                                            author:@""
                                          sections:dict
                                       previewJPEG:preview];
  if (!saved)
    return;
  // Adopt the new entry's id so this instance is now "running that template" -
  // the same identity a browser load stamps, and what its saved curve defaults
  // are keyed by.
  [self _stampCodeSaveID:saved.entryID];
  [_browserController
      refreshLocal]; // local save; show the new card, no re-fetch
}

// Write `entryID` onto the code lane and publish, so the identity survives the
// round-trip. A no-op when the lane already carries it.
- (void)_stampCodeSaveID:(NSString *)entryID {
  KKTimeline *current = _miniViewerRenderer.timeline;
  if (!current || !entryID.length)
    return;
  // Saving forks a template: the catalog mints a FRESH id per save, so the new
  // one starts with no defaults of its own. Carry over whatever was tuned on
  // the template this was saved FROM - a variant of Magic Move should keep
  // Magic Move's curve / OSC defaults until it is given its own.
  // `current` still carries the id this was saved FROM, so syncing against it
  // gives the source scope; the stamp + applyTimeline below move the active
  // scope onto the new id.
  [self _syncCurveDefaultsScope:current];
  KKScopedDefaultsCopyScope(
      KKDefaultsActiveScope(),
      [[self _curveDefaultsBaseScope] stringByAppendingFormat:@"/%@", entryID]);
  NSMutableArray<KKLane *> *lanes = [current.lanes mutableCopy];
  BOOL changed = NO;
  // The save bar saves what the EDITOR is showing, which is the selected rack
  // entry's code - so that is the lane the new template identity lands on.
  NSString *codeKey = MirageRackCodeLaneKey(self.selectedRackEntryID.length
                                                ? self.selectedRackEntryID
                                                : kMirageRackSentinelEntryID,
                                            kMirageCodeLaneLabel);
  for (NSUInteger i = 0; i < lanes.count; i++) {
    if (![lanes[i].key isEqualToString:codeKey])
      continue;
    if ([(lanes[i].codeSaveID ?: @"") isEqualToString:entryID])
      continue;
    KKLane *lane = [lanes[i] copy];
    lane.codeSaveID = entryID;
    lanes[i] = lane;
    changed = YES;
  }
  if (!changed)
    return;
  KKTimeline *updated = [current copy];
  updated.lanes = lanes;
  if (self.onTimelineMutated)
    self.onTimelineMutated(updated);
  [self applyTimeline:updated];
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

// Load a saved entry into the SELECTED rack entry's code lane (Image =
// codeString, other sections = codeTabs) and persist via the inspector's
// onTimelineMutated channel (the host writes the timeline param in an action
// scope).
//
// Which entry: the one the strip has selected. Picking a template is a SWAP,
// and what it swaps is the link the user is standing on - an unracked project
// has exactly one, the sentinel, whose key is the bare code lane every
// pre-rack project persisted.
- (void)_loadEntry:(MirageCatalogEntry *)entry {
  KKTimeline *current = _miniViewerRenderer.timeline;
  if (!current || !entry.sections.count)
    return;
  NSString *targetEntry = self.selectedRackEntryID.length
                              ? self.selectedRackEntryID
                              : kMirageRackSentinelEntryID;
  NSString *codeKey = MirageRackCodeLaneKey(targetEntry, kMirageCodeLaneLabel);

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
    if (![lanes[i].key isEqualToString:codeKey])
      continue;
    KKLane *lane = [lanes[i] copy];
    lane.codeString = image;
    lane.codeTabs = tabs.count ? tabs : nil;
    // Loading a named shader names the instance: the save bar shows it, and
    // the link-bus source is labelled with it instead of a bare "Mirage".
    lane.codeSaveName = entry.name.length ? entry.name : nil;
    // The entry's UUID, not its name: it survives renames and code edits, so
    // it is what scopes this template's saved curve / modulate defaults.
    lane.codeSaveID = entry.entryID.length ? entry.entryID : nil;
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
      image.length ? image : MirageDefaultShaderSource();
  for (NSUInteger i = 0; i < lanes.count; i++) {
    KKLane *lane = lanes[i];
    if (lane.valueType == KKLaneValueTypeCode)
      continue;
    // Only the entry being swapped, and asked about under its BARE key - the
    // directive name is what the shader declared, which is the key with the
    // rack scope peeled off. Another entry in the chain is a different shader
    // and its values are none of this template's business.
    NSString *owner = nil, *bareKey = nil;
    MirageRackParseLaneKey(lane.key, &owner, &bareKey);
    if (![owner isEqualToString:targetEntry])
      continue;
    NSArray<NSNumber *> *def =
        MirageDirectiveDefaultValuesForLabel(newSource, bareKey);
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
  // Publish to the OSC's process snapshot BEFORE the host write. The OSC
  // builds its controls from that snapshot, and it is otherwise only refreshed
  // by parameterChanged - i.e. after FCP round-trips the write below. Until
  // then the snapshot still has the OLD code lane (or, on a fresh instance,
  // none at all, so -_currentShaderSource falls back to the chosen default
  // source). Either way the OSC keeps the PREVIOUS shader's controls: applying
  // MagicMove could leave the previous template's controls registered, so a
  // click on the new shader's rotation ring hit nothing and the control looked
  // dead until something forced a resync.
  MirageSetTimelineSnapshot(updated);
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

  // A shader whose `// #motionblur` line says `on` starts with blur enabled
  // (Magic Move: a transform without it reads as a hard cut per frame). Only
  // on APPLY - doing this on every code commit would re-tick the box under a
  // user who deliberately turned it off. Write the persisted blob too, not
  // just the checkbox, so it survives the round-trip.
  if (MirageMotionBlurDefaultsOnForSource(entry.sections[@"Image"])) {
    [self setMotionBlurEnabled:YES];
    if (self.onMotionBlurChanged)
      self.onMotionBlurChanged(YES, 180.0, [self motionBlurDefaultSamples],
                               KKMotionBlurTechniqueAccurate);
  }

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

// Mirage keeps its curve / modulate defaults per TEMPLATE, not just per plugin:
// a bounce that suits Magic Move is wrong for a plasma. The code lane's
// `codeSaveID` is the template identity (stable across renames and edits);
// without one - code the user never saved or loaded - the plugin-wide scope
// stands, which is also what the plugin process itself uses.
// The plugin-wide part of the defaults scope: the preset key, falling back to
// the bundle id when the host hasn't handed it over yet (the same string
// presetPluginKey resolves to, so the scope never splits on timing).
- (NSString *)_curveDefaultsBaseScope {
  return self.presetPluginKey.length
             ? self.presetPluginKey
             : ([NSBundle bundleForClass:[self class]].bundleIdentifier
                    ?: @"Mirage");
}

- (void)_syncCurveDefaultsScope:(KKTimeline *)timeline {
  NSString *base = [self _curveDefaultsBaseScope];
  // The SELECTED entry's template identity: with a chain, the curve defaults
  // that apply are the ones belonging to the shader whose controls are on
  // screen.
  NSString *codeKey = MirageRackCodeLaneKey(self.selectedRackEntryID.length
                                                ? self.selectedRackEntryID
                                                : kMirageRackSentinelEntryID,
                                            kMirageCodeLaneLabel);
  NSString *entryID = nil;
  for (KKLane *l in timeline.lanes)
    if ([l.key isEqualToString:codeKey] && l.codeSaveID.length) {
      entryID = l.codeSaveID;
      break;
    }
  KKDefaultsSetActiveScope(
      entryID.length ? [base stringByAppendingFormat:@"/%@", entryID] : base);
}

- (BOOL)showsOSCVisibilityRow {
  return YES;
}

// A `#slots` instance count is the OTHER thing the lane set is a function of,
// and it moves without the source moving: undo, redo, a preset apply and an
// AI merge all arrive as a timeline blob whose registry disagrees with the
// templates currently in the rows. The panel's own +/- paths re-derive
// explicitly; nothing else did, so an undone removal put the instance's lanes
// back in the timeline while `hidesLanesWithoutTemplate` filtered its rows
// out - a handle on the wheel with no controls under it.
//
// BEFORE super, unlike the source-change re-wire in -applyTimeline:. That
// filter runs inside -[KKTimelineInspectorView applyTimeline:], against the
// templates it holds AT THAT MOMENT, so templates re-derived afterwards would
// arrive one apply too late - and an undo does not necessarily produce a second
// apply. A source change is already handled pre-filter by the base class's own
// re-derive; a slots change is invisible to it, since the code is identical.
//
// Derived against the INCOMING timeline, and not by faking a code commit.
// Both halves of that matter:
//
//  * the provider's default is the lanes view's live timeline, which pre-super
//    is still the one the undo is replacing. Deriving against it stamps
//    templates for the instance count that was just reverted - re-deriving to
//    exactly the wrong answer, which is why the first version of this logged
//    the trigger and changed nothing;
//  * `onCodeCommitted` means the SOURCE changed, and here it is identical to
//    the character. Its other subscribers are all source-derived: the OSC
//    checklist would be re-wired to a compound set that cannot have moved
//    (`oscCompoundsForShaderSource:` never reads the timeline), and the
//    `#motionblur` handler would clear persisted state this undo never
//    touched. So the lanes are applied directly instead.
//
// Answers the instance this change restored, if it restored one. Resolved
// here, where both signatures are in hand, and spent after super - the handle
// it names does not exist until the panel has rebuilt its pucks from the new
// registry.
- (NSString *)_slotRegistryChangedForTimeline:(KKTimeline *)timeline
                                    effective:(NSString *)effective {
  NSString *slotSignature = KKSlotRegistrySignature(timeline);
  if ([slotSignature isEqualToString:(_lastSlotSignature ?: @"")] ||
      !self.availableLanesProvider)
    return nil;
  NSArray<KKLane *> *lanes = self.availableLanesProvider(effective, timeline);
  [self applyAvailableLanes:lanes];
  // Read back rather than storing what was measured: deriving brings a group
  // this project has never registered up to its declared default, IN this
  // timeline, so the registry just derived from is the post-stamp one.
  NSString *derived = KKSlotRegistrySignature(timeline);
  NSString *restoredGroup = nil;
  NSString *restoredInstance =
      KKSlotFirstAddedInstance(_lastSlotSignature, derived, &restoredGroup);
  _lastSlotSignature = [derived copy];
  // The rack rides the SAME registry, so appending a link is a slot-registry
  // addition by this measure - and the id it adds is a rack entry, not a puck.
  // Handing it to the Color panel would point it at a handle that either does
  // not exist or, since both come from the same minter, is some unrelated
  // instance that happens to share the id. The re-derive above still stands (a
  // rack change does move the lane set); only the SELECTION is refused.
  if ([restoredGroup isEqualToString:kMirageRackGroupName]) {
    return nil;
  }
  return restoredInstance;
}

- (void)applyTimeline:(KKTimeline *)timeline {
  // The SELECTED rack entry's code lane, or the chosen default when it has none
  // (a guide seed drops the code lane, so it resolves to the default). "The"
  // shader for everything below - the editor, the OSC set, `#motionblur` and
  // the Color panel are all statements about the link the user is standing on,
  // and an unracked project has exactly one, whose key is the bare code lane.
  NSString *selectedEntry = self.selectedRackEntryID.length
                                ? self.selectedRackEntryID
                                : kMirageRackSentinelEntryID;
  NSString *codeKey =
      MirageRackCodeLaneKey(selectedEntry, kMirageCodeLaneLabel);
  NSString *effective = MirageDefaultShaderSource();
  for (KKLane *l in timeline.lanes)
    if ([l.key isEqualToString:codeKey] && l.codeString.length) {
      effective = l.codeString;
      break;
    }
  BOOL sourceChanged =
      ![effective isEqualToString:(_lastEffectiveShaderSource ?: @"")];

  NSString *rackNameSignature = MirageRackNameSignature(timeline);
  BOOL rackNameChanged =
      ![rackNameSignature isEqualToString:(_lastRackNameSignature ?: @"")];
  // Rename-only changes used to refresh just the rack strip because it reads
  // codeSaveName directly. Every other surface reads layerLabel from the
  // derived templates, so replace those BEFORE super filters/rebuilds the
  // incoming timeline. A simultaneous source change takes the existing
  // source-commit route below, which derives the same metadata once.
  if (rackNameChanged && !sourceChanged && self.availableLanesProvider) {
    NSArray<KKLane *> *lanes = self.availableLanesProvider(effective, timeline);
    [self applyAvailableLanes:lanes];
  }
  _lastRackNameSignature = [rackNameSignature copy];

  NSString *restoredInstance =
      sourceChanged
          ? nil
          : [self _slotRegistryChangedForTimeline:timeline effective:effective];

  [super applyTimeline:timeline];
  _miniViewerRenderer.timeline = timeline;
  [self _syncCurveDefaultsScope:timeline];
  // Refresh this clip's reference-menu thumbnail when its look changes.
  [self _scheduleThumbnailBake];
  MirageColorSurfaceSpace surfaceSpace = MirageColorSurfaceSpaceInvalid;
  MirageColorSurfaceError surfaceError = MirageColorSurfaceErrorNone;
  BOOL wantsSurface =
      MirageColorSurfaceForSource(effective, &surfaceSpace, &surfaceError) &&
      surfaceError == MirageColorSurfaceErrorNone;
  // BEFORE the opt-in: the panel resolves its rings, pucks and lanes from the
  // entry it is pointed at, so pointing it must come first or a swap between
  // two grading templates would rebuild against the outgoing one.
  _colorPanelController.selectedRackEntryID = selectedEntry;
  self.basicLanesView.editorRightPanelToggleAvailable = wantsSurface;
  _colorPanelController.surfaceEnabled = wantsSurface;
  [_colorPanelController timelineDidChange];
  // A recompile can add or drop `preview=selection` under an open popover, and
  // the row's one shader-dependent button is a function of exactly that.
  [_compareControls timelineDidChange];
  // The chain is a function of the timeline, so every arrival re-derives it -
  // including the ones the rack didn't cause (an undo, a preset, an AI merge).
  [self refreshRack];
  // Now that the refresh above has rebuilt the handles from the new registry,
  // the restored one exists and can be selected. Only an ADDITION gets here -
  // the panel's own +/- already place their selection, and a removal has
  // nothing to select, so its neighbour fallback stands.
  if (restoredInstance.length)
    [_colorPanelController selectSlotInstance:restoredInstance];
  // Re-wire the source-derived OSC set (the cog checklist) whenever the
  // effective shader source changes - the SAME re-wire a code-editor commit /
  // browser load does (via onCodeCommitted), so the cog isn't stuck on the
  // previous clip's set.
  if (sourceChanged) {
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
    // Read back for the same reason the slots trigger does, off the timeline
    // THIS derive stamped into: the commit above runs post-super and hands the
    // provider no timeline, so it derived against - and stamped into - the
    // lanes view's live one, which by now is the applied timeline.
    _lastSlotSignature = [KKSlotRegistrySignature(
        self.basicLanesView.currentTimeline ?: timeline) copy];
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

/// Motion-blur state reaching the preview. Only a `// #motionblur native`
/// shader consumes it (the renderer gates on the mode), but the inspector
/// pushes it unconditionally - the mode lives in the shader source, which
/// changes under the editor, so deciding here would go stale.
///
/// Shutter is normalised the same way the FCP render normalises it: 360deg is
/// one frame, so angle/360 == shutterSec/frameDur. Disabled zeroes it, matching
/// a render with blur off.
- (void)_pushMotionBlurToMiniViewer {
  _miniViewerRenderer.motionBlurShutterFraction =
      _mbPreviewEnabled ? (float)(_mbPreviewShutterAngle / 360.0) : 0.0f;
  _miniViewerRenderer.motionBlurSamples = (int)_mbPreviewSamples;
}

- (void)setMotionBlurEnabled:(BOOL)enabled {
  [super setMotionBlurEnabled:enabled];
  _mbPreviewEnabled = enabled;
  [self _pushMotionBlurToMiniViewer];
}

- (void)setMotionBlurShutterAngle:(double)shutterAngle
                          samples:(NSInteger)samples {
  [super setMotionBlurShutterAngle:shutterAngle samples:samples];
  _mbPreviewShutterAngle = shutterAngle;
  _mbPreviewSamples = samples;
  [self _pushMotionBlurToMiniViewer];
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
  // The preview's overrides are keyed to the fraction they were pushed at, so a
  // playhead move drops them until they are asserted again. With no Color panel
  // open nothing else would: the panel re-asserts on every frame it samples,
  // and a plain filter samples none. Idempotent, so this costs a comparison
  // when the matte is not showing.
  [_colorPanelController reassertPreviewOverrides];
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
