/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// The inline parameter-link expression editor: building the editor row, the
// reference-insert menu (display<->stored token translation), expand/collapse,
// the live result strip + its refresh timer, and keeping the cached lane's
// expression in sync. Split out of KKTimelineStaticValuesPopover.m; reaches
// popover state via the @package ivars in
// KKTimelineStaticValuesPopover_Private.h.

#import "KKCodeEditorView.h"
#import "KKGLSLSyntax.h" // KKExprCatalog
#import "KKLinkBus.h"
#import "KKLinkExpr.h"
#import "KKLocalized.h"
#import "KKLog.h"
#import "KKMiniViewerRenderer.h"
#import "KKMiniViewerView.h"
#import "KKTimelineStaticValuesPopover_Private.h"
#import "KKTimingEvaluation.h" // KKTimelineLaneValueAtFraction
#import "KKTimeline.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"
#import <QuartzCore/QuartzCore.h>

@interface _KKStaticValuesPopoverView (ExpressionPrivate)
- (NSView *)_makeExprEditorRowForLabel:(NSString *)label text:(NSString *)text;
- (void)_refreshLinkManifests;
- (NSArray<NSDictionary<NSString *, NSString *> *> *)
    _linkCompletionItemsForPartial:(NSString *)partial;
- (NSString *)_displayFromStored:(NSString *)stored;
- (NSString *)_storedFromDisplay:(NSString *)display;
- (void)_insertReferenceMenu:(NSButton *)sender;
- (NSAttributedString *)_exprCatalogTitleForEntry:
    (NSDictionary<NSString *, NSString *> *)e;
- (void)_insertReferenceChosen:(NSMenuItem *)item;
- (void)_removeReferenceSource:(NSMenuItem *)item;
- (void)_toggleExprExpand:(NSButton *)sender;
- (void)_updateExprResultForLane:(KKLane *)lane;
- (NSString *)_formatResultText:(NSArray<NSNumber *> *)values
                        forLane:(KKLane *)lane;
- (void)_ensureExprResultTimer;
@end

@implementation _KKStaticValuesPopoverView (Expression)

- (NSView *)_makeExprEditorRowForLabel:(NSString *)label text:(NSString *)text {
  BOOL expanded = [_exprExpandedLabels containsObject:label];
  KKCodeEditorView *ed = [[KKCodeEditorView alloc] initWithFrame:NSZeroRect];
  ed.syntax = KKCodeSyntaxExpression; // set before codeText for the first paint
  // The model stores UUID-keyed refs (`${uuid.param}`); the editor shows the
  // friendly `${Clip.Param}` form. Translate on the way in, and back on
  // persist.
  [self _refreshLinkManifests];
  ed.codeText = [self _displayFromStored:(text ?: @"")];
  _exprEditorByLabel[label] = ed;
  __weak typeof(self) weak = self;
  ed.onChange = ^(NSString *code) {
    __strong typeof(weak) s = weak;
    NSString *stored = [s _storedFromDisplay:code];
    // Refresh the popover's cached `_lanes` entry so the result-strip timer
    // re-evaluates the NEW expression. The keypose popover suppresses the
    // rebuild echo (the _boundaryRedriveSuppress window that fixes the cmd-Z
    // crash), so unlike constants it never gets a fresh `_lanes` from
    // updateUnoptedLanes - update it here, in place, without a row rebuild.
    [s _updateCachedLaneExpression:stored forLabel:label];
    if (s->_onSetLinkExpression)
      s->_onSetLinkExpression(label, stored);
  };
  // Autocomplete inside a `${...` token: typing `${` lists every discovered
  // source (Clip.Param / Clip.Layer.Param), filtered live as the user types,
  // so refs never need hand-typing. The manifest cache refreshes when a token
  // opens (empty partial), not on every keystroke.
  ed.linkCompletionProvider =
      ^NSArray<NSDictionary<NSString *, NSString *> *> *(NSString *partial) {
        __strong typeof(weak) s = weak;
        if (!s)
          return nil;
        if (partial.length == 0)
          [s _refreshLinkManifests];
        return [s _linkCompletionItemsForPartial:partial];
      };
  // Left override: the discovered-clip insert menu (drops a `${Clip.Param}`
  // token). Right override: the expand/collapse chevron. Both carry the label
  // on their identifier for the action, and are sized to the row's gutter
  // glyphs.
  NSButton *insertBtn = [NSButton
      buttonWithImage:[NSImage imageWithSystemSymbolName:@"plus.circle"
                                accessibilityDescription:nil]
               target:self
               action:@selector(_insertReferenceMenu:)];
  insertBtn.bordered = NO;
  insertBtn.identifier = label;
  insertBtn.toolTip = KKLoc(
      @"Insert a clip reference, function or variable",
      @"Expression editor: insert-reference / function-reference button.");
  insertBtn.contentTintColor =
      [[NSColor accentMatchingHost] colorWithAlphaComponent:0.9];
  insertBtn.imageScaling = NSImageScaleProportionallyDown;
  insertBtn.translatesAutoresizingMaskIntoConstraints = NO;
  [insertBtn.widthAnchor constraintEqualToConstant:15.0].active = YES;
  [insertBtn.heightAnchor constraintEqualToConstant:15.0].active = YES;

  NSButton *chevron = [NSButton
      buttonWithImage:[NSImage
                          imageWithSystemSymbolName:(expanded ? @"chevron.up"
                                                              : @"chevron.down")
                           accessibilityDescription:nil]
               target:self
               action:@selector(_toggleExprExpand:)];
  chevron.bordered = NO;
  chevron.identifier = label;
  chevron.contentTintColor =
      [[NSColor inspectorLabel] colorWithAlphaComponent:0.55];
  chevron.imageScaling = NSImageScaleProportionallyDown;
  chevron.translatesAutoresizingMaskIntoConstraints = NO;
  [chevron.widthAnchor constraintEqualToConstant:15.0].active = YES;
  [chevron.heightAnchor constraintEqualToConstant:15.0].active = YES;

  _KKStaticValueRow *row = [[_KKStaticValueRow alloc]
      initEditorRowWithContentView:ed
                          leftView:insertBtn
                         rightView:chevron
                        firstLineH:kKKExprEditorTextH
                            height:(expanded ? kKKExprEditorExpandedH
                                             : kKKExprEditorRowH)];
  return row;
}

