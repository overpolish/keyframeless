/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// What one box of the chain CONTAINS, and what its controls do when clicked.
// The strip itself - the scrolling rail the boxes sit on, its edge fades and
// the slowness warning - is MirageShaderRackView.m; the reorder drag is
// MirageShaderRackView+DragDrop.m.

#import "MirageShaderRackView_Internal.h"

#import "MirageLocalized.h"

#import <KeyframelessKit/KKListRowViews.h>
#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>

@implementation MirageRackEntry
@end

// How strongly the selected box's accent fill reads, against the resting fill
// every other box carries. The strip sits under the mini viewer rather than on
// a panel of its own, so both are light - a full-strength band up there
// competes with the preview.
static const CGFloat kMirageRackSelectionAlpha = 0.28;
static const CGFloat kMirageRackRestingAlpha = 0.07;
// A bypassed shader is still in the chain and still selectable, so it fades
// rather than disappears - but only just. What carries "off" is the unchecked
// box and the dashed connector leaving it; the fade only has to say "not this
// one", and at 0.55 it was saying "unreadable" instead.
static const CGFloat kMirageRackDisabledAlpha = 0.8;
// The category glyph is a 12pt symbol on a near-transparent fill, where
// secondaryLabelColor is thin enough to lose the shape. A high-alpha
// labelColor keeps it legible without reading as loud as the name.
static const CGFloat kMirageRackGlyphAlpha = 0.85;

@implementation MirageShaderRackView (Boxes)

// The whole strip is rebuilt on every change, selection included: what a box
// CONTAINS depends on the chain length (a single-entry rack carries neither the
// on/off control nor the bin) and how it is TINTED depends on the selection and
// on which box preview is running from, so there is no styling-only path that
// would stay honest.
- (void)rebuildBoxes {
  for (NSView *v in _chain.arrangedSubviews.copy)
    [v removeFromSuperview];
  [_boxViews removeAllObjects];

  for (NSUInteger i = 0; i < _entries.count; i++) {
    MirageRackConnectorView *arrow = nil;
    if (i > 0) {
      arrow = [[MirageRackConnectorView alloc] initWithFrame:NSZeroRect];
      arrow.translatesAutoresizingMaskIntoConstraints = NO;
      arrow.image = [[NSImage imageWithSystemSymbolName:@"arrow.right"
                               accessibilityDescription:nil]
          imageWithSymbolConfiguration:_symConfig];
      arrow.dimmed = !_entries[i - 1].enabled;
      [_chain addArrangedSubview:arrow];
      // The connector occupies the same fixed slot the drop-line maths measures
      // its gap from, so the width stays the constant even though the glyph
      // inside it is narrower.
      [arrow.widthAnchor constraintEqualToConstant:kMirageRackConnectorWidth]
          .active = YES;
      [arrow.heightAnchor constraintEqualToConstant:kMirageRackBoxHeight]
          .active = YES;
    }
    MirageRackBox *box = [self _boxForEntry:_entries[i] index:(NSInteger)i];
    [_chain addArrangedSubview:box];
    [box.heightAnchor constraintEqualToConstant:kMirageRackBoxHeight].active =
        YES;
    // Tied to the BOX's centre rather than left to the strip's own middle: the
    // strip is taller than a box by its padding, and anything centred on the
    // band instead of on the boxes sits off the line the chain reads along.
    if (arrow)
      [arrow.centerYAnchor constraintEqualToAnchor:box.centerYAnchor].active =
          YES;
    [_boxViews addObject:box];
  }
  [_chain addArrangedSubview:_addButton];
  // Adding or removing a box changes what there is to scroll to without moving
  // the clip, so the fades would stay on the previous chain's answer until the
  // next scroll. Deferred so the document's width has settled.
  self.needsLayout = YES;
  __weak typeof(self) weak = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    [weak updateEdgeShadows];
  });
}

- (NSInteger)_selectedIndex {
  for (NSUInteger i = 0; i < _entries.count; i++)
    if ([_entries[i].entryID isEqualToString:_selectedEntryID ?: @""])
      return (NSInteger)i;
  return -1;
}

- (BOOL)isBoxSelected:(NSInteger)index {
  return index >= 0 && index == [self _selectedIndex];
}

// The box already selected can never be ineligible - a keypose popover opens
// ON the selected entry's keypose, so it has one there by construction. Said
// out loud anyway: a host that pushed a stale set would otherwise gray the very
// box the popover is editing.
- (BOOL)isBoxSelectable:(NSInteger)index {
  if (!_nonSelectableEntryIDs.count)
    return YES;
  if ([self isBoxSelected:index])
    return YES;
  MirageRackEntry *entry = [self _entryAtIndex:index];
  return entry && ![_nonSelectableEntryIDs containsObject:entry.entryID];
}

