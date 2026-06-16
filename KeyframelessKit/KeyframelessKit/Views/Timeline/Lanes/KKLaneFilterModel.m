/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLaneFilterModel.h"
#import "KKLocalized.h"

@implementation KKLaneFilterModel {
  NSArray<NSString *> *_allLabels;     // every lane, in order
  NSArray<NSString *> *_laneSignature; // label + layer name + category, per lane
  // Per compound, per segment: the lane labels that segment toggles. A master
  // (layer or category) segment targets every lane it heads; a plain lane
  // segment targets its single lane. Parallel `_segIsMaster` flags masters.
  NSArray<NSArray<NSArray<NSString *> *> *> *_segTargets;
  NSArray<NSArray<NSNumber *> *> *_segIsMaster;
  NSMutableSet<NSString *> *_visible;
  NSMutableSet<NSString *> *_soloLabels; // lanes visible via an active solo
}

- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes {
  self = [super init];
  if (!self)
    return nil;
  _visible = [NSMutableSet set];
  _soloLabels = [NSMutableSet set];
  for (KKLane *l in lanes)
    [_visible addObject:l.label];
  [self _rebuildForLanes:lanes];
  return self;
}

- (BOOL)applyLanes:(NSArray<KKLane *> *)lanes {
  if ([[self _signatureForLanes:lanes] isEqualToArray:_laneSignature])
    return NO; // same lanes + layer names + order - nothing to rebuild
  NSArray<NSString *> *newLabels = [lanes valueForKey:@"label"];
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
  return YES;
}

- (void)_rebuildForLanes:(NSArray<KKLane *> *)lanes {
  _allLabels = [lanes valueForKey:@"label"];
  _laneSignature = [self _signatureForLanes:lanes];
  _displayLabels = [self _buildCompoundsForLanes:lanes]; // sets _seg* ivars
  _masterExcludedIndices = [self _computeMasterExcludedIndices];
}

#pragma mark - Compound model

// Per-lane identity for the rebuild guard: the lane label AND its display-only
// layer name + category, so renaming a layer (label unchanged, only layerLabel)
// still rebuilds the pills.
- (NSArray<NSString *> *)_signatureForLanes:(NSArray<KKLane *> *)lanes {
  NSMutableArray<NSString *> *sig = [NSMutableArray array];
  for (KKLane *l in lanes)
    [sig addObject:[NSString stringWithFormat:@"%@\x1f%@\x1f%@", l.label ?: @"",
                                              l.layerLabel ?: @"",
                                              l.categoryKey ?: @""]];
  return sig;
}

// Distinct layer keys in first-appearance order (multi-owner timelines tag each
// lane with its owning layer). Empty if no lane carries a layerKey.
- (NSArray<NSString *> *)_orderedLayerKeysForLanes:(NSArray<KKLane *> *)lanes {
  NSMutableArray<NSString *> *keys = [NSMutableArray array];
  NSMutableSet<NSString *> *seen = [NSMutableSet set];
  for (KKLane *l in lanes)
    if (l.layerKey.length && ![seen containsObject:l.layerKey]) {
      [seen addObject:l.layerKey];
      [keys addObject:l.layerKey];
    }
  return keys;
}

// Append category-grouped segments for `lanes` onto one compound's parallel
// display / target / master arrays. Consecutive same-category lanes become a
// [Category | lane | lane] run (the leading category segment is a master over
// the run); an uncategorised lane is a single plain segment.
- (void)_appendCategorySegmentsForLanes:(NSArray<KKLane *> *)lanes
                                display:(NSMutableArray<NSString *> *)display
                                targets:
                                    (NSMutableArray<NSArray<NSString *> *> *)
                                        targets
                               isMaster:(NSMutableArray<NSNumber *> *)isMaster {
  NSInteger i = 0;
  while (i < (NSInteger)lanes.count) {
    KKLane *l = lanes[i];
    NSString *cat = l.categoryKey;
    if (cat.length) {
      NSMutableArray<NSString *> *grp =
          [NSMutableArray arrayWithObject:l.label];
      NSInteger j = i + 1;
      while (j < (NSInteger)lanes.count &&
             [lanes[j].categoryKey isEqualToString:cat]) {
        [grp addObject:lanes[j].label];
        j++;
      }
      [display addObject:KKLocalizedParamName(cat)];
      [targets addObject:[grp copy]];
      [isMaster addObject:@YES];
      for (NSString *lab in grp) {
        [display addObject:KKLocalizedParamName(lab)];
        [targets addObject:@[ lab ]];
        [isMaster addObject:@NO];
      }
      i = j;
    } else {
      [display addObject:KKLocalizedParamName(l.label)];
      [targets addObject:@[ l.label ]];
      [isMaster addObject:@NO];
      i++;
    }
  }
}

