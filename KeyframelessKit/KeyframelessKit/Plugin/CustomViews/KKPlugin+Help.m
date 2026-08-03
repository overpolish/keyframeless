/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKDataBlob.h"
#import "KKHelpSection+Markdown.h"
#import "KKHelpSection.h"
#import "KKHelpView+Guides.h"
#import "KKHelpView.h"
#import "KKJoyrideGuideHost.h"
#import "KKLocalized.h"
#import "KKLog.h"
#import "KKMarkup.h"
#import "KKPluginHost.h"
#import "KKPlugin_Private.h"
#import "KKTimelineInspectorView.h"
#import "KKTimingEvaluation.h"
#import "KKTimeline.h"
#import <FxPlug/FxPlugSDK.h>

#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation KKPlugin (Help)

- (void)patchUIStateKey:(NSString *)key
                  value:(id)value
                paramID:(UInt32)paramID {
  [self patchUIStateKeys:@{key : value} paramID:paramID];
}

- (void)patchUIStateKeys:(NSDictionary<NSString *, id> *)values
                 paramID:(UInt32)paramID {
  [self kkInParamAction:^(id<FxParameterRetrievalAPI_v6> getAPI,
                          id<FxParameterSettingAPI_v5> setAPI,
                          CMTime actionTime) {
    NSString *existing = KKReadCustomParamString(getAPI, paramID);
    NSMutableDictionary *state =
        (existing.length
             ? [NSJSONSerialization
                   JSONObjectWithData:
                       [existing dataUsingEncoding:NSUTF8StringEncoding]
                              options:0
                                error:nil]
             : nil)
            ?: @{};
    state = [state mutableCopy];
    [state addEntriesFromDictionary:values];
    NSString *json = [[NSString alloc]
        initWithData:[NSJSONSerialization dataWithJSONObject:state
                                                     options:0
                                                       error:nil]
            encoding:NSUTF8StringEncoding];
    KKWriteCustomParamString(setAPI, json, paramID);
  }];
}

- (void)patchMaintainTimingEnabled:(BOOL)enabled paramID:(UInt32)paramID {
  KKPerformUndoable(self.apiManager, self, nil, ^(
                        id<FxParameterRetrievalAPI_v6> getAPI,
                        id<FxParameterSettingAPI_v5> setAPI, CMTime actionTime) {
  NSString *existing = KKReadCustomParamString(getAPI, paramID);
  NSMutableDictionary *state =
      (existing.length
           ? [NSJSONSerialization
                 JSONObjectWithData:[existing
                                        dataUsingEncoding:NSUTF8StringEncoding]
                            options:0
                              error:nil]
           : nil)
          ?: @{};
  state = [state mutableCopy];
  state[@"maintainTiming"] = @(enabled);
  if (enabled) {
    // Anchor to the current source in-point + clip duration. FxTimingAPI
    // resolves here inside the action scope.
    id<FxTimingAPI_v4> timingAPI =
        [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
    CMTime srcStart = kCMTimeZero, clipDur = kCMTimeZero;
    [timingAPI startTimeOfInputToFilter:&srcStart];
    [timingAPI durationTimeForEffect:&clipDur];
    state[@"maintainAnchorSrcIn"] = @(CMTimeGetSeconds(srcStart));
    state[@"maintainAnchorDur"] = @(CMTimeGetSeconds(clipDur));
  }
  NSString *json = [[NSString alloc]
      initWithData:[NSJSONSerialization dataWithJSONObject:state
                                                   options:0
                                                     error:nil]
          encoding:NSUTF8StringEncoding];
  KKWriteCustomParamString(setAPI, json, paramID);
  });
}

// Seconds the source range must hold steady after a trim before the bake
// commits. This delays the destructive blob rewrite so a continuous clip-edge
// drag commits once on release instead of churning every frame.
static const double kKKMaintainTimingBakeSettleSecs = 0.3;

- (void)bakeMaintainTimingForCache:(KKRenderCache *)cache
                   timelineParamID:(UInt32)timelineParamID
                    uiStateParamID:(UInt32)uiStateParamID
                  hasDurationLocks:(BOOL)hasDurationLocks {
  if (cache.effectDurSec <= 0)
    return;
  double curSrcIn = cache.sourceInSec, curDur = cache.effectDurSec;
  BOOL maintainAll = cache.maintainTimingEnabled && cache.anchorDurSec > 0;
  if (!maintainAll && !hasDurationLocks)
    return;
  if (maintainAll && fabs(curSrcIn - cache.anchorSrcInSec) < 1.0e-4 &&
      fabs(curDur - cache.anchorDurSec) < 1.0e-4)
    return;
  // Only (re)arm the settle timer when the range actually moves. A steady value
  // (drag released / paused) schedules nothing new, so the last-armed timer
  // fires and commits exactly once.
  BOOL unchanged = fabs(curDur - cache.bakeLastSeenDurSec) < 1.0e-4;
  if (maintainAll)
    unchanged = unchanged &&
                fabs(curSrcIn - cache.bakeLastSeenSrcInSec) < 1.0e-4;
  if (unchanged)
    return;
  cache.bakeLastSeenSrcInSec = curSrcIn;
  cache.bakeLastSeenDurSec = curDur;
  cache.bakeGeneration += 1;
  NSInteger gen = cache.bakeGeneration;

  __weak typeof(self) weak = self;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW,
                    (int64_t)(kKKMaintainTimingBakeSettleSecs * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        __strong typeof(weak) strong = weak;
        // Superseded by a later change → that change owns the commit.
        if (!strong || gen != cache.bakeGeneration)
          return;
        [strong _commitMaintainTimingBakeWithTimelineParamID:timelineParamID
                                              uiStateParamID:uiStateParamID];
      });
}

