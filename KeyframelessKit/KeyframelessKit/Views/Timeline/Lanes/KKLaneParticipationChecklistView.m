/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLaneParticipationChecklistView.h"

#import "KKTimelineLanesView_Private.h" // _KKManageRow

@implementation KKLaneParticipationChecklistView {
  NSSet<NSString *> *_checked;
}

- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes
                checkedLabels:(NSSet<NSString *> *)checked
                        width:(CGFloat)width
                maxBodyHeight:(CGFloat)maxBodyHeight {
  self = [super initWithLanes:lanes width:width maxBodyHeight:maxBodyHeight];
  if (!self)
    return nil;
  _checked = [checked copy];
  [self rebuildRows];
  return self;
}

- (void)configureRow:(_KKManageRow *)row forLane:(KKLane *)lane {
  row.checked = [_checked containsObject:lane.key];
  NSString *label = lane.key;
  __weak typeof(self) weak = self;
  row.onToggle = ^{
    __strong typeof(weak) s = weak;
    if (s.onToggled)
      s.onToggled(label, ![s->_checked containsObject:label]);
  };
}

- (void)reloadCheckedLabels:(NSSet<NSString *> *)checked {
  _checked = [checked copy];
  for (_KKManageRow *row in _allRows)
    row.checked = [_checked containsObject:row.rowLabel];
}

- (void)reloadLanes:(NSArray<KKLane *> *)lanes
      checkedLabels:(NSSet<NSString *> *)checked {
  _checked = [checked copy];
  [self setLanes:lanes]; // rebuilds rows via configureRow:forLane:
}

@end
