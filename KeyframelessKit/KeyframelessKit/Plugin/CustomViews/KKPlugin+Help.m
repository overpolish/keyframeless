/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKDataBlob.h"
#import "KKHelpSection+Markdown.h"
#import "KKHelpSection.h"
#import "KKHelpView+Guides.h"
#import "KKHelpView.h"
#import "KKLocalized.h"
#import "KKLog.h"
#import "KKMarkup.h"
#import "KKPlugin_Private.h"
#import <FxPlug/FxPlugSDK.h>

#pragma clang diagnostic ignored "-Wobjc-protocol-method-implementation"

@implementation KKPlugin (Help)

- (void)patchUIStateKey:(NSString *)key
                  value:(id)value
                paramID:(UInt32)paramID {
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!actionAPI)
    return;
  [actionAPI startAction:self];
  id<FxParameterRetrievalAPI_v6> getAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
  id<FxParameterSettingAPI_v5> setAPI =
      [self.apiManager apiForProtocol:@protocol(FxParameterSettingAPI_v5)];
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
  state[key] = value;
  NSString *json = [[NSString alloc]
      initWithData:[NSJSONSerialization dataWithJSONObject:state
                                                   options:0
                                                     error:nil]
          encoding:NSUTF8StringEncoding];
  KKWriteCustomParamString(setAPI, json, paramID);
  [actionAPI endAction:self];
}

- (NSArray<KKHelpSection *> *)helpSections {
  return @[];
}

- (KKHelpSection *)helpSectionFromKnowledgeTopic:(NSString *)topicID
                                           title:(NSString *)title
                                          symbol:(NSString *)symbol
                                       localizer:
                                           (NSString * (^)(NSString *))localizer {
  // self is the plugin subclass, so bundleForClass resolves to the plugin's
  // own bundle where its AIKnowledge docs live (kept in an AIKnowledge
  // subdirectory, unlike the kit framework which flattens).
  NSArray<NSString *> *tips =
      [KKHelpSection tipMarkupFromKnowledgeTopic:topicID
                                        inBundle:[NSBundle bundleForClass:[self
                                                                              class]]
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
        shortcutWithKeysMarkup:KKLoc(@"Double-click the mini-canvas",
                                     @"Shortcut keys.")
                    descMarkup:KKLoc(@"Reset its zoom and pan",
                                     @"Help shortcut.")],
    [KKHelpShortcut
        shortcutWithKeysMarkup:@"<kbd>⌘ 0</kbd>"
                    descMarkup:KKLoc(@"Reset the mini-canvas zoom",
                                     @"Help shortcut.")],
    [KKHelpShortcut
        shortcutWithKeysMarkup:KKLoc(@"Scroll / pinch", @"Shortcut keys.")
                    descMarkup:KKLoc(@"Zoom the mini-canvas (two-finger drag "
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
                   shortcutWithKeysMarkup:KKLoc(@"<kbd>⌥</kbd> + click a keypose",
                                               @"Shortcut keys.")
                               descMarkup:KKLoc(@"Delete it", @"Help shortcut.")],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:KKLoc(@"<kbd>⌥</kbd> + drag a keypose",
                                               @"Shortcut keys.")
                               descMarkup:KKLoc(@"Duplicate it",
                                                @"Help shortcut.")],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:KKLoc(@"Drag", @"Shortcut keys.")
                               descMarkup:KKLoc(@"Move a keypose (snaps to "
                                                @"nearby ones)",
                                                @"Help shortcut.")],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:KKLoc(@"<kbd>⌘</kbd> + click an empty "
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
               [KKHelpShortcut
                   shortcutWithKeysMarkup:KKLoc(@"<kbd>Space</kbd>",
                                               @"Shortcut keys.")
                               descMarkup:KKLoc(@"Play or pause",
                                                @"Help shortcut.")],
               [KKHelpShortcut
                   shortcutWithKeysMarkup:@"<kbd>⌘ Z</kbd> / <kbd>⌘ ⇧ Z</kbd>"
                               descMarkup:KKLoc(@"Undo / redo, including inside "
                                                @"popovers",
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
    [self _builtInTimingShortcutsSection],
  ];
}

+ (KKHelpSection *)_builtInMotionBlurHelpSection {
  // Single-sourced from the shared knowledge doc the AI assistant also reads
  // (motion-blur.md in the kit bundle), so the help window and the AI never
  // disagree on the controls. Localized at display time via KKLocalizable.
  NSArray<NSString *> *tips =
      [KKHelpSection localizedTipMarkupFromKnowledgeTopic:@"motion-blur"];

  KKHelpSection *mb = [KKHelpSection
      sectionWithTitle:KKLoc(@"Motion Blur", @"Help section title: motion blur.")
             tipMarkup:tips
             shortcuts:nil];
  mb.icon = [NSImage imageWithSystemSymbolName:@"figure.walk.motion"
                      accessibilityDescription:nil];
  return mb;
}

- (void)openHelpRemoteWindow {
  NSMutableArray<KKHelpSection *> *sections =
      [[self helpSections] mutableCopy] ?: [NSMutableArray array];
  NSString *wrapTip =
      [KKPlugin _clipWrappingTipForMode:[self clipWrappingMode]];
  if (wrapTip.length > 0 && sections.count > 0)
    [KKPlugin _prependClipWrappingTip:wrapTip toSection:sections.firstObject];

  // Show the shared Timing docs when this plugin drives the timeline. Two
  // mechanisms exist: Canvas/Glow declare their lanes via -defaultLanesAtTime
  // (which needs currentTime + a resolved getAPI, hence a short action scope),
  // while MagicMove/Rounded declare theirs through the shared inspector config
  // and never override -defaultLanesAtTime - so a non-empty -helpGuides (their
  // timing walkthroughs) counts as a timeline signal too.
  BOOL hasTimeline = NO;
  id<FxCustomParameterActionAPI_v4> actionAPI =
      [self.apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (actionAPI) {
    [actionAPI startAction:self];
    id<FxParameterRetrievalAPI_v6> getAPI =
        [self.apiManager apiForProtocol:@protocol(FxParameterRetrievalAPI_v6)];
    hasTimeline =
        [self defaultLanesAtTime:[actionAPI currentTime] paramGetAPI:getAPI]
            .count > 0;
    [actionAPI endAction:self];
  }
  if (!hasTimeline && [self helpGuides].count > 0)
    hasTimeline = YES;
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
                                                    guides:[s helpGuides]];
                  NSNotificationName refreshName =
                      [s helpGuideRefreshNotificationName];
                  if (refreshName)
                    [helpView observeGuideRefreshNotificationNamed:refreshName];
                  return helpView;
                }];
}

@end