- (KKTimelineInspectorView *)maintainTimingInspectorView {
  return self.inspectorView;
}

- (void)_commitMaintainTimingBakeWithTimelineParamID:(UInt32)timelineParamID
                                      uiStateParamID:(UInt32)uiStateParamID {
  __block KKTimeline *retimedOut = nil;
  BOOL scoped = KKPerformUndoable(self.apiManager, self, nil, ^(
                    id<FxParameterRetrievalAPI_v6> getAPI,
                    id<FxParameterSettingAPI_v5> setAPI, CMTime actionTime) {
  // Re-read the CURRENT source range fresh from FxTimingAPI here, not a value
  // captured off a render tick: trims surface on render ticks that FCP can
  // coalesce, so a captured value may lag the real clip (the cause of the
  // "graph sometimes lands wrong / doesn't update" inconsistency).
  id<FxTimingAPI_v4> timingAPI =
      [self.apiManager apiForProtocol:@protocol(FxTimingAPI_v4)];
  CMTime srcStart = kCMTimeZero, clipDur = kCMTimeZero, frameDur = kCMTimeZero;
  [timingAPI startTimeOfInputToFilter:&srcStart];
  [timingAPI durationTimeForEffect:&clipDur];
  [timingAPI frameDuration:&frameDur];
  double curSrcIn = CMTimeGetSeconds(srcStart);
  double curDur = CMTimeGetSeconds(clipDur);
  double frameDurSec = CMTimeGetSeconds(frameDur);
  // Snap a keypose within half a frame of an edge (e.g. a split AT a keypose)
  // to the edge instead of duplicating it.
  double edgeEps = curDur > 0 ? 0.5 * frameDurSec / curDur : 0.0;

  // Read the anchor the BLOB is currently framed in from the UI-state (not a
  // captured cache value), so back-to-back trims compose correctly: each bake
  // maps the blob from its actual current frame to the new range.
  NSString *uiJSON = KKReadCustomParamString(getAPI, uiStateParamID);
  NSMutableDictionary *st =
      (uiJSON.length
           ? [[NSJSONSerialization
                 JSONObjectWithData:[uiJSON
                                        dataUsingEncoding:NSUTF8StringEncoding]
                            options:0
                              error:nil] mutableCopy]
           : nil)
          ?: [NSMutableDictionary dictionary];
  double fromSrcIn = [st[@"maintainAnchorSrcIn"] doubleValue];
  double fromDur = [st[@"maintainAnchorDur"] doubleValue];
  BOOL maintainAll = [st[@"maintainTiming"] boolValue] && fromDur > 0.0;
  KKTimeline *retimed = nil;
  BOOL rangeChanged = fabs(curSrcIn - fromSrcIn) > 1.0e-4 ||
                      fabs(curDur - fromDur) > 1.0e-4;
  if (curDur > 0 && ((maintainAll && rangeChanged) || !maintainAll)) {
    retimed = [self _retimeMaintainTimingBlobWithParamID:timelineParamID
                                                  getAPI:getAPI
                                                  setAPI:setAPI
                                               fromSrcIn:fromSrcIn
                                                 fromDur:fromDur
                                                 toSrcIn:curSrcIn
                                                   toDur:curDur
                                                 edgeEps:edgeEps
                                       durationLocksOnly:!maintainAll];
    if (maintainAll) {
      st[@"maintainAnchorSrcIn"] = @(curSrcIn);
      st[@"maintainAnchorDur"] = @(curDur);
      NSString *stJSON = [[NSString alloc]
          initWithData:[NSJSONSerialization dataWithJSONObject:st
                                                       options:0
                                                         error:nil]
              encoding:NSUTF8StringEncoding];
      KKWriteCustomParamString(setAPI, stJSON, uiStateParamID);
    }
  }
  retimedOut = retimed;
  });
  if (!scoped)
    return;
  KKTimeline *retimed = retimedOut;

  // Push straight to the graph so it refreshes even if the parameterChanged
  // round-trip from this self-write is dropped (the inconsistency symptom). A
  // per-layer plugin returns nil and refreshes its own multi-layer graph.
  if (retimed)
    [[self maintainTimingInspectorView] applyTimeline:retimed];
}

