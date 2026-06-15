/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Building and styling the layer rows: the row view (disclosure / glyph / eye /
// name / lock columns), the right-click context menu, and click selection.

#import "CanvasLayerListView_Private.h"

#import "CanvasLayerRowViews.h"
#import "CanvasLayerTree.h"
#import "CanvasLocalized.h"

#import <KeyframelessKit/KKBezierPath.h>
#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>

@implementation CanvasLayerListView (Rows)

#pragma mark - Rebuild / selection styling

- (void)_rebuildRows {
  for (NSView *v in _rowsStack.arrangedSubviews.copy)
    [v removeFromSuperview];
  [_rowViews removeAllObjects];

  [_paths enumerateObjectsUsingBlock:^(KKBezierPath *p, NSUInteger i, BOOL *s) {
    if ([self _isRowHiddenByCollapse:i])
      return; // inside a collapsed group
    NSView *row = [self _rowViewForPath:p
                                  index:i
                               selected:[_selection containsIndex:i]];
    [_rowsStack addArrangedSubview:row];
    [row.widthAnchor constraintEqualToAnchor:_rowsStack.widthAnchor].active =
        YES;
    [row.heightAnchor constraintEqualToConstant:kRowHeight].active = YES;
    [_rowViews addObject:row];
  }];

  _emptyStack.hidden = _paths.count > 0;
  [self _updateScrollShadows];
}

// Selection is pure UI state - just restyle the existing rows, no rebuild. Rows
// may be a subset of paths (collapse), so key off each row's own path index.
- (void)_applySelectionStyling {
  for (CanvasLayerRow *row in (NSArray<CanvasLayerRow *> *)_rowViews) {
    row.layer.backgroundColor =
        [_selection containsIndex:(NSUInteger)row.rowIndex]
            ? [[NSColor accent] colorWithAlphaComponent:kSelectionAlpha].CGColor
            : NSColor.clearColor.CGColor;
  }
}

#pragma mark - Row view (column builders)

// Fixed-width disclosure column so the eye column lines up across groups and
// leaf rows. Group rows get a chevron button; others get a matching spacer.
- (NSView *)_disclosureColumnForPath:(KKBezierPath *)path
                               index:(NSUInteger)idx {
  if (path.isGroup) {
    BOOL collapsed = [_collapsedGroups containsObject:path.groupID ?: @""];
    return CanvasLayerIconButton(collapsed ? @"chevron.right" : @"chevron.down",
                                 _symConfig, self, @selector(toggleCollapse:),
                                 idx, NSColor.secondaryLabelColor);
  }
  NSView *spacer =
      [[CanvasLayerPassthroughView alloc] initWithFrame:NSZeroRect];
  [spacer.widthAnchor constraintEqualToConstant:KKIconSizeSM].active = YES;
  [spacer.heightAnchor constraintEqualToConstant:KKIconSizeSM].active = YES;
  return spacer;
}

- (NSImage *)_symbolGlyph:(NSString *)symbol {
  NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration
      configurationWithPointSize:kLeadGlyphSize - 2
                          weight:NSFontWeightRegular];
  return [[NSImage imageWithSystemSymbolName:symbol
                    accessibilityDescription:nil]
      imageWithSymbolConfiguration:cfg];
}

// Fixed-size identity glyph: folder / image thumbnail / shape. A passthrough
// view so click-select and reorder-drag over it reach the row.
- (NSView *)_glyphColumnForPath:(KKBezierPath *)path {
  CanvasLayerGlyphView *glyph;
  if (path.isGroup) {
    glyph =
        [CanvasLayerGlyphView imageViewWithImage:[self _symbolGlyph:@"folder"]];
    glyph.contentTintColor = NSColor.secondaryLabelColor;
  } else if (path.isImage && path.imagePath.length) {
    NSImage *img = [self _thumbnailForPath:path.imagePath]
                       ?: [NSImage imageWithSystemSymbolName:@"photo.fill"
                                    accessibilityDescription:nil];
    glyph = [CanvasLayerGlyphView imageViewWithImage:img];
    glyph.imageScaling = NSImageScaleProportionallyUpOrDown;
  } else {
    glyph = [CanvasLayerGlyphView
        imageViewWithImage:[self _symbolGlyph:@"scribble"]];
    glyph.contentTintColor = NSColor.secondaryLabelColor;
  }
  [glyph.widthAnchor constraintEqualToConstant:kLeadGlyphSize].active = YES;
  [glyph.heightAnchor constraintEqualToConstant:kLeadGlyphSize].active = YES;
  return glyph;
}