// Reload the discovered link sources into the per-popover cache used by the
// display<->stored token transforms and the insert menu. Cheap directory read;
// called on editor install and each menu open, not on the render/keystroke
// path.
- (void)_refreshLinkManifests {
  // Scope the picker to the editing clip's project (empty documentID = unknown,
  // which returns everything - the legacy library-wide behaviour).
  _linkManifests = [KKLinkBus manifestsForDocumentID:self.documentID];
}

// Flat candidate list for the `${` autocomplete: every referenceable param of
// every discovered source as a friendly "Clip.Param" / "Clip.Layer.Param" ref
// (the same form the insert menu drops; onChange translates it to the stored
// uuid form). Filtered case-insensitively against the typed partial anywhere
// in the full ref, so typing a clip, layer, or param fragment all narrow the
// list. The desc row carries the source's last-seen age - the honest tell
// between same-named twins.
- (NSArray<NSDictionary<NSString *, NSString *> *> *)
    _linkCompletionItemsForPartial:(NSString *)partial {
  static NSRelativeDateTimeFormatter *relFmt;
  static dispatch_once_t relOnce;
  dispatch_once(&relOnce, ^{
    relFmt = [[NSRelativeDateTimeFormatter alloc] init];
    relFmt.dateTimeStyle = NSRelativeDateTimeFormatterStyleNamed;
  });
  NSMutableArray<NSDictionary<NSString *, NSString *> *> *out =
      [NSMutableArray array];
  for (KKLinkManifest *man in _linkManifests) {
    NSString *seen = [NSString
        stringWithFormat:KKLoc(@"Last seen %@",
                               @"Expression insert menu: subtitle under a "
                               @"source clip; %@ is a relative time like '2 "
                               @"minutes ago' or 'now'."),
                         [relFmt localizedStringForDate:
                                     [NSDate dateWithTimeIntervalSinceNow:
                                                 -man.lastSeenAgeSec]
                                         relativeToDate:[NSDate date]]];
    void (^add)(NSString *, NSString *) = ^(NSString *name, NSString *full) {
      if (partial.length &&
          [full rangeOfString:partial options:NSCaseInsensitiveSearch]
                  .location == NSNotFound)
        return;
      [out addObject:@{
        @"name" : name,
        @"signature" : full,
        @"desc" : seen,
        @"insert" : [full stringByAppendingString:@"}"]
      }];
    };
    for (NSUInteger i = 0; i < man.paramLabels.count; i++) {
      NSString *disp = (i < man.paramDisplayNames.count)
                           ? man.paramDisplayNames[i]
                           : man.paramLabels[i];
      add(disp, [NSString stringWithFormat:@"%@.%@", man.displayName, disp]);
    }
    for (KKLinkLayerSource *layer in man.layers) {
      for (NSUInteger i = 0; i < layer.paramLabels.count; i++) {
        NSString *disp = (i < layer.paramDisplayNames.count)
                             ? layer.paramDisplayNames[i]
                             : layer.paramLabels[i];
        add(disp, [NSString stringWithFormat:@"%@.%@.%@", man.displayName,
                                             layer.displayName, disp]);
      }
    }
  }
  return out;
}