// Default: retime the single kKKParamTimelineData KKTimeline blob. Per-layer
// plugins (Canvas) override this to retime every layer's animationJSON.
- (KKTimeline *)
    _retimeMaintainTimingBlobWithParamID:(UInt32)timelineParamID
                                  getAPI:(id<FxParameterRetrievalAPI_v6>)getAPI
                                  setAPI:(id<FxParameterSettingAPI_v5>)setAPI
                               fromSrcIn:(double)fromSrcIn
                                 fromDur:(double)fromDur
                                 toSrcIn:(double)toSrcIn
                                   toDur:(double)toDur
                                 edgeEps:(double)edgeEps
                       durationLocksOnly:(BOOL)durationLocksOnly {
  NSString *tlJSON = KKReadCustomParamString(getAPI, timelineParamID);
  KKTimeline *tl = tlJSON.length ? [KKTimeline timelineFromJSON:tlJSON] : nil;
  if (!tl)
    return nil;
  KKTimeline *retimed = nil;
  if (durationLocksOnly) {
    double storedDuration = 0.0;
    BOOL hasLocks = NO;
    for (KKLane *lane in tl.lanes)
      if (KKLaneHasDurationLocks(lane)) {
        hasLocks = YES;
        if (lane.lastKnownClipDuration > 0.0)
          storedDuration = lane.lastKnownClipDuration;
      }
    if (!hasLocks || storedDuration <= 0.0 ||
        fabs(storedDuration - toDur) < 1.0e-4)
      return nil;
    retimed = KKTimelineRebalanced(tl, storedDuration, toDur);
  } else {
    retimed = KKTimelineRetimedForMaintainTiming(
        tl, fromSrcIn, fromDur, toSrcIn, toDur,
        ^NSArray<NSNumber *> *(KKLane *lane, double frac) {
          return KKLaneDisplayValueAtFraction(lane, frac);
        },
        edgeEps);
  }
  NSString *outJSON = [KKTimeline jsonFromTimeline:retimed];
  if (outJSON)
    KKWriteCustomParamString(setAPI, outJSON, timelineParamID);
  return retimed;
}

- (NSArray<KKHelpSection *> *)helpSections {
  return @[];
}

- (nullable NSString *)helpHeaderTitle {
  return nil;
}

- (nullable NSImage *)helpHeaderIcon {
  return nil;
}

- (KKHelpSection *)helpSectionFromKnowledgeTopic:(NSString *)topicID
                                           title:(NSString *)title
                                          symbol:(NSString *)symbol
                                       localizer:(NSString * (^)(NSString *))
                                                     localizer {
  // self is the plugin subclass, so bundleForClass resolves to the plugin's
  // own bundle where its AIKnowledge docs live (kept in an AIKnowledge
  // subdirectory, unlike the kit framework which flattens).
  NSArray<NSString *> *tips = [KKHelpSection
      tipMarkupFromKnowledgeTopic:topicID
                         inBundle:[NSBundle bundleForClass:[self class]]
                     subdirectory:@"AIKnowledge"
                        localizer:localizer];
  KKHelpSection *s = [KKHelpSection sectionWithTitle:title
                                           tipMarkup:tips
                                           shortcuts:nil];
  if (symbol.length > 0)
    s.icon = [NSImage imageWithSystemSymbolName:symbol
                       accessibilityDescription:nil];
  return s;
}