// The box reads left to right the way the signal flows through it: on/off,
// what kind of shader it is, its name, what to preview from it, and the way out
// of the chain.
- (MirageRackBox *)_boxForEntry:(MirageRackEntry *)entry
                          index:(NSInteger)index {
  BOOL selected = [self isBoxSelected:index];
  BOOL selectable = [self isBoxSelectable:index];
  MirageRackBox *box = [[MirageRackBox alloc] initWithFrame:NSZeroRect];
  box.owner = self;
  box.boxIndex = index;
  box.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  box.alignment = NSLayoutAttributeCenterY;
  box.distribution = NSStackViewDistributionFill;
  box.spacing = KKSpacingSM;
  box.edgeInsets = NSEdgeInsetsMake(0, KKPaddingMD, 0, KKPaddingMD);
  box.wantsLayer = YES;
  box.layer.cornerRadius = KKRadiusMD;
  box.layer.backgroundColor =
      (selected ? [[NSColor accentMatchingHost]
                      colorWithAlphaComponent:kMirageRackSelectionAlpha]
                : [NSColor.labelColor
                      colorWithAlphaComponent:kMirageRackRestingAlpha])
          .CGColor;
  // An entry the open keypose popover can't edit fades exactly as a bypassed
  // one does, and for the same reason: it is still in the chain, it just isn't
  // available right now. Deliberately NOT a second, deeper fade - two shades of
  // "not this one" in a 28pt strip read as a rendering fault, and what
  // distinguishes the two states is already on the box (an unchecked box for
  // bypassed, a tooltip and a dead click for this).
  box.alphaValue =
      (entry.enabled && selectable) ? 1.0 : kMirageRackDisabledAlpha;
  if (!selectable)
    box.toolTip = _nonSelectableReason;

  // The on/off control only exists once there IS a chain. With one entry there
  // is nothing to switch out of the path - turning the only shader off is
  // turning the effect off, which Final Cut's own enable checkbox already does
  // - and offering it here would ALSO be the click that racks a project which
  // had never been racked.
  //
  // Checked, it takes the host accent the way every other on/off control in
  // the inspector does (KKTimelineInspectorButtons: accent when on, secondary
  // when off) - a grey tick read as another disabled glyph rather than as the
  // one control in the box that is currently saying yes.
  if (_entries.count > 1)
    [box addArrangedSubview:KKListIconButton(
                                entry.enabled ? @"checkmark.square.fill"
                                              : @"square",
                                _symConfig, self, @selector(_toggleEnabled:),
                                (NSUInteger)index,
                                entry.enabled ? [NSColor accentMatchingHost]
                                              : NSColor.secondaryLabelColor)];

  KKListGlyphView *glyph = [KKListGlyphView
      imageViewWithImage:[[NSImage imageWithSystemSymbolName:entry.symbolName
                                    accessibilityDescription:nil]
                             imageWithSymbolConfiguration:_symConfig]];
  glyph.translatesAutoresizingMaskIntoConstraints = NO;
  glyph.contentTintColor =
      [NSColor.labelColor colorWithAlphaComponent:kMirageRackGlyphAlpha];
  [glyph.widthAnchor constraintEqualToConstant:KKIconSizeSM].active = YES;
  [glyph.heightAnchor constraintEqualToConstant:KKIconSizeSM].active = YES;
  [box addArrangedSubview:glyph];

  KKListNameLabel *label =
      [KKListNameLabel labelWithString:entry.name.length ? entry.name : @""];
  label.font = [NSFont systemFontOfSize:KKFontSizeSM];
  // The name stays a name whether or not the shader is in the path - it is how
  // the box is identified and how it is dragged. Bypassed, it steps down one
  // level, not two: tertiary under the box's own fade was unreadable.
  label.textColor = (entry.enabled && selectable) ? NSColor.labelColor
                                                  : NSColor.secondaryLabelColor;
  label.alignment = NSTextAlignmentLeft;
  label.lineBreakMode = NSLineBreakByTruncatingTail;
  label.cell.lineBreakMode = NSLineBreakByTruncatingTail;
  [box addArrangedSubview:label];

  // The two preview questions, on EVERY box of a chain. Asking "show me up to
  // here" about a box is not the same as working on it, and gating them behind
  // the selection made comparing two links a four-click round trip (select,
  // look, select back, look). Wider boxes are the price; the inactive pair is
  // secondary ink so a four-box strip still reads as names, not as buttons.
  //
  // Both are pure preview: they change what the mini viewer above shows and
  // nothing else. Final Cut's own viewer keeps rendering the whole chain.
  if (_entries.count > 1) {
    [box addArrangedSubview:
             [self _previewButtonForEntry:entry
                                    index:index
                                     mode:MirageRackPreviewModeUpToHere]];
    [box addArrangedSubview:
             [self _previewButtonForEntry:entry
                                    index:index
                                     mode:MirageRackPreviewModeSolo]];
  }

  // Remove sits on EVERY box of a chain, gated the same way the on/off control
  // is: with one entry there is nothing removable. Gating it behind the
  // selection made it read as a close button for the box you were editing
  // rather than as a per-shader control, and a ViewBridge-hosted popover
  // doesn't deliver reliable mouse-entered tracking for a hover-reveal either.
  //
  // A bin rather than an x: an x on a box that is always there says "dismiss
  // this", which is the one thing it doesn't do. Resting ink is secondary, the
  // same as the inactive preview pair - it is always present, so it must never
  // pull ahead of the name.
  if (_entries.count > 1) {
    NSButton *remove =
        KKListIconButton(@"trash", _symConfig, self, @selector(_removeTapped:),
                         (NSUInteger)index, NSColor.secondaryLabelColor);
    remove.toolTip = RLoc(@"Remove Shader",
                          @"Mirage rack: tooltip on the button that deletes "
                          @"the selected shader from the chain.");
    [box addArrangedSubview:remove];
  }
  return box;
}

