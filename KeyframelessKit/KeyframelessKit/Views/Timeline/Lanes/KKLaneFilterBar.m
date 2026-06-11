/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLaneFilterBar.h"
#import "KKCompoundPillBar.h"
#import "KKLocalized.h"
#import "KKTokens.h"

static const CGFloat kLaneFilterBarH = 30.0;
static const CGFloat kLaneFilterPillH = 22.0;

@implementation KKLaneFilterBar {
  KKCompoundPillBar *_bar;
  NSArray<NSString *> *_allLabels;                     // every lane, in order
  NSArray<NSArray<NSString *> *> *_compoundLaneLabels; // per compound: lanes
  NSArray<NSNumber *> *_compoundHasHeader;             // per compound: BOOL
  NSMutableSet<NSString *> *_visible;
  NSMutableSet<NSString *> *_soloLabels; // lanes visible via an active solo
}

- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes {
  self = [super initWithFrame:NSZeroRect];
  if (!self)
    return nil;
  self.translatesAutoresizingMaskIntoConstraints = NO;
  _visible = [NSMutableSet set];
  _soloLabels = [NSMutableSet set];
  for (KKLane *l in lanes)
    [_visible addObject:l.label];
  [self _rebuildForLanes:lanes];
  return self;
}

- (BOOL)isFlipped {
  return YES;
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize(NSViewNoIntrinsicMetric, kLaneFilterBarH);
}

- (void)applyLanes:(NSArray<KKLane *> *)lanes {
  NSArray<NSString *> *newLabels = [lanes valueForKey:@"label"];
  if ([newLabels isEqualToArray:_allLabels])
    return; // same set + order - nothing to rebuild
  NSMutableSet<NSString *> *vis = [NSMutableSet set];
  for (NSString *lab in newLabels) {
    if (![_allLabels containsObject:lab])
      [vis addObject:lab]; // newly opted-in lane defaults to visible
    else if ([_visible containsObject:lab])
      [vis addObject:lab]; // survivors keep their visibility
  }
  if (vis.count == 0)
    [vis addObjectsFromArray:newLabels]; // a structural change never lands
                                         // all-hidden
  _visible = vis;
  _soloLabels = [self _intersect:_soloLabels withLabels:newLabels];
  [self _rebuildForLanes:lanes];
}

- (NSMutableSet<NSString *> *)_intersect:(NSSet<NSString *> *)set
                              withLabels:(NSArray<NSString *> *)labels {
  NSMutableSet<NSString *> *out = [NSMutableSet set];
  for (NSString *lab in labels)
    if ([set containsObject:lab])
      [out addObject:lab];
  return out;
}

- (NSSet<NSString *> *)hiddenLabels {
  NSMutableSet<NSString *> *hidden = [NSMutableSet set];
  for (NSString *lab in _allLabels)
    if (![_visible containsObject:lab])
      [hidden addObject:lab];
  return hidden;
}

- (void)showAllLanes {
  [_soloLabels removeAllObjects];
  [_visible removeAllObjects];
  [_visible addObjectsFromArray:_allLabels];
  [self _emitVisibilityChange];
}

- (void)applyHiddenLabels:(NSSet<NSString *> *)hidden {
  [_soloLabels removeAllObjects];
  [_visible removeAllObjects];
  for (NSString *lab in _allLabels)
    if (![hidden containsObject:lab])
      [_visible addObject:lab];
  [self _emitVisibilityChange];
}