- (NSArray<KKHelpGuide *> *)helpGuides {
  return @[];
}

- (nullable NSNotificationName)helpGuideRefreshNotificationName {
  return nil;
}

- (nullable NSView *)aiAccessoryView {
  return nil;
}

- (nullable NSView *)licenseAccessoryView {
  return nil;
}

- (KKClipWrappingMode)clipWrappingMode {
  return KKClipWrappingModeNone;
}

+ (nullable NSString *)_clipWrappingTipForMode:(KKClipWrappingMode)mode {
  switch (mode) {
  case KKClipWrappingModeAdjustmentOrCompound:
    return KKLoc(@"Apply on an Adjustment Clip <kbd>⌥ A</kbd> or a Compound "
                 @"Clip <kbd>⌥ G</kbd> to avoid unexpected behavior and "
                 @"clipping.",
                 @"Help tip: wrap the clip.");
  case KKClipWrappingModeCompound:
    return KKLoc(@"Wrap your clip in a Compound Clip <kbd>⌥ G</kbd> before "
                 @"applying to avoid the animation being clipped at the edges.",
                 @"Help tip: wrap the clip.");
  case KKClipWrappingModeNone:
    return nil;
  }
}

+ (void)_prependClipWrappingTip:(NSString *)tipMarkup
                      toSection:(KKHelpSection *)section {
  NSAttributedString *wrap = [KKMarkup attributedStringFromMarkup:tipMarkup];
  NSMutableArray<NSAttributedString *> *tips = [NSMutableArray array];
  [tips addObject:wrap];
  [tips addObjectsFromArray:section.tips];
  section.tips = tips;
}

+ (KKHelpSection *)_knowledgeSectionWithTitle:(NSString *)title
                                        topic:(NSString *)topicID
                                       symbol:(NSString *)symbol {
  // Prose is single-sourced from the shared knowledge markdown the AI reads,
  // localized at display time. See KKHelpSection+Markdown.
  KKHelpSection *s = [KKHelpSection
      sectionWithTitle:title
             tipMarkup:[KKHelpSection
                           localizedTipMarkupFromKnowledgeTopic:topicID]
             shortcuts:nil];
  s.icon = [NSImage imageWithSystemSymbolName:symbol
                     accessibilityDescription:nil];
  return s;
}

+ (NSArray<KKHelpShortcut *> *)sharedOnScreenControlShortcuts {
  return @[
    [KKHelpShortcut
        shortcutWithKeysMarkup:KKLoc(@"<kbd>⌥</kbd> + click a control",
                                     @"Shortcut keys.")
                    descMarkup:KKLoc(@"Hide that on-screen control",
                                     @"Help shortcut.")],
    [KKHelpShortcut
        shortcutWithKeysMarkup:KKLoc(@"<kbd>⌥</kbd> hold", @"Shortcut keys.")
                    descMarkup:KKLoc(@"Reveal hidden controls as ghosts to "
                                     @"interact with - also when On-Screen "
                                     @"Controls is switched off",
                                     @"Help shortcut.")],
    [KKHelpShortcut
        shortcutWithKeysMarkup:KKLoc(@"Double-click the mini-viewer",
                                     @"Shortcut keys.")
                    descMarkup:KKLoc(@"Reset its zoom and pan",
                                     @"Help shortcut.")],
    [KKHelpShortcut shortcutWithKeysMarkup:@"<kbd>⌘ 0</kbd>"
                                descMarkup:KKLoc(@"Reset the mini-viewer zoom",
                                                 @"Help shortcut.")],
    [KKHelpShortcut
        shortcutWithKeysMarkup:KKLoc(@"Scroll / pinch", @"Shortcut keys.")
                    descMarkup:KKLoc(@"Zoom the mini-viewer (two-finger drag "
                                     @"pans)",
                                     @"Help shortcut.")],
  ];
}