// The name column is the inline rename field while editing this row, otherwise
// a passthrough label (a drag begun over it reaches the row; selection +
// double-click rename are handled by the row's mouse events).
- (NSView *)_nameColumnForPath:(KKBezierPath *)path index:(NSUInteger)idx {
  NSString *displayName = path.name.length ? path.name : @"Layer";
  if ((NSInteger)idx == _editingIndex) {
    NSTextField *field =
        [CanvasLayerRenameField textFieldWithString:displayName];
    field.font = [NSFont systemFontOfSize:KKFontSizeSM];
    // Match the value-edit fields (KKValueTextField): borderless, clear, no
    // focus ring, single-line, inspector label color - edits in place.
    field.textColor = [NSColor inspectorLabel];
    field.bordered = NO;
    field.bezeled = NO;
    field.drawsBackground = NO;
    field.backgroundColor = [NSColor clearColor];
    field.focusRingType = NSFocusRingTypeNone;
    field.usesSingleLineMode = YES;
    field.lineBreakMode = NSLineBreakByClipping;
    field.cell.wraps = NO;
    field.cell.scrollable = YES;
    field.alignment = NSTextAlignmentLeft;
    // Delegate is set AFTER focusing (in _beginRenameAtIndex:) so the spurious
    // begin/end during this enter-edit rebuild doesn't trigger a commit.
    field.tag = (NSInteger)idx;
    [field setContentHuggingPriority:1
                      forOrientation:NSLayoutConstraintOrientationHorizontal];
    _editingField = field;
    return field;
  }
  NSTextField *name = [CanvasLayerNameLabel labelWithString:displayName];
  name.alignment = NSTextAlignmentLeft;
  name.font = path.isGroup ? [NSFont boldSystemFontOfSize:KKFontSizeSM]
                           : [NSFont systemFontOfSize:KKFontSizeSM];
  name.textColor =
      path.hidden ? NSColor.tertiaryLabelColor : NSColor.labelColor;
  name.lineBreakMode = NSLineBreakByTruncatingTail;
  name.cell.lineBreakMode = NSLineBreakByTruncatingTail;
  [name setContentHuggingPriority:1
                   forOrientation:NSLayoutConstraintOrientationHorizontal];
  [name setContentCompressionResistancePriority:1
                                 forOrientation:
                                     NSLayoutConstraintOrientationHorizontal];
  return name;
}

- (NSView *)_rowViewForPath:(KKBezierPath *)path
                      index:(NSUInteger)idx
                   selected:(BOOL)selected {
  NSColor *eyeColor =
      path.hidden ? NSColor.tertiaryLabelColor : NSColor.secondaryLabelColor;
  NSColor *lockColor =
      path.locked ? NSColor.secondaryLabelColor : NSColor.tertiaryLabelColor;
  NSArray<NSView *> *views = @[
    [self _disclosureColumnForPath:path index:idx],
    [self _glyphColumnForPath:path],
    CanvasLayerIconButton(path.hidden ? @"eye.slash" : @"eye.fill", _symConfig,
                          self, @selector(toggleVisibility:), idx, eyeColor),
    [self _nameColumnForPath:path index:idx],
    CanvasLayerIconButton(path.locked ? @"lock.fill" : @"lock.open", _symConfig,
                          self, @selector(toggleLock:), idx, lockColor),
  ];

  CanvasLayerRow *row = [[CanvasLayerRow alloc] initWithFrame:NSZeroRect];
  row.owner = self;
  row.rowIndex = (NSInteger)idx;
  for (NSView *v in views)
    [row addArrangedSubview:v];
  row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  row.alignment = NSLayoutAttributeCenterY;
  row.distribution = NSStackViewDistributionFill;
  row.spacing = KKSpacingMD;
  // Indent nested group members by their depth.
  CGFloat depth = (CGFloat)CanvasLayerAncestorIndices(idx, _paths).count;
  row.edgeInsets =
      NSEdgeInsetsMake(0, KKPaddingMD + depth * kGroupIndent, 0, KKPaddingMD);
  row.wantsLayer = YES;
  row.layer.cornerRadius = KKRadiusSM;
  row.layer.backgroundColor =
      selected
          ? [[NSColor accent] colorWithAlphaComponent:kSelectionAlpha].CGColor
          : NSColor.clearColor.CGColor;

  // Right-click context menu - assign to the row and its subviews so a
  // right-click anywhere on the row shows it.
  NSMenu *menu = [self _contextMenuForIndex:idx];
  row.menu = menu;
  for (NSView *sub in views)
    sub.menu = menu;
  return row;
}