// One capsule for `lanes`: an optional leading master segment (the layer name,
// heading every lane) followed by the category-grouped segments. Appends to the
// three parallel per-compound output arrays.
- (void)_addCompoundForLanes:(NSArray<KKLane *> *)lanes
                 masterLabel:(nullable NSString *)masterLabel
                  intoDisplay:(NSMutableArray<NSArray<NSString *> *> *)display
                      targets:
                          (NSMutableArray<NSArray<NSArray<NSString *> *> *> *)
                              targets
                      masters:(NSMutableArray<NSArray<NSNumber *> *> *)masters {
  NSMutableArray<NSString *> *cd = [NSMutableArray array];
  NSMutableArray<NSArray<NSString *> *> *ct = [NSMutableArray array];
  NSMutableArray<NSNumber *> *cm = [NSMutableArray array];
  if (masterLabel.length) {
    [cd addObject:masterLabel];
    [ct addObject:[lanes valueForKey:@"label"]];
    [cm addObject:@YES];
  }
  [self _appendCategorySegmentsForLanes:lanes
                                display:cd
                                targets:ct
                               isMaster:cm];
  [display addObject:cd];
  [targets addObject:ct];
  [masters addObject:cm];
}

// Build the capsule model and return per-compound display labels.
//  - Multi-owner: ONE capsule per layer, prefixed with a layer master.
//  - Single-owner: each category run / bare lane is its own capsule.
// Sets _segTargets / _segIsMaster.
- (NSArray<NSArray<NSString *> *> *)_buildCompoundsForLanes:
    (NSArray<KKLane *> *)lanes {
  NSMutableArray<NSArray<NSString *> *> *display = [NSMutableArray array];
  NSMutableArray<NSArray<NSArray<NSString *> *> *> *targets =
      [NSMutableArray array];
  NSMutableArray<NSArray<NSNumber *> *> *masters = [NSMutableArray array];

  NSArray<NSString *> *layerKeys = [self _orderedLayerKeysForLanes:lanes];
  if (layerKeys.count) {
    for (NSString *lid in layerKeys) {
      NSMutableArray<KKLane *> *layerLanes = [NSMutableArray array];
      NSString *layerLabel = lid;
      for (KKLane *l in lanes)
        if ([l.layerKey isEqualToString:lid]) {
          [layerLanes addObject:l];
          if (l.layerLabel.length)
            layerLabel = l.layerLabel;
        }
      [self _addCompoundForLanes:layerLanes
                     masterLabel:KKTruncatedLayerName(layerLabel)
                     intoDisplay:display
                         targets:targets
                         masters:masters];
    }
  } else {
    NSInteger i = 0;
    while (i < (NSInteger)lanes.count) {
      NSString *cat = lanes[i].categoryKey;
      NSInteger j = i + 1;
      if (cat.length)
        while (j < (NSInteger)lanes.count &&
               [lanes[j].categoryKey isEqualToString:cat])
          j++;
      [self _addCompoundForLanes:[lanes subarrayWithRange:NSMakeRange(i, j - i)]
                     masterLabel:nil
                     intoDisplay:display
                         targets:targets
                         masters:masters];
      i = j;
    }
  }

  _segTargets = targets;
  _segIsMaster = masters;
  return display;
}