// Model (`${uuid.rawLabel}`) <-> editor (`${Clip.Param}`) ref translation. The
// logic (token walk + name/uuid resolution) lives in the kit so the plugin's AI
// write-back and this editor share ONE source of truth; here we just bind it to
// the cached manifests.
- (NSString *)_displayFromStored:(NSString *)stored {
  return KKLinkDisplayExpressionFromStored(stored, _linkManifests);
}

- (NSString *)_storedFromDisplay:(NSString *)display {
  return KKLinkStoredExpressionFromDisplay(display, _linkManifests);
}

// Build and pop the reference-insert menu for the editor whose gutter button
// was clicked: one submenu per discovered clip (its display name + timecode),
// each listing that clip's referenceable params. Choosing one drops a friendly
// `${Clip.Param}` token into that editor (persisted uuid-keyed via onChange).
- (void)_insertReferenceMenu:(NSButton *)sender {
  NSString *label = sender.identifier;
  if (label.length == 0)
    return;
  [self _refreshLinkManifests];
  NSMenu *menu = [[NSMenu alloc] init];
  if (_linkManifests.count == 0) {
    NSMenuItem *empty = [[NSMenuItem alloc]
        initWithTitle:KKLoc(@"No other clips found",
                            @"Expression insert menu: empty state.")
               action:NULL
        keyEquivalent:@""];
    empty.enabled = NO;
    [menu addItem:empty];
  }
  for (KKLinkManifest *man in _linkManifests) {
    NSMenuItem *clipItem = [[NSMenuItem alloc] initWithTitle:man.displayName
                                                      action:NULL
                                               keyEquivalent:@""];
    // "Last seen" subtext: a live clip heartbeats its manifest every ~10s, so
    // the file's age says how long ago the clip last rendered. FCP gives no
    // deletion signal, so this is the one honest tell for a deleted twin
    // ("Canvas @ 0:00" whose corpse still lingers on the bus) - shown as a
    // timestamp on every source rather than a warning color, since an idle
    // clip (playhead elsewhere) also ages and a color would cry wolf.
    static NSRelativeDateTimeFormatter *relFmt;
    static dispatch_once_t relOnce;
    dispatch_once(&relOnce, ^{
      relFmt = [[NSRelativeDateTimeFormatter alloc] init];
      relFmt.dateTimeStyle = NSRelativeDateTimeFormatterStyleNamed;
    });
    NSDate *seen = [NSDate dateWithTimeIntervalSinceNow:-man.lastSeenAgeSec];
    clipItem.subtitle = [NSString
        stringWithFormat:KKLoc(@"Last seen %@",
                               @"Expression insert menu: subtitle under a "
                               @"source clip; %@ is a relative time like '2 "
                               @"minutes ago' or 'now'."),
                         [relFmt localizedStringForDate:seen
                                         relativeToDate:[NSDate date]]];
    // Per-clip thumbnail (baked by the source's inspector, keyed by its uuid)
    // so two same-named clips ("Shader @ 0:02" x2) are told apart visually.
    // Absent thumbnail = text-only item, unchanged.
    NSString *thumbPath = [KKLinkBus thumbnailPathForUUID:man.uuid];
    if (thumbPath.length) {
      NSImage *thumb = [[NSImage alloc] initWithContentsOfFile:thumbPath];
      if (thumb) {
        CGFloat h = 24.0; // ~menu row height; keep the source's aspect
        CGFloat w = MAX(1.0, thumb.size.height > 0
                                 ? h * thumb.size.width / thumb.size.height
                                 : h);
        thumb.size = NSMakeSize(round(w), h);
        clipItem.image = thumb;
      }
    }
    NSMenu *sub = [[NSMenu alloc] init];
    // A layered source ("sub-clips": Canvas layers) nests one submenu per
    // layer - choosing Layer > Param inserts `${Clip.Layer.Param}` (stored
    // as `${uuid.layerID.label}` by the same onChange translation).
    for (KKLinkLayerSource *layer in man.layers) {
      NSMenuItem *layerItem = [[NSMenuItem alloc] initWithTitle:layer.displayName
                                                         action:NULL
                                                  keyEquivalent:@""];
      // Per-layer thumbnail (the source bakes each layer isolated over its
      // footage), same treatment as the clip-level image above.
      NSString *layerThumbPath = [KKLinkBus thumbnailPathForUUID:man.uuid
                                                         layerID:layer.layerID];
      if (layerThumbPath.length) {
        NSImage *layerThumb =
            [[NSImage alloc] initWithContentsOfFile:layerThumbPath];
        if (layerThumb) {
          CGFloat lh = 24.0;
          CGFloat lw =
              MAX(1.0, layerThumb.size.height > 0
                           ? lh * layerThumb.size.width / layerThumb.size.height
                           : lh);
          layerThumb.size = NSMakeSize(round(lw), lh);
          layerItem.image = layerThumb;
        }
      }
      NSMenu *layerSub = [[NSMenu alloc] init];
      for (NSUInteger i = 0; i < layer.paramLabels.count; i++) {
        NSString *paramDisplay = (i < layer.paramDisplayNames.count)
                                     ? layer.paramDisplayNames[i]
                                     : layer.paramLabels[i];
        NSMenuItem *pit =
            [[NSMenuItem alloc] initWithTitle:paramDisplay
                                       action:@selector(_insertReferenceChosen:)
                                keyEquivalent:@""];
        pit.target = self;
        pit.representedObject = @{
          @"label" : label,
          @"token" : [NSString stringWithFormat:@"${%@.%@.%@}",
                                                man.displayName,
                                                layer.displayName, paramDisplay]
        };
        [layerSub addItem:pit];
      }
      if (layer.paramLabels.count == 0) {
        NSMenuItem *none = [[NSMenuItem alloc]
            initWithTitle:KKLoc(@"No parameters",
                                @"Expression insert menu: a source with no "
                                @"referenceable params.")
                   action:NULL
            keyEquivalent:@""];
        none.enabled = NO;
        [layerSub addItem:none];
      }
      layerItem.submenu = layerSub;
      [sub addItem:layerItem];
    }
    if (man.layers.count && man.paramLabels.count)
      [sub addItem:[NSMenuItem separatorItem]];
    for (NSUInteger i = 0; i < man.paramLabels.count; i++) {
      NSString *paramDisplay = (i < man.paramDisplayNames.count)
                                   ? man.paramDisplayNames[i]
                                   : man.paramLabels[i];
      NSMenuItem *pit =
          [[NSMenuItem alloc] initWithTitle:paramDisplay
                                     action:@selector(_insertReferenceChosen:)
                              keyEquivalent:@""];
      pit.target = self;
      // Carry the editor label + the friendly token to insert (onChange maps it
      // back to the stable `${uuid.rawLabel}` for the model).
      pit.representedObject = @{
        @"label" : label,
        @"token" : [NSString
            stringWithFormat:@"${%@.%@}", man.displayName, paramDisplay]
      };
      [sub addItem:pit];
    }
    if (man.paramLabels.count == 0 && man.layers.count == 0) {
      NSMenuItem *none = [[NSMenuItem alloc]
          initWithTitle:KKLoc(@"No parameters",
                              @"Expression insert menu: a source with no "
                              @"referenceable params.")
                 action:NULL
          keyEquivalent:@""];
      none.enabled = NO;
      [sub addItem:none];
    }
    // Manual cleanup. Auto-reconcile drops a source only once its clip is gone
    // AND the project is reopened (FCP gives the plugin no in-session delete
    // signal). For the rare straggler still listed after an in-session delete,
    // let the user remove it by hand. Harmless if it is actually live - it
    // re-advertises on its next render.
    [sub addItem:[NSMenuItem separatorItem]];
    NSMenuItem *rm = [[NSMenuItem alloc]
        initWithTitle:KKLoc(@"Remove from list",
                            @"Expression insert menu: manually drop a stale "
                            @"source clip from the reference list.")
               action:@selector(_removeReferenceSource:)
        keyEquivalent:@""];
    rm.target = self;
    rm.representedObject = man.uuid;
    if (@available(macOS 11.0, *))
      rm.image = [NSImage imageWithSystemSymbolName:@"xmark.circle"
                           accessibilityDescription:nil];
    [sub addItem:rm];
    clipItem.submenu = sub;
    [menu addItem:clipItem];
  }

  // Functions & variables reference: the WHOLE expression vocabulary, grouped
  // by category, each showing its signature + a one-line description, click to
  // insert. This is the discoverability surface - nothing is hidden behind
  // "you had to know it existed" (e.g. pingpong).
  if (menu.numberOfItems > 0)
    [menu addItem:[NSMenuItem separatorItem]];
  NSMenuItem *fnHeader = [[NSMenuItem alloc]
      initWithTitle:KKLoc(@"Functions & variables",
                          @"Expression insert menu: reference section header.")
             action:NULL
      keyEquivalent:@""];
  fnHeader.enabled = NO;
  [menu addItem:fnHeader];
  for (NSString *categ in KKExprCatalogCategories()) {
    // categ stays English as the grouping key (matched against each entry's
    // "category"); localize only its shown title.
    NSMenuItem *catItem = [[NSMenuItem alloc]
        initWithTitle:KKLoc(categ, @"Expression insert menu: a category of "
                                   @"functions/variables (Variables/Math/...).")
               action:NULL
        keyEquivalent:@""];
    NSMenu *catSub = [[NSMenu alloc] init];
    for (NSDictionary<NSString *, NSString *> *e in KKExprCatalog()) {
      if (![e[@"category"] isEqualToString:categ])
        continue;
      NSMenuItem *it =
          [[NSMenuItem alloc] initWithTitle:e[@"signature"]
                                     action:@selector(_insertReferenceChosen:)
                              keyEquivalent:@""];
      it.target = self;
      it.attributedTitle = [self _exprCatalogTitleForEntry:e];
      it.toolTip = e[@"desc"];
      it.representedObject = @{@"label" : label, @"token" : e[@"insert"]};
      [catSub addItem:it];
    }
    catItem.submenu = catSub;
    [menu addItem:catItem];
  }

  // The menu window is host-proxied in the ViewBridge world, so a scroll
  // inside a long menu looks to the presenter's dismissal monitors like a
  // scroll "in FCP" and closed the whole popover mid-pick. Flag the tracking
  // span so those monitors veto dismissal (the colour-panel treatment;
  // popUpMenuPositioningItem blocks until the menu closes).
  _exprMenuOpen = YES;
  [menu popUpMenuPositioningItem:nil
                      atLocation:NSMakePoint(0, NSHeight(sender.bounds))
                          inView:sender];
  _exprMenuOpen = NO;
}

