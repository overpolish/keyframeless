/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLaneFilterChecklistView.h"

#import "KKTimelineLanesView_Private.h" // _KKManageRow

@implementation KKLaneFilterChecklistView {
  NSSet<NSString *> *_visible;
  NSSet<NSString *> *_soloed;
}

- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes
                visibleLabels:(NSSet<NSString *> *)visible
                 soloedLabels:(NSSet<NSString *> *)soloed
                minimumHeight:(CGFloat)minimumHeight {
  self = [super initWithLanes:lanes minimumHeight:minimumHeight];
  if (!self)
    return nil;
  _visible = [visible copy];
  _soloed = [soloed copy];
  [self rebuildRows];
  return self;
}

- (void)configureRow:(_KKManageRow *)row forLane:(KKLane *)lane {
  row.checked = [_visible containsObject:lane.label];
  row.warning = [_soloed containsObject:lane.label];
  NSString *label = lane.label;
  __weak typeof(self) weak = self;
  row.onToggle = ^{
    __strong typeof(weak) s = weak;
    if (s.onToggled)
      s.onToggled(label, ![s->_visible containsObject:label]);
  };
  row.onOptionToggle = ^{
    __strong typeof(weak) s = weak;
    if (s.onSolo)
      s.onSolo(label);
  };
}

- (void)reloadVisibleLabels:(NSSet<NSString *> *)visible
               soloedLabels:(NSSet<NSString *> *)soloed {
  _visible = [visible copy];
  _soloed = [soloed copy];
  for (_KKManageRow *row in _allRows) {
    row.checked = [_visible containsObject:row.rowLabel];
    row.warning = [_soloed containsObject:row.rowLabel];
  }
}

- (void)reloadLanes:(NSArray<KKLane *> *)lanes
      visibleLabels:(NSSet<NSString *> *)visible
       soloedLabels:(NSSet<NSString *> *)soloed {
  _visible = [visible copy];
  _soloed = [soloed copy];
  [self setLanes:lanes]; // rebuilds rows via configureRow:forLane:
  if (self.popover)
    self.popover.contentSize = NSMakeSize(
        [KKLaneFilterChecklistView preferredWidth], [self fittingHeight]);
}

@end