// The mode currently running ON this entry, `Off` for every other box. One mode
// at a time across the whole rack, so at most one box is ever tinted.
- (MirageRackPreviewMode)_previewModeForEntry:(MirageRackEntry *)entry {
  if (_previewMode == MirageRackPreviewModeOff ||
      ![_previewEntryID isEqualToString:entry.entryID ?: @""])
    return MirageRackPreviewModeOff;
  return _previewMode;
}

// One preview button. Accent when its own mode is the one running on this box,
// secondary otherwise - the same on/off ink the enable checkbox uses, so "this
// is what you are looking at" reads the same everywhere in the strip.
//
// `arrow.right.to.line` for up-to-here: the chain stops AT this box, which is
// what the glyph draws. `viewfinder` for solo: one thing framed on its own,
// with none of the audio-desk baggage a headphone glyph would import into a
// picture pipeline.
- (NSButton *)_previewButtonForEntry:(MirageRackEntry *)entry
                               index:(NSInteger)index
                                mode:(MirageRackPreviewMode)mode {
  BOOL upToHere = (mode == MirageRackPreviewModeUpToHere);
  BOOL active = ([self _previewModeForEntry:entry] == mode);
  NSButton *button = KKListIconButton(
      upToHere ? @"arrow.right.to.line" : @"viewfinder", _symConfig, self,
      upToHere ? @selector(_previewUpToHereTapped:)
               : @selector(_previewSoloTapped:),
      (NSUInteger)index,
      active ? [NSColor accentMatchingHost] : NSColor.secondaryLabelColor);
  button.toolTip =
      upToHere ? RLoc(@"Preview the chain up to here. Final Cut's viewer still "
                      @"shows the whole chain.",
                      @"Mirage rack: tooltip on the button that previews the "
                      @"shader chain truncated after this shader.")
               : RLoc(@"Preview this shader alone, on the original clip. Final "
                      @"Cut's viewer still shows the whole chain.",
                      @"Mirage rack: tooltip on the button that previews only "
                      @"this shader's own contribution.");
  return button;
}

- (void)_previewUpToHereTapped:(NSButton *)sender {
  MirageRackEntry *entry = [self _entryAtIndex:sender.tag];
  if (entry && self.onSetPreviewMode)
    self.onSetPreviewMode(entry.entryID, MirageRackPreviewModeUpToHere);
}

- (void)_previewSoloTapped:(NSButton *)sender {
  MirageRackEntry *entry = [self _entryAtIndex:sender.tag];
  if (entry && self.onSetPreviewMode)
    self.onSetPreviewMode(entry.entryID, MirageRackPreviewModeSolo);
}

- (MirageRackEntry *)_entryAtIndex:(NSInteger)index {
  if (index < 0 || (NSUInteger)index >= _entries.count)
    return nil;
  return _entries[(NSUInteger)index];
}

- (void)selectBoxAtIndex:(NSInteger)index {
  MirageRackEntry *entry = [self _entryAtIndex:index];
  if (!entry)
    return;
  // Inert while a keypose popover is open on a time this entry has no keypose
  // at. Swallowed HERE as well as in the host (which refuses the same move) so
  // the box never flashes selected on its way to being refused - the strip
  // repaints from its own `_selectedEntryID` before the host is even asked.
  if (![self isBoxSelectable:index])
    return;
  _selectedEntryID = [entry.entryID copy];
  [self rebuildBoxes];
  if (self.onSelectEntry)
    self.onSelectEntry(entry.entryID);
}

- (void)_toggleEnabled:(NSButton *)sender {
  MirageRackEntry *entry = [self _entryAtIndex:sender.tag];
  if (entry && self.onSetEntryEnabled)
    self.onSetEntryEnabled(entry.entryID, !entry.enabled);
}

- (void)addTapped:(NSButton *)sender {
  if (self.onAddTapped)
    self.onAddTapped(sender);
}

// A single-entry rack has nothing to remove into: the chain always renders
// something, so the last shader is the effect itself.
- (void)_removeTapped:(NSButton *)sender {
  MirageRackEntry *entry = [self _entryAtIndex:sender.tag];
  if (entry && _entries.count > 1 && self.onRemoveEntry)
    self.onRemoveEntry(entry.entryID);
}
@end