// A reference-menu item title: the signature in normal menu text followed by
// its description dimmed + smaller, so the whole vocabulary reads at a glance.
- (NSAttributedString *)_exprCatalogTitleForEntry:
    (NSDictionary<NSString *, NSString *> *)e {
  NSMutableAttributedString *s = [[NSMutableAttributedString alloc]
      initWithString:e[@"signature"]
          attributes:@{
            NSFontAttributeName : [NSFont menuFontOfSize:0],
            NSForegroundColorAttributeName : [NSColor labelColor]
          }];
  [s appendAttributedString:
          [[NSAttributedString alloc]
              initWithString:[@"    " stringByAppendingString:e[@"desc"]]
                  attributes:@{
                    NSFontAttributeName :
                        [NSFont menuFontOfSize:[NSFont smallSystemFontSize]],
                    NSForegroundColorAttributeName :
                        [NSColor secondaryLabelColor]
                  }]];
  return s;
}

- (void)_insertReferenceChosen:(NSMenuItem *)item {
  NSDictionary *info = item.representedObject;
  NSString *label = info[@"label"];
  NSString *token = info[@"token"];
  KKCodeEditorView *ed = _exprEditorByLabel[label];
  [ed insertReferenceText:token];
}

// Manually drop a source clip from the reference list (the "Remove from list"
// item in a source's submenu). Wipes its manifest / thumbnail / published
// curves; the next menu open rebuilds from what's left. Non-destructive for a
// live source - it re-advertises on its next render tick.
- (void)_removeReferenceSource:(NSMenuItem *)item {
  NSString *uuid = item.representedObject;
  if (uuid.length == 0)
    return;
  [KKLinkBus removeSourceForUUID:uuid];
  [self _refreshLinkManifests];
}

