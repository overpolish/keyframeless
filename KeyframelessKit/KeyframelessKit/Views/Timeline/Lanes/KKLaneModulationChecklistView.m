/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLaneModulationChecklistView.h"

#import "KKTimelineLanesView_Private.h" // _KKManageRow

@implementation KKLaneModulationChecklistView {
  NSArray<NSArray<NSString *> *> *_compounds;
  NSMutableArray<NSMutableArray<NSNumber *> *> *_states;
  // Parallel to _allRows: each row's (compoundIndex, segmentIndex) so a toggle
  // or external refresh maps straight back to the compound coordinates.
  NSMutableArray<NSNumber *> *_rowCompound;
  NSMutableArray<NSNumber *> *_rowSegment;
}

- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes
                    compounds:(NSArray<NSArray<NSString *> *> *)compounds
                       states:(NSArray<NSArray<NSNumber *> *> *)states
                        width:(CGFloat)width
                maxBodyHeight:(CGFloat)maxBodyHeight {
  self = [super initWithLanes:lanes width:width maxBodyHeight:maxBodyHeight];
  if (!self)
    return nil;
  _compounds = [compounds copy];
  _states = [NSMutableArray arrayWithCapacity:states.count];
  for (NSArray<NSNumber *> *s in states)
    [_states addObject:[s mutableCopy]];
  _rowCompound = [NSMutableArray array];
  _rowSegment = [NSMutableArray array];
  [self rebuildRows];
  return self;
}

// A multi-segment compound is one lane: segment 0 is the master (top level),
// segments 1+ are its components (indented one level). Category comes from the
// parallel lane so master + children page together under the same pill.
- (void)rebuildRows {
  [self removeAllRows];
  [_rowCompound removeAllObjects];
  [_rowSegment removeAllObjects];
  __weak typeof(self) weak = self;
  for (NSInteger ci = 0; ci < (NSInteger)_compounds.count; ci++) {
    NSArray<NSString *> *compound = _compounds[ci];
    KKLane *lane = (ci < (NSInteger)_lanes.count) ? _lanes[ci] : nil;
    NSString *cat = lane.categoryKey;
    for (NSInteger si = 0; si < (NSInteger)compound.count; si++) {
      // Leaf of a dotted key reads as the component (mirrors the OSC
      // checklist); the Hold builder already passes bare component labels, so
      // this is a no-op for them and only helps if a key is ever dotted.
      NSString *label =
          [compound[si] componentsSeparatedByString:@"."].lastObject
              ?: compound[si];
      _KKManageRow *row = [self appendRowWithLabel:label
                                       categoryKey:cat
                                       indentLevel:(si == 0 ? 0 : 1)];
      row.checked =
          (si < (NSInteger)_states[ci].count) ? _states[ci][si].boolValue : NO;
      NSInteger capCI = ci, capSI = si;
      row.onToggle = ^{
        [weak _toggleCompound:capCI segment:capSI];
      };
      [_rowCompound addObject:@(ci)];
      [_rowSegment addObject:@(si)];
    }
  }
  [self refilterAndResize];
}

- (void)_toggleCompound:(NSInteger)ci segment:(NSInteger)si {
  if (ci < 0 || ci >= (NSInteger)_states.count || si < 0 ||
      si >= (NSInteger)_states[ci].count)
    return;
  BOOL now = !_states[ci][si].boolValue;
  _states[ci][si] = @(now);
  for (NSInteger r = 0; r < (NSInteger)_rowCompound.count; r++)
    if (_rowCompound[r].integerValue == ci &&
        _rowSegment[r].integerValue == si && r < (NSInteger)_allRows.count)
      _allRows[r].checked = now;
  if (self.onToggled)
    self.onToggled(ci, si, now);
}

- (void)reloadLanes:(NSArray<KKLane *> *)lanes
          compounds:(NSArray<NSArray<NSString *> *> *)compounds
             states:(NSArray<NSArray<NSNumber *> *> *)states {
  _lanes = [lanes copy]; // @protected base ivar (category pill + per-row cat)
  _compounds = [compounds copy];
  _states = [NSMutableArray arrayWithCapacity:states.count];
  for (NSArray<NSNumber *> *s in states)
    [_states addObject:[s mutableCopy]];
  [self rebuildRows];
}

- (void)reloadStates:(NSArray<NSArray<NSNumber *> *> *)states {
  if (states.count != _states.count)
    return;
  for (NSInteger i = 0; i < (NSInteger)states.count; i++)
    _states[i] = [states[i] mutableCopy];
  for (NSInteger r = 0; r < (NSInteger)_allRows.count; r++) {
    NSInteger ci = _rowCompound[r].integerValue;
    NSInteger si = _rowSegment[r].integerValue;
    if (ci < (NSInteger)_states.count && si < (NSInteger)_states[ci].count)
      _allRows[r].checked = _states[ci][si].boolValue;
  }
}

@end