// Group consecutive same-category lanes into a [Category | lane | lane] capsule
// (leading category segment is the group master); an uncategorised lane is its
// own single-segment capsule. Sets _compoundLaneLabels / _compoundHasHeader and
// returns the display labels (localized) for each capsule, in lane order.
- (NSArray<NSArray<NSString *> *> *)_buildCompoundsForLanes:
    (NSArray<KKLane *> *)lanes {
  NSMutableArray<NSArray<NSString *> *> *display = [NSMutableArray array];
  NSMutableArray<NSArray<NSString *> *> *laneLabels = [NSMutableArray array];
  NSMutableArray<NSNumber *> *hasHeader = [NSMutableArray array];
  NSInteger i = 0;
  while (i < (NSInteger)lanes.count) {
    KKLane *l = lanes[i];
    NSString *cat = l.categoryKey;
    if (cat.length) {
      NSMutableArray<NSString *> *grp =
          [NSMutableArray arrayWithObject:l.label];
      NSInteger j = i + 1;
      while (j < (NSInteger)lanes.count && [lanes[j].categoryKey
                                               isEqualToString:cat]) {
        [grp addObject:lanes[j].label];
        j++;
      }
      NSMutableArray<NSString *> *seg =
          [NSMutableArray arrayWithObject:KKLocalizedParamName(cat)];
      for (NSString *lab in grp)
        [seg addObject:KKLocalizedParamName(lab)];
      [display addObject:seg];
      [laneLabels addObject:grp];
      [hasHeader addObject:@YES];
      i = j;
    } else {
      [display addObject:@[ KKLocalizedParamName(l.label) ]];
      [laneLabels addObject:@[ l.label ]];
      [hasHeader addObject:@NO];
      i++;
    }
  }
  _compoundLaneLabels = laneLabels;
  _compoundHasHeader = hasHeader;
  return display;
}

// Per-compound index sets of the master (header) segments, which are kept out
// of the drag-sweep (they still toggle on a plain click, just aren't painted).
- (NSArray<NSIndexSet *> *)_masterExcludedIndices {
  NSMutableArray<NSIndexSet *> *excluded = [NSMutableArray array];
  for (NSNumber *h in _compoundHasHeader)
    [excluded addObject:h.boolValue ? [NSIndexSet indexSetWithIndex:0]
                                    : [NSIndexSet indexSet]];
  return excluded;
}