- (NSArray<NSIndexSet *> *)_computeMasterExcludedIndices {
  NSMutableArray<NSIndexSet *> *excluded = [NSMutableArray array];
  for (NSArray<NSNumber *> *flags in _segIsMaster) {
    NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
    for (NSInteger s = 0; s < (NSInteger)flags.count; s++)
      if (flags[s].boolValue)
        [set addIndex:s];
    [excluded addObject:set];
  }
  return excluded;
}

#pragma mark - Derived state

// Per-compound per-segment flags from a predicate over the segment's targets.
// A master heads >=1 lane and a plain segment exactly one, so `_anyVisible` /
// `_allSoloed` over the targets cover both cases without a master/lane branch.
- (NSArray<NSArray<NSNumber *> *> *)_flagsUsing:
    (BOOL (^)(NSArray<NSString *> *targets))pred {
  NSMutableArray<NSArray<NSNumber *> *> *out = [NSMutableArray array];
  for (NSArray<NSArray<NSString *> *> *segs in _segTargets) {
    NSMutableArray<NSNumber *> *row = [NSMutableArray array];
    for (NSArray<NSString *> *targets in segs)
      [row addObject:@(pred(targets))];
    [out addObject:row];
  }
  return out;
}

- (NSArray<NSArray<NSNumber *> *> *)segmentStates {
  return [self _flagsUsing:^BOOL(NSArray<NSString *> *targets) {
    return [self _anyVisible:targets];
  }];
}

- (NSArray<NSArray<NSNumber *> *> *)segmentWarnings {
  return [self _flagsUsing:^BOOL(NSArray<NSString *> *targets) {
    return [self _allSoloed:targets];
  }];
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

- (NSSet<NSString *> *)hiddenLabels {
  NSMutableSet<NSString *> *hidden = [NSMutableSet set];
  for (NSString *lab in _allLabels)
    if (![_visible containsObject:lab])
      [hidden addObject:lab];
  return hidden;
}

- (BOOL)filterActive {
  return _soloLabels.count > 0 || _visible.count < _allLabels.count;
}

#pragma mark - Mutations

// The lanes a compound segment targets, or nil for an out-of-range index.
- (nullable NSArray<NSString *> *)_targetsForCompound:(NSInteger)ci
                                              segment:(NSInteger)seg {
  if (ci < 0 || ci >= (NSInteger)_segTargets.count)
    return nil;
  NSArray<NSArray<NSString *> *> *segs = _segTargets[ci];
  if (seg < 0 || seg >= (NSInteger)segs.count)
    return nil;
  return segs[seg];
}

- (void)toggleCompound:(NSInteger)ci segment:(NSInteger)seg on:(BOOL)on {
  NSArray<NSString *> *targets = [self _targetsForCompound:ci segment:seg];
  if (!targets)
    return;
  [_soloLabels removeAllObjects]; // a manual toggle ends solo highlighting
  for (NSString *lab in targets) {
    if (on)
      [_visible addObject:lab];
    else
      [_visible removeObject:lab];
  }
}

- (void)soloCompound:(NSInteger)ci segment:(NSInteger)seg {
  NSArray<NSString *> *targets = [self _targetsForCompound:ci segment:seg];
  if (!targets)
    return;
  NSSet<NSString *> *targetSet = [NSSet setWithArray:targets];
  if ([_soloLabels isEqualToSet:targetSet]) {
    [self showAll];
  } else {
    _soloLabels = [targetSet mutableCopy];
    _visible = [targetSet mutableCopy];
  }
}

- (void)showAll {
  [_soloLabels removeAllObjects];
  [_visible removeAllObjects];
  [_visible addObjectsFromArray:_allLabels];
}

- (void)applyHidden:(NSSet<NSString *> *)hidden {
  [_soloLabels removeAllObjects];
  [_visible removeAllObjects];
  for (NSString *lab in _allLabels)
    if (![hidden containsObject:lab])
      [_visible addObject:lab];
}

- (NSMutableSet<NSString *> *)_intersect:(NSSet<NSString *> *)set
                              withLabels:(NSArray<NSString *> *)labels {
  NSMutableSet<NSString *> *out = [NSMutableSet set];
  for (NSString *lab in labels)
    if ([set containsObject:lab])
      [out addObject:lab];
  return out;
}

@end
