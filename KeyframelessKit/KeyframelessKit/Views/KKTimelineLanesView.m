/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKTimelineLanesView.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import "KKTimelineLanesView_Popovers.h"
#import "KKTimelineLanesView_Private.h"
#import <KeyframelessKit/KKLog.h>

@implementation KKTimelineLanesView

- (instancetype)initWithAvailableLanes:(NSArray<KKLane *> *)availableLanes
                              timeline:(KKTimeline *)timeline {
  self = [super initWithFrame:NSZeroRect];
  if (self) {
    _availableLanes = [availableLanes
        sortedArrayUsingComparator:^NSComparisonResult(KKLane *a, KKLane *b) {
          return [a.label localizedCaseInsensitiveCompare:b.label];
        }];
    _timeline = [timeline copy];
    _laneRows = [NSMutableDictionary dictionary];
    [self _buildUI];
    [self _refresh];
  }
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (void)_buildUI {
  _laneStack = [NSStackView stackViewWithViews:@[]];
  _laneStack.translatesAutoresizingMaskIntoConstraints = NO;
  _laneStack.orientation = NSUserInterfaceLayoutOrientationVertical;
  _laneStack.alignment = NSLayoutAttributeLeading;
  _laneStack.spacing = 0;
  _laneStack.edgeInsets = NSEdgeInsetsZero;
  [_laneStack setContentHuggingPriority:NSLayoutPriorityRequired
                         forOrientation:NSLayoutConstraintOrientationVertical];
  [self addSubview:_laneStack];

  NSView *footerRow = [[NSView alloc] init];
  footerRow.translatesAutoresizingMaskIntoConstraints = NO;
  _footerRow = footerRow;
  [self addSubview:footerRow];

  NSTextField *animatedLabel = [NSTextField labelWithString:@"Animated"];
  animatedLabel.translatesAutoresizingMaskIntoConstraints = NO;
  animatedLabel.font = [NSFont systemFontOfSize:KKFontSizeSM
                                         weight:NSFontWeightMedium];
  animatedLabel.textColor =
      [[NSColor inspectorLabel] colorWithAlphaComponent:0.5];
  [footerRow addSubview:animatedLabel];

  _dropdownTrigger = [[_KKDropdownTrigger alloc] init];
  _dropdownTrigger.translatesAutoresizingMaskIntoConstraints = NO;
  [footerRow addSubview:_dropdownTrigger];

  __weak typeof(self) weak = self;
  __weak _KKDropdownTrigger *weakTrigger = _dropdownTrigger;
  _dropdownTrigger.onTapped = ^{
    __strong typeof(weak) s = weak;
    __strong _KKDropdownTrigger *trigger = weakTrigger;
    if (!s || !trigger)
      return;
    // Defer by one run-loop cycle so any in-flight mouseDown event (e.g. from
    // sendEvent: during joyride click forwarding) is fully consumed before
    // NSPopoverBehaviorTransient installs its outside-click monitor.
    dispatch_async(dispatch_get_main_queue(), ^{
      __strong typeof(weak) s2 = weak;
      __strong _KKDropdownTrigger *t2 = weakTrigger;
      if (s2 && t2)
        [s2 _showManagePopoverFromView:t2];
    });
  };

  _centeredArea = [[NSView alloc] init];
  _centeredArea.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:_centeredArea];

  _hintLabel = [NSTextField labelWithString:@"No animated properties"];
  _hintLabel.translatesAutoresizingMaskIntoConstraints = NO;
  _hintLabel.font = [NSFont systemFontOfSize:KKFontSizeSM
                                      weight:NSFontWeightRegular];
  _hintLabel.textColor = [[NSColor inspectorLabel] colorWithAlphaComponent:0.4];
  _hintLabel.alignment = NSTextAlignmentCenter;
  [_centeredArea addSubview:_hintLabel];

  [NSLayoutConstraint activateConstraints:@[
    [_laneStack.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [_laneStack.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [_laneStack.topAnchor constraintEqualToAnchor:self.topAnchor],

    [footerRow.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [footerRow.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [footerRow.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
    [footerRow.heightAnchor constraintEqualToConstant:kFooterH],

    [animatedLabel.leadingAnchor constraintEqualToAnchor:footerRow.leadingAnchor
                                                constant:KKPaddingLG],
    [animatedLabel.centerYAnchor
        constraintEqualToAnchor:footerRow.centerYAnchor],

    [_dropdownTrigger.leadingAnchor
        constraintEqualToAnchor:animatedLabel.trailingAnchor
                       constant:KKSpacingMD],
    [_dropdownTrigger.trailingAnchor
        constraintEqualToAnchor:footerRow.trailingAnchor
                       constant:-KKPaddingLG],
    [_dropdownTrigger.topAnchor constraintEqualToAnchor:footerRow.topAnchor],
    [_dropdownTrigger.bottomAnchor
        constraintEqualToAnchor:footerRow.bottomAnchor],

    [_centeredArea.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [_centeredArea.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [_centeredArea.topAnchor constraintEqualToAnchor:_laneStack.bottomAnchor],
    [_centeredArea.bottomAnchor constraintEqualToAnchor:footerRow.topAnchor],

    [_hintLabel.centerXAnchor
        constraintEqualToAnchor:_centeredArea.centerXAnchor],
    [_hintLabel.centerYAnchor
        constraintEqualToAnchor:_centeredArea.centerYAnchor],
  ]];
}

- (void)_refresh {
  NSMutableArray<NSString *> *toRemove = [NSMutableArray array];
  for (NSString *label in _laneRows) {
    if (![self _laneForLabel:label])
      [toRemove addObject:label];
  }
  for (NSString *label in toRemove) {
    _KKLaneRow *row = _laneRows[label];
    [_laneStack removeArrangedSubview:row];
    [row removeFromSuperview];
    [_laneRows removeObjectForKey:label];
  }

  BOOL anyOptedIn = NO;
  for (KKLane *tmpl in _availableLanes) {
    if (![self _laneForLabel:tmpl.label])
      continue;
    anyOptedIn = YES;
    if (!_laneRows[tmpl.label]) {
      _KKLaneRow *row = [[_KKLaneRow alloc] init];
      row.translatesAutoresizingMaskIntoConstraints = NO;
      row.laneLabel = tmpl.label;
      _laneRows[tmpl.label] = row;
      NSInteger insertIdx = _laneStack.arrangedSubviews.count;
      for (NSInteger i = 0; i < (NSInteger)_laneStack.arrangedSubviews.count;
           i++) {
        _KKLaneRow *existing = (_KKLaneRow *)_laneStack.arrangedSubviews[i];
        if ([tmpl.label localizedCaseInsensitiveCompare:existing.laneLabel] ==
            NSOrderedAscending) {
          insertIdx = i;
          break;
        }
      }
      [_laneStack insertArrangedSubview:row atIndex:insertIdx];
      [row.widthAnchor constraintEqualToAnchor:_laneStack.widthAnchor].active =
          YES;
    }
  }
  _hintLabel.hidden = anyOptedIn;

  NSMutableArray<NSString *> *opted = [NSMutableArray array];
  for (KKLane *tmpl in _availableLanes)
    if ([self _laneForLabel:tmpl.label])
      [opted addObject:tmpl.label];
  _dropdownTrigger.selectedLabels = opted;
  [_dropdownTrigger setNeedsDisplay:YES];

  if (_openManageView)
    [_openManageView updateCheckedLabels:[self _optedInLabelsSet]];
  if (_openStaticView)
    [_openStaticView updateUnoptedLanes:[self _unoptedLanes]];
}

- (nullable KKLane *)_laneForLabel:(NSString *)label {
  for (KKLane *lane in _timeline.lanes)
    if ([lane.label isEqualToString:label])
      return lane;
  return nil;
}

- (nullable KKLane *)_templateForLabel:(NSString *)label {
  for (KKLane *tmpl in _availableLanes)
    if ([tmpl.label isEqualToString:label])
      return tmpl;
  return nil;
}

- (NSSet<NSString *> *)_optedInLabelsSet {
  NSMutableSet<NSString *> *set = [NSMutableSet set];
  for (KKLane *lane in _timeline.lanes)
    [set addObject:lane.label];
  return [set copy];
}

- (NSArray<KKLane *> *)_unoptedLanes {
  NSMutableArray<KKLane *> *result = [NSMutableArray array];
  for (KKLane *tmpl in _availableLanes)
    if (![self _laneForLabel:tmpl.label])
      [result addObject:tmpl];
  return result;
}

- (NSView *)footerView {
  return _footerRow;
}

- (nullable NSView *)laneRowViewForLabel:(NSString *)label {
  return _laneRows[label];
}

- (KKTimeline *)currentTimeline {
  return _timeline;
}

- (NSArray<NSNumber *> *)_defaultValuesForLabel:(NSString *)label {
  KKLane *tmpl = [self _templateForLabel:label];
  if (!tmpl)
    return @[ @0.0 ];
  if (tmpl.valueType == KKLaneValueTypeBox)
    return @[ @1.0, @1.0, @0.0, @0.0 ];
  double def =
      tmpl.componentMin.firstObject ? tmpl.componentMin[0].doubleValue : 0.0;
  return @[ @(def) ];
}

- (void)_optInLaneWithLabel:(NSString *)label
                     values:(NSArray<NSNumber *> *)values {
  KKLane *tmpl = [self _templateForLabel:label];
  if (!tmpl)
    return;
  KKLane *lane = [KKLane laneWithLabel:label];
  lane.valueType = tmpl.valueType;
  lane.componentMin = tmpl.componentMin;
  lane.componentMax = tmpl.componentMax;
  KKKeyPose *kp = [KKKeyPose keyposeAtTime:0.0 values:values];
  [lane insertKeypose:kp];

  KKTimeline *updated = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [updated.lanes mutableCopy];
  BOOL replaced = NO;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if ([lanes[i].label isEqualToString:label]) {
      lanes[i] = lane;
      replaced = YES;
      break;
    }
  }
  if (!replaced)
    [lanes addObject:lane];
  updated.lanes = lanes;
  _timeline = updated;
  [self _refresh];
  if (_onTimelineMutated)
    _onTimelineMutated(updated);
}

- (void)_optOutLaneWithLabel:(NSString *)label {
  KKTimeline *updated = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [updated.lanes mutableCopy];
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    if ([lanes[i].label isEqualToString:label]) {
      [lanes removeObjectAtIndex:i];
      break;
    }
  }
  updated.lanes = lanes;
  _timeline = updated;

  _KKLaneRow *row = _laneRows[label];
  if (row) {
    [_laneStack removeArrangedSubview:row];
    [row removeFromSuperview];
    [_laneRows removeObjectForKey:label];
  }
  [self _refresh];
  if (_onTimelineMutated)
    _onTimelineMutated(updated);
}

- (BOOL)hasUnoptedLanes {
  return [self _unoptedLanes].count > 0;
}

- (void)applyTimeline:(KKTimeline *)timeline {
  _timeline = [timeline copy];
  [self _refresh];
}

@end
