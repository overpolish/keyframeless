/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKChoiceChecklistView.h"

#import "KKLocalized.h"
#import "KKTimelineLanesView_Private.h"

@implementation KKChoiceChecklistView {
  NSArray<NSString *> *_options;
  NSInteger _selectedIndex;
  NSIndexSet *_selectedIndexes;
  BOOL _multiple;
}

- (instancetype)initWithOptions:(NSArray<NSString *> *)options
                  selectedIndex:(NSInteger)selectedIndex
                  maxBodyHeight:(CGFloat)maxBodyHeight {
  self =
      [self initWithOptions:options
            selectedIndexes:(selectedIndex >= 0
                                 ? [NSIndexSet indexSetWithIndex:selectedIndex]
                                 : [NSIndexSet indexSet])
              maxBodyHeight:maxBodyHeight];
  if (self) {
    _multiple = NO;
    _selectedIndex = selectedIndex;
    self.allowsMultipleSelection = NO;
    [self rebuildRows];
  }
  return self;
}

- (instancetype)initWithOptions:(NSArray<NSString *> *)options
                selectedIndexes:(NSIndexSet *)selectedIndexes
                  maxBodyHeight:(CGFloat)maxBodyHeight {
  // Embedded (capped + internally scrolling) rather than the base's
  // popover-resizing mode. A choice list can be any length a shader author
  // types, so it caps and scrolls behind the standard top/bottom fade instead
  // of growing the popover without limit.
  //
  // No lanes: the base only walks them in the default -rebuildRows, which this
  // replaces. Everything else it does - search, filtering, the row stack, the
  // height math - is lane-agnostic.
  self = [super initWithLanes:@[]
                        width:[[self class] preferredWidth]
                maxBodyHeight:maxBodyHeight];
  if (!self)
    return nil;
  _options = [options copy];
  _selectedIndexes = [selectedIndexes copy] ?: [NSIndexSet indexSet];
  _multiple = YES;
  _selectedIndex = -1;
  self.allowsMultipleSelection = YES;
  [self rebuildRows];
  return self;
}

- (void)rebuildRows {
  [self removeAllRows];
  for (NSInteger i = 0; i < (NSInteger)_options.count; i++) {
    // No category key: a choice's options are one flat list, so the base's
    // category pill stays out of the way.
    _KKManageRow *row = [self appendRowWithLabel:_options[i]
                                     categoryKey:nil
                                     indentLevel:0];
    row.displayOverride = KKLocalizedParamName(_options[i]);
    row.checked =
        _multiple ? [_selectedIndexes containsIndex:i] : (i == _selectedIndex);
    __weak typeof(self) weak = self;
    __weak _KKManageRow *weakRow = row;
    row.onToggle = ^{
      __strong typeof(weak) s = weak;
      if (!s)
        return;
      if (s->_multiple) {
        BOOL selected = !weakRow.checked;
        weakRow.checked = selected;
        NSMutableIndexSet *next = [s->_selectedIndexes mutableCopy];
        if (selected)
          [next addIndex:i];
        else
          [next removeIndex:i];
        s->_selectedIndexes = [next copy];
        if (s.onToggle)
          s.onToggle(i, selected);
        return;
      }
      // Move the mark here rather than waiting for the host to write the value
      // back through a rebuild: the click should land on the same tick even if
      // the host defers (an action scope, an undo group).
      s->_selectedIndex = i;
      [s checkOnlyRow:weakRow];
      if (s.onSelect)
        s.onSelect(i);
    };
  }
  [self refilterAndResize];
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
  if (_multiple) {
    [self setSelectedIndexes:selectedIndex >= 0
                                 ? [NSIndexSet indexSetWithIndex:selectedIndex]
                                 : [NSIndexSet indexSet]];
    return;
  }
  if (_selectedIndex == selectedIndex)
    return;
  _selectedIndex = selectedIndex;
  [self rebuildRows];
}

- (void)setSelectedIndexes:(NSIndexSet *)selectedIndexes {
  NSIndexSet *next = selectedIndexes ?: [NSIndexSet indexSet];
  if ([_selectedIndexes isEqualToIndexSet:next])
    return;
  _selectedIndexes = [next copy];
  [self rebuildRows];
}

@end