#pragma mark - Context menu

- (NSMenuItem *)_menuItemWithTitle:(NSString *)title
                            symbol:(NSString *)symbol
                            action:(SEL)action
                               tag:(NSUInteger)tag {
  NSMenuItem *item = [[NSMenuItem alloc] initWithTitle:title
                                                action:action
                                         keyEquivalent:@""];
  item.target = self;
  item.tag = (NSInteger)tag;
  item.image = [NSImage imageWithSystemSymbolName:symbol
                         accessibilityDescription:nil];
  return item;
}

- (NSMenu *)_contextMenuForIndex:(NSUInteger)idx {
  NSMenu *menu = [[NSMenu alloc] init];
  [menu addItem:[self _menuItemWithTitle:CLoc(@"Rename", @"Layer context menu.")
                                  symbol:@"pencil"
                                  action:@selector(renameRow:)
                                     tag:idx]];
  [menu addItem:[self _menuItemWithTitle:CLoc(@"Duplicate",
                                              @"Layer context menu.")
                                  symbol:@"plus.rectangle.on.rectangle"
                                  action:@selector(duplicateRow:)
                                     tag:idx]];

  [menu addItem:[NSMenuItem separatorItem]];
  [menu addItem:[self _menuItemWithTitle:CLoc(@"Group", @"Layer context menu.")
                                  symbol:@"folder.badge.plus"
                                  action:@selector(groupSelection:)
                                     tag:idx]];
  if (idx < _paths.count && _paths[idx].isGroup)
    [menu addItem:[self _menuItemWithTitle:CLoc(@"Ungroup",
                                                @"Layer context menu.")
                                    symbol:@"folder.badge.minus"
                                    action:@selector(ungroupRow:)
                                       tag:idx]];
  if (idx < _paths.count && _paths[idx].parentGroupID.length)
    [menu addItem:[self _menuItemWithTitle:CLoc(@"Remove from Group",
                                                @"Layer context menu.")
                                    symbol:@"rectangle.portrait.and.arrow.right"
                                    action:@selector(removeFromGroup:)
                                       tag:idx]];

  [menu addItem:[NSMenuItem separatorItem]];
  NSMenuItem *del =
      [self _menuItemWithTitle:CLoc(@"Delete", @"Layer context menu.")
                        symbol:@"trash"
                        action:@selector(deleteRow:)
                           tag:idx];
  del.attributedTitle = [[NSAttributedString alloc]
      initWithString:CLoc(@"Delete", @"Layer context menu.")
          attributes:@{NSForegroundColorAttributeName : [NSColor error]}];
  [menu addItem:del];
  return menu;
}

// Acts on the whole selection when right-clicking a row that's part of a
// multi-selection; otherwise just that row.
- (NSIndexSet *)_actionTargetsForTag:(NSUInteger)tag {
  if (_selection.count > 1 && [_selection containsIndex:tag])
    return [_selection copy];
  return [NSIndexSet indexSetWithIndex:tag];
}

#pragma mark - Selection

- (BOOL)isRowSelected:(NSUInteger)idx {
  return [_selection containsIndex:idx];
}

- (void)selectIndex:(NSUInteger)idx
          modifiers:(NSEventModifierFlags)mods
         clickCount:(NSInteger)clicks {
  [self _commitRenameIfEditing];
  // Take key + focus so keyboard actions (Delete) target the panel.
  [self.window makeKeyWindow];
  [self.window makeFirstResponder:self];
  if (mods & NSEventModifierFlagCommand) {
    if ([_selection containsIndex:idx])
      [_selection removeIndex:idx];
    else
      [_selection addIndex:idx];
  } else if ((mods & NSEventModifierFlagShift) && _selection.count > 0) {
    NSUInteger anchor = _selection.firstIndex;
    NSUInteger lo = MIN(anchor, idx), hi = MAX(anchor, idx);
    [_selection addIndexesInRange:NSMakeRange(lo, hi - lo + 1)];
  } else {
    [_selection removeAllIndexes];
    [_selection addIndex:idx];
  }
  [self _applySelectionStyling];
}

@end