// Chevron on an expression-editor row: flip its label's expanded state, resize
// the editor row, swap the glyph, and re-fit the popover.
- (void)_toggleExprExpand:(NSButton *)sender {
  NSString *label = sender.identifier;
  if (label.length == 0)
    return;
  BOOL expanded = ![_exprExpandedLabels containsObject:label];
  if (expanded)
    [_exprExpandedLabels addObject:label];
  else
    [_exprExpandedLabels removeObject:label];
  _KKStaticValueRow *row = (_KKStaticValueRow *)_exprRowsByLabel[label];
  if ([row respondsToSelector:@selector(setEditorRowHeight:)])
    [row setEditorRowHeight:(expanded ? kKKExprEditorExpandedH
                                      : kKKExprEditorRowH)];
  sender.image = [NSImage
      imageWithSystemSymbolName:(expanded ? @"chevron.up" : @"chevron.down")
       accessibilityDescription:nil];
  [self _applyContentSize];
}

// Append an expression-editor row for `lane` to the end of the stack (used
// while building rows in order). No-op unless the lane carries an expression.
- (void)_installExprEditorForLane:(KKLane *)lane {
  if (!KKLaneHasExpressionEditor(lane))
    return;
  NSView *row = [self _makeExprEditorRowForLabel:lane.key
                                            text:lane.linkExpression];
  [_stack addArrangedSubview:row];
  [row.widthAnchor constraintEqualToAnchor:_stack.widthAnchor].active = YES;
  _exprRowsByLabel[lane.key] = row;
  [self _updateExprResultForLane:lane]; // seed the strip immediately
  [self _ensureExprResultTimer];
}