+ (KKHelpSection *)_builtInTimingShortcutsSection {
  // A skimmable 2-column table, curated to match shortcuts.md (the AI doc).
  KKHelpSection *s = [KKHelpSection
      sectionWithTitle:KKLoc(@"Timing shortcuts", @"Help section title.")
             tipMarkup:nil
             shortcuts:@[
               [KKHelpShortcut
                   shortcutWithKeysMarkup:KKLoc(@"Click", @"Shortcut keys.")
                               descMarkup:KKLoc(@"Select a keypose or interval "
                                                @"and open its editor",
                                                @"Help shortcut.")],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:KKLoc(@"<kbd>⇧</kbd> + click",
                                                @"Shortcut keys.")
                               descMarkup:KKLoc(@"Add to or remove from the "
                                                @"selection",
                                                @"Help shortcut.")],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:KKLoc(
                                              @"<kbd>⌥</kbd> + click a keypose",
                                              @"Shortcut keys.")
                               descMarkup:KKLoc(@"Delete it",
                                                @"Help shortcut.")],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:KKLoc(
                                              @"<kbd>⌥</kbd> + drag a keypose",
                                              @"Shortcut keys.")
                               descMarkup:KKLoc(@"Duplicate it",
                                                @"Help shortcut.")],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:KKLoc(@"Drag", @"Shortcut keys.")
                               descMarkup:KKLoc(@"Move a keypose (snaps to "
                                                @"nearby ones)",
                                                @"Help shortcut.")],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:KKLoc(
                                              @"<kbd>⌘</kbd> + click an empty "
                                              @"lane",
                                              @"Shortcut keys.")
                               descMarkup:KKLoc(@"Add a keypose there",
                                                @"Help shortcut.")],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:KKLoc(@"Right-click an interval",
                                                @"Shortcut keys.")
                               descMarkup:KKLoc(@"Link or unlink its endpoints "
                                                @"(hold vs animate)",
                                                @"Help shortcut.")],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:KKLoc(@"Drag empty space",
                                                @"Shortcut keys.")
                               descMarkup:KKLoc(@"Marquee-select keyposes",
                                                @"Help shortcut.")],
               [KKHelpShortcut shortcutWithKeysMarkup:KKLoc(@"<kbd>Space</kbd>",
                                                            @"Shortcut keys.")
                                           descMarkup:KKLoc(@"Play or pause",
                                                            @"Help shortcut.")],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:KKLoc(@"<kbd>⌘ ⌥</kbd> + click",
                                                @"Shortcut keys.")
                               descMarkup:KKLoc(@"Move the playhead there to "
                                                @"preview",
                                                @"Help shortcut.")],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>⌘ Z</kbd> / <kbd>⌘ ⇧ Z</kbd>"
                               descMarkup:KKLoc(
                                              @"Undo / redo, including inside "
                                              @"popovers",
                                              @"Help shortcut.")],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:KKLoc(
                                              @"<kbd>⌥</kbd> + click a filter "
                                              @"row",
                                              @"Shortcut keys.")
                               descMarkup:KKLoc(@"Solo that property",
                                                @"Help shortcut.")],
             ]];
  s.icon = [NSImage imageWithSystemSymbolName:@"keyboard"
                     accessibilityDescription:nil];
  return s;
}

+ (NSArray<KKHelpSection *> *)_builtInTimingHelpSections {
  // Concept prose is single-sourced from the AI markdown; the shortcuts are a
  // skimmable table (above).
  return @[
    [self _knowledgeSectionWithTitle:KKLoc(@"How animation works",
                                           @"Help section title.")
                               topic:@"timeline-basics"
                              symbol:@"point.3.connected.trianglepath.dotted"],
    [self _knowledgeSectionWithTitle:KKLoc(@"Basic vs Advanced",
                                           @"Help section title.")
                               topic:@"basic-vs-advanced"
                              symbol:@"switch.2"],
    [self _knowledgeSectionWithTitle:KKLoc(@"Easing curves",
                                           @"Help section title.")
                               topic:@"easing"
                              symbol:@"point.topleft.down.curvedto."
                                     @"point.bottomright.up"],
    [self
        _knowledgeSectionWithTitle:KKLoc(@"Expressions", @"Help section title.")
                             topic:@"expressions"
                            symbol:@"function"],
    [self _knowledgeSectionWithTitle:KKLoc(@"Presets", @"Help section title.")
                               topic:@"presets"
                              symbol:@"bookmark"],
    [self _knowledgeSectionWithTitle:KKLoc(@"Filtering lanes",
                                           @"Help section title.")
                               topic:@"lane-filter"
                              symbol:@"line.3.horizontal.decrease.circle"],
    [self _builtInTimingShortcutsSection],
  ];
}