- (void)_rebuildForLanes:(NSArray<KKLane *> *)lanes {
  [_bar removeFromSuperview];
  _allLabels = [lanes valueForKey:@"label"];

  _bar = [[KKCompoundPillBar alloc]
      initWithCompounds:[self _buildCompoundsForLanes:lanes]];
  _bar.translatesAutoresizingMaskIntoConstraints = NO;
  _bar.crossCapsuleSweep = YES;
  _bar.dragExcludedIndices = [self _masterExcludedIndices];
  // The bar scrolls horizontally; its (potentially wide, e.g. long localized
  // labels) intrinsic content width must NOT inflate the inspector's
  // fittingSize and push the timeline off the right edge. Yield to the
  // available width instead of driving it.
  [_bar setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                 forOrientation:
                                     NSLayoutConstraintOrientationHorizontal];
  [_bar setContentHuggingPriority:NSLayoutPriorityDefaultLow
                   forOrientation:NSLayoutConstraintOrientationHorizontal];
  __weak typeof(self) weak = self;
  _bar.onToggled = ^(NSInteger ci, NSInteger seg, BOOL on) {
    [weak _toggleCompound:ci segment:seg on:on];
  };
  _bar.onOptionToggled = ^(NSInteger ci, NSInteger seg) {
    [weak _soloCompound:ci segment:seg];
  };
  [self _syncBar];
  [self addSubview:_bar];
  [NSLayoutConstraint activateConstraints:@[
    [_bar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                       constant:KKPaddingMD],
    [_bar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                        constant:-KKPaddingMD],
    [_bar.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    // The compound bar wraps an internal scroll view, so give it a definite
    // height (its natural grouped-pill height) rather than rely on intrinsic.
    [_bar.heightAnchor constraintEqualToConstant:kLaneFilterPillH],
  ]];
}

- (NSArray<NSArray<NSNumber *> *> *)_statesFromVisible {
  NSMutableArray<NSArray<NSNumber *> *> *states = [NSMutableArray array];
  for (NSInteger c = 0; c < (NSInteger)_compoundLaneLabels.count; c++) {
    NSArray<NSString *> *labels = _compoundLaneLabels[c];
    NSMutableArray<NSNumber *> *st = [NSMutableArray array];
    if (_compoundHasHeader[c].boolValue) {
      // Master is on when ANY lane in the group is visible, so a partially-
      // enabled group stays accent and one more master click turns it fully
      // off (the better mental model than "on only when all are visible").
      [st addObject:@([self _anyVisible:labels])];
    }
    for (NSString *lab in labels)
      [st addObject:@([_visible containsObject:lab])];
    [states addObject:st];
  }
  return states;
}

// Parallel to the states: a segment is flagged when its lane is soloed (master
// flagged only when its whole group is soloed), so soloed pills draw warning.
- (NSArray<NSArray<NSNumber *> *> *)_warningStatesFromSolo {
  NSMutableArray<NSArray<NSNumber *> *> *warnings = [NSMutableArray array];
  for (NSInteger c = 0; c < (NSInteger)_compoundLaneLabels.count; c++) {
    NSArray<NSString *> *labels = _compoundLaneLabels[c];
    NSMutableArray<NSNumber *> *wt = [NSMutableArray array];
    if (_compoundHasHeader[c].boolValue)
      [wt addObject:@([self _allSoloed:labels])];
    for (NSString *lab in labels)
      [wt addObject:@([_soloLabels containsObject:lab])];
    [warnings addObject:wt];
  }
  return warnings;
}

- (BOOL)_anyVisible:(NSArray<NSString *> *)labels {
  for (NSString *lab in labels)
    if ([_visible containsObject:lab])
      return YES;
  return NO;
}

- (BOOL)_allSoloed:(NSArray<NSString *> *)labels {
  if (labels.count == 0)
    return NO;
  for (NSString *lab in labels)
    if (![_soloLabels containsObject:lab])
      return NO;
  return YES;
}

- (void)_syncBar {
  _bar.states = [self _statesFromVisible];
  _bar.warningStates = [self _warningStatesFromSolo];
}

// The lanes this compound segment targets: the whole group for a master
// segment, otherwise the single lane. nil for an out-of-range index.
- (nullable NSArray<NSString *> *)_lanesForCompound:(NSInteger)ci
                                            segment:(NSInteger)seg {
  if (ci < 0 || ci >= (NSInteger)_compoundLaneLabels.count)
    return nil;
  NSArray<NSString *> *labels = _compoundLaneLabels[ci];
  BOOL header = _compoundHasHeader[ci].boolValue;
  if (header && seg == 0)
    return labels;
  NSInteger laneIdx = header ? seg - 1 : seg;
  if (laneIdx < 0 || laneIdx >= (NSInteger)labels.count)
    return nil;
  return @[ labels[laneIdx] ];
}

- (void)_emitVisibilityChange {
  [self _syncBar];
  if (self.onVisibilityChanged)
    self.onVisibilityChanged([self hiddenLabels]);
}

- (void)_toggleCompound:(NSInteger)ci segment:(NSInteger)seg on:(BOOL)on {
  NSArray<NSString *> *targets = [self _lanesForCompound:ci segment:seg];
  if (!targets)
    return;
  [_soloLabels removeAllObjects]; // a manual toggle ends solo highlighting
  for (NSString *lab in targets) {
    if (on)
      [_visible addObject:lab];
    else
      [_visible removeObject:lab];
  }
  // Empty is allowed now (host shows an "all hidden" message).
  [self _emitVisibilityChange];
  if (self.onUserToggled)
    self.onUserToggled();
}

// Option-click: solo the clicked lane/group (only it visible, drawn warning).
// Option-clicking the active solo again clears it and shows every lane.
- (void)_soloCompound:(NSInteger)ci segment:(NSInteger)seg {
  NSArray<NSString *> *targets = [self _lanesForCompound:ci segment:seg];
  if (!targets)
    return;
  NSSet<NSString *> *targetSet = [NSSet setWithArray:targets];
  if ([_soloLabels isEqualToSet:targetSet]) {
    [_soloLabels removeAllObjects];
    [_visible removeAllObjects];
    [_visible addObjectsFromArray:_allLabels];
  } else {
    _soloLabels = [targetSet mutableCopy];
    _visible = [targetSet mutableCopy];
  }
  [self _emitVisibilityChange];
  if (self.onUserToggled)
    self.onUserToggled();
}

@end