// Evaluate `lane`'s expression at the current preview time and push the result
// to its inline editor's strip. Time comes from the popover's mini-viewer
// renderer (clip fraction / project seconds / duration); with no mini-viewer it
// falls to t=0. `value` + `${refs}` resolve exactly as the render does, so the
// strip shows what actually renders. No-op for a lane without an editor /
// expression.
- (void)_updateExprResultForLane:(KKLane *)lane {
  KKCodeEditorView *ed = _exprEditorByLabel[lane.key];
  if (!ed)
    return;
  if (lane.linkExpression.length == 0) {
    ed.resultText = nil;
    return;
  }
  // Evaluate against the LIVE displayed value (seeded from the shown keypose,
  // updated on every field / OSC edit) so the strip re-runs immediately - the
  // keypose popover never rebuilds `_lanes` on a value edit, so the cached
  // lane's keypose would otherwise stay stale until the popover is reopened.
  KKLane *evalLane = lane;
  NSArray<NSNumber *> *live = _currentValuesByLabel[lane.key];
  if (live.count) {
    evalLane = [lane copy];
    evalLane.keyposes = @[ [KKKeyPose keyposeAtTime:0.0 values:live] ];
  }
  double frac = 0.0, tlSec = 0.0, dur = 0.0, start = 0.0;
  KKMiniViewerRenderer *r =
      [_miniViewer.canvasDelegate isKindOfClass:[KKMiniViewerRenderer class]]
          ? (KKMiniViewerRenderer *)_miniViewer.canvasDelegate
          : nil;
  if (r) {
    frac = r.editFraction;
    tlSec = r.linkTimelineSec;
    dur = r.clipDurationSeconds;
    start = r.clipTimelineStartSec;
  }

  // Where the dot sits (and where the readout is evaluated - they must agree):
  //  - constants mode: always the live playhead (linkTimelineSec back-solved to
  //  a
  //    clip fraction = clipProjectStartSec + playheadFraction*dur) - no keypose
  //    to anchor to, so it just tracks the scrub;
  //  - keypose mode: the playhead WHILE scrubbing/playing (so the dot + readout
  //    move with the live preview), pinging back to the keypose (editFraction)
  //    once the playhead settles.
  double playFrac = -1.0;
  if (dur > 0.0 && start >= 0.0 && tlSec >= 0.0)
    playFrac = MAX(0.0, MIN(1.0, (tlSec - start) / dur));
  double markerFrac;
  if (!_editsKeypose)
    markerFrac = playFrac;
  else if (_playheadMoving && playFrac >= 0.0)
    markerFrac = playFrac;
  else
    markerFrac = (frac >= 0.0 && frac <= 1.0) ? frac : -1.0;

  // Evaluate the readout AT the marker position so the number matches the dot:
  // t = clipStart + evalFrac*dur (= linkTimelineSec while moving; = the
  // keypose's own time once settled - not the stale scrub-release time).
  double evalFrac = (markerFrac >= 0.0) ? markerFrac : frac;
  double evalTl = (dur > 0.0 && start >= 0.0) ? start + evalFrac * dur : tlSec;
  // Resolve `${refs}` to a same-clip source's LIVE displayed value, not the
  // published bus curve - so the readout tracks a referenced lane in real time
  // as it is dragged, matching the mini-viewer preview, instead of only on
  // mouse-up. Reads the SAME live source the mini's -valuesForLabel: uses (the
  // renderer's live timeline, mirrored from every popover field / OSC edit via
  // -applyConstantValues:forLabel:), so the readout number is byte-identical to
  // what the mini renders. A cross-clip ref (no matching lane here) or an
  // expression-driven source falls through to the bus unchanged.
  KKTimeline *liveTl = r.timeline;
  NSString *selfUUID = r.linkSelfUUID;
  KKLinkRefOverride refOverride =
      liveTl ? ^NSArray<NSNumber *> *(NSString *refName) {
    // Identity-checked like the mini's -valuesForLabel: override: the uuid
    // must be THIS clip (when known) and a layered ref only resolves against
    // a lane whose layerKey matches - a cross-clip or other-layer ref with a
    // coinciding label reads the bus.
    NSArray<NSString *> *comps = [refName componentsSeparatedByString:@"."];
    NSString *layerID = comps.count == 3 ? comps[1] : nil;
    NSString *tail = comps.lastObject ?: refName;
    if (selfUUID.length && comps.count >= 2 &&
        ![comps.firstObject isEqualToString:selfUUID])
      return nil;
    for (KKLane *l in liveTl.lanes) {
      if (![l.key isEqualToString:tail])
        continue;
      if (layerID && ![l.layerKey isEqualToString:layerID])
        continue;
      // Display evaluation, matching the bus's committed-curve sampling.
      return l.linkExpression.length
                 ? nil
                 : KKLaneDisplayValueAtFraction(l, evalFrac);
    }
    return nil;
  }
             : nil;
             NSArray<NSNumber *> *res = KKLinkResolvedLaneValueWithOverride(
                 evalLane, evalFrac, evalTl, dur, refOverride);
             ed.resultText = [self _formatResultText:res forLane:evalLane];

             // Inline curve preview: sample the SAME expression across the
             // whole clip (fraction 0..1, t = clipStart + frac*dur), first
             // component only, so it reads identically in constants and keypose
             // modes regardless of the current playhead. A time-independent
             // expression comes out flat, which is the honest picture.
             static const NSInteger kSamples = 48;
             NSMutableArray<NSNumber *> *curve =
                 [NSMutableArray arrayWithCapacity:kSamples];
             for (NSInteger i = 0; i < kSamples; i++) {
               double f = (double)i / (double)(kSamples - 1);
               double t = dur > 0.0 ? start + f * dur : tlSec;
               NSArray<NSNumber *> *v = KKLinkResolvedLaneValueWithOverride(
                   evalLane, f, t, dur, refOverride);
               [curve addObject:v.firstObject ?: @0];
             }
             ed.sparklineSamples = curve;
             ed.sparklineMarker = markerFrac;
}

