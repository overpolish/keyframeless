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
}

- (instancetype)initWithOptions:(NSArray<NSString *> *)options
                  selectedIndex:(NSInteger)selectedIndex
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
  _selectedIndex = selectedIndex;
  self.allowsMultipleSelection = NO;
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
    row.checked = (i == _selectedIndex);
    __weak typeof(self) weak = self;
    __weak _KKManageRow *weakRow = row;
    row.onToggle = ^{
      __strong typeof(weak) s = weak;
      if (!s)
        return;
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
  if (_selectedIndex == selectedIndex)
    return;
  _selectedIndex = selectedIndex;
  [self rebuildRows];
}

@end