+ (KKHelpSection *)_builtInMotionBlurHelpSection {
  // Single-sourced from the shared knowledge doc the AI assistant also reads
  // (motion-blur.md in the kit bundle), so the help window and the AI never
  // disagree on the controls. Localized at display time via KKLocalizable.
  NSArray<NSString *> *tips =
      [KKHelpSection localizedTipMarkupFromKnowledgeTopic:@"motion-blur"];

  KKHelpSection *mb =
      [KKHelpSection sectionWithTitle:KKLoc(@"Motion Blur",
                                            @"Help section title: motion blur.")
                            tipMarkup:tips
                            shortcuts:nil];
  mb.icon = [NSImage imageWithSystemSymbolName:@"figure.walk.motion"
                      accessibilityDescription:nil];
  return mb;
}

// One-shot: after the help window is dismissed to run a guide, re-open it when
// that guide ends (completion OR skip - KKJoyrideRunDidEndNotification fires
// for both). Self-removing so it never re-opens on a later, unrelated guide
// run.
- (void)_reopenHelpWhenGuideEnds {
  __weak typeof(self) weakSelf = self;
  __block id obs = [NSNotificationCenter.defaultCenter
      addObserverForName:KKJoyrideRunDidEndNotification
                  object:nil
                   queue:NSOperationQueue.mainQueue
              usingBlock:^(NSNotification *_Nonnull note) {
                if (obs) {
                  [NSNotificationCenter.defaultCenter removeObserver:obs];
                  obs = nil;
                }
                __strong typeof(self) s = weakSelf;
                if (s)
                  [s openHelpRemoteWindow];
              }];
}

- (void)openHelpRemoteWindow {
  NSMutableArray<KKHelpSection *> *sections =
      [[self helpSections] mutableCopy] ?: [NSMutableArray array];
  NSString *wrapTip =
      [KKPlugin _clipWrappingTipForMode:[self clipWrappingMode]];
  if (wrapTip.length > 0 && sections.count > 0)
    [KKPlugin _prependClipWrappingTip:wrapTip toSection:sections.firstObject];

  // Show the shared Timing docs when this plugin drives the timeline. A
  // non-empty -helpGuides (its timing walkthroughs) is the signal.
  BOOL hasTimeline = [self helpGuides].count > 0;
  if (hasTimeline)
    [sections addObjectsFromArray:[KKPlugin _builtInTimingHelpSections]];
  if ([self usesMotionBlur])
    [sections addObject:[KKPlugin _builtInMotionBlurHelpSection]];

  NSArray<KKHelpSection *> *finalSections = [sections copy];
  __weak typeof(self) weakSelf = self;
  [self
      presentRemoteWindowOfSize:CGSizeMake(500.0, 420.0)
                contentProvider:^NSView * {
                  __strong typeof(weakSelf) s = weakSelf;
                  if (!s)
                    return nil;
                  KKHelpView *helpView =
                      [[KKHelpView alloc] initWithSections:finalSections
                                                    guides:[s helpGuides]
                                               headerTitle:[s helpHeaderTitle]
                                                headerIcon:[s helpHeaderIcon]];
                  NSNotificationName refreshName =
                      [s helpGuideRefreshNotificationName];
                  if (refreshName)
                    [helpView observeGuideRefreshNotificationNamed:refreshName];
                  // Launching a guide from the help window: close the window so
                  // it doesn't cover the guide, and re-open it when the guide
                  // ends (completion OR skip).
                  helpView.onGuideLaunch = ^{
                    __strong typeof(self) s2 = weakSelf;
                    if (!s2)
                      return;
                    [s2 _reopenHelpWhenGuideEnds];
                    [s2 closeRemoteWindowIfSupported];
                  };
                  return helpView;
                }];
}

@end