// "→ 135" (scalar) / "→ 105.2, 52.6" (multi-component). A media-scaled lane
// (Position / Crop / Anchor) shows its result in DISPLAY units - normalized
// 0..1 x media px, whole numbers - so the readout matches the lane's value
// fields (otherwise the result reads 0.5 while the field reads 960). The same
// per-component scale the value fields use (even index = width, odd = height;
// a "%" component stays literal); raw two-decimal otherwise.
- (NSString *)_formatResultText:(NSArray<NSNumber *> *)values
                        forLane:(KKLane *)lane {
  if (values.count == 0)
    return nil;
  CGSize media = _miniViewer.sourceMediaSize;
  BOOL scaled =
      lane.componentsScaleWithMedia && media.width > 0 && media.height > 0;
  NSArray<NSString *> *units = lane.componentUnits;
  NSMutableArray<NSString *> *parts =
      [NSMutableArray arrayWithCapacity:values.count];
  for (NSUInteger i = 0; i < values.count; i++) {
    double v = values[i].doubleValue;
    // Media-scale only a "px" (or units-absent legacy) component; "%" and an
    // explicit empty-string component stay literal - matches the value fields'
    // componentScale block so the readout agrees with the fields.
    NSString *u = i < units.count ? units[i] : nil;
    BOOL literal = [u isEqualToString:@"%"] || (u != nil && u.length == 0);
    if (scaled && !literal) {
      double px = v * ((i % 2 == 0) ? media.width : media.height);
      [parts addObject:[NSString stringWithFormat:@"%.0f", px]];
    } else {
      [parts addObject:[NSString
                           stringWithFormat:@"%g", round(v * 100.0) / 100.0]];
    }
  }
  return [@"→ " stringByAppendingString:[parts componentsJoinedByString:@", "]];
}

// Refresh every visible expression lane's result strip (timer tick).
- (void)_updateAllExprResults {
  // Detect playhead motion once per tick (scrub/playback advances
  // linkTimelineSec; it holds at rest) so the keypose sparkline dot follows the
  // playhead while moving and pings back to the keypose when settled - matching
  // the mini-viewer's live preview. Computed here, not per-lane, so every lane
  // sees the same verdict.
  double tl = -1.0;
  if ([_miniViewer.canvasDelegate isKindOfClass:[KKMiniViewerRenderer class]])
    tl = ((KKMiniViewerRenderer *)_miniViewer.canvasDelegate).linkTimelineSec;
  _playheadMoving = (tl >= 0.0 && fabs(tl - _lastMarkerLinkSec) > 1e-6);
  _lastMarkerLinkSec = tl;
  for (KKLane *lane in _lanes)
    if (_exprEditorByLabel[lane.key])
      [self _updateExprResultForLane:lane];
}

// Start the result-refresh timer (once) so time-based expressions stay live.
// Weak self (no retain cycle); torn down in -releaseMiniViewer / -dealloc.
- (void)_ensureExprResultTimer {
  if (_exprResultTimer)
    return;
  __weak typeof(self) weak = self;
  _exprResultTimer =
      [NSTimer scheduledTimerWithTimeInterval:0.2
                                      repeats:YES
                                        block:^(NSTimer *t) {
                                          __strong typeof(weak) s = weak;
                                          if (!s) {
                                            [t invalidate];
                                            return;
                                          }
                                          [s _updateAllExprResults];
                                        }];
}

// Bring the inline editor in/out of an ALREADY-BUILT stack to match the current
// expression state for `label`, inserting it directly under `valueRow`. Drives
// the grow-in-place on Add/Remove. Returns YES iff a row was added/removed
// (structural change); a live text edit (still non-empty) leaves the existing
// editor alone. `label` is always a referenceable lane here (the row only
// exposes the menu for those), so presence is just `expr.length`.
- (BOOL)_syncExprEditorForLabel:(NSString *)label
                     expression:(NSString *)expr
                       afterRow:(_KKStaticValueRow *)valueRow {
  // nil = no expression (remove the editor); an empty string is a present-but-
  // empty expression (keep the editor open), so key on nil, not length.
  BOOL should = (expr != nil);
  NSView *existing = _exprRowsByLabel[label];
  if (should && !existing) {
    NSView *row = [self _makeExprEditorRowForLabel:label text:expr];
    NSInteger idx = [_stack.arrangedSubviews indexOfObject:valueRow];
    if (idx == NSNotFound)
      [_stack addArrangedSubview:row];
    else
      [_stack insertArrangedSubview:row atIndex:idx + 1];
    [row.widthAnchor constraintEqualToAnchor:_stack.widthAnchor].active = YES;
    _exprRowsByLabel[label] = row;
    [self _ensureExprResultTimer]; // populate the result strip on the next tick
    return YES;
  }
  if (!should && existing) {
    [_stack removeArrangedSubview:existing];
    [existing removeFromSuperview];
    [_exprRowsByLabel removeObjectForKey:label];
    [_exprEditorByLabel removeObjectForKey:label];
    return YES;
  }
  return NO; // no structural change (text edit / already correct)
}

- (BOOL)_syncExprEditorForLane:(KKLane *)lane
                      afterRow:(_KKStaticValueRow *)valueRow {
  return [self _syncExprEditorForLabel:lane.key
                            expression:(KKLaneHasExpressionEditor(lane)
                                            ? lane.linkExpression
                                            : nil)afterRow:valueRow];
}

// Push the lane's current (stored) expression into its inline editor as an
// EXTERNAL change, so an undo/redo of a committed edit reaches the editor. Uses
// -applyExternalText: which is focus-safe (skips a live uncommitted typing
// burst so it never clobbers what the user is mid-typing) and clears the
// editor's local undo once applied. No-op when the lane has no editor.
//
// DEFERRED to the next runloop, and NO disk read here: this is called from
// inside the synchronous undo -> _refresh -> updateUnoptedLanes chain, often
// while the editor's text view is first responder mid-edit. Mutating it (and,
// worse, doing app-group disk I/O) re-entrantly from that chain crashed FCP on
// cmd-Z. The dispatch hops out of the chain; the stored->display mapping uses
// the cached manifests (a stale friendly name is harmless and refreshes on the
// next edit).
- (void)_resyncExprEditorTextForLane:(KKLane *)lane {
  NSString *label = lane.key;
  if (!_exprEditorByLabel[label])
    return;
  NSString *stored = lane.linkExpression ?: @"";
  __weak typeof(self) weak = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong typeof(weak) s = weak;
    KKCodeEditorView *ed = s ? s->_exprEditorByLabel[label] : nil;
    if (!ed)
      return;
    [ed applyExternalText:[s _displayFromStored:stored]];
  });
}

// Update the popover's cached `_lanes` entry for `label` so a subsequent resize
// (_applyContentSize -> _heightForLanes:_lanes) computes the new height. A copy
// is mutated (never the shared model lane). Needed for the keypose popover,
// which has no lanes-view reconcile to refresh _lanes on an expression toggle.
- (void)_updateCachedLaneExpression:(NSString *)expr
                           forLabel:(NSString *)label {
  NSMutableArray<KKLane *> *ml = [_lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)ml.count; i++)
    if ([ml[i].key isEqualToString:label]) {
      KKLane *c = [ml[i] copy];
      // An empty expression stays present (passthrough) so the inline editor
      // remains open after the user clears the text; only nil closes it.
      c.linkExpression = expr;
      ml[i] = c;
      _lanes = ml;
      return;
    }
}

@end
