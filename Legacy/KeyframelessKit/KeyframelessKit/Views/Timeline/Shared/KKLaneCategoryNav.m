/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLaneCategoryNav.h"
#import "KKLocalized.h"
#import "KKPillToggleRowView.h"

NSArray<NSArray<NSString *> *> *
KKOrderedLaneCategories(NSArray<KKLane *> *lanes) {
  NSMutableArray<NSString *> *keys = [NSMutableArray array];
  NSMutableArray<NSString *> *syms = [NSMutableArray array];
  for (KKLane *l in lanes) {
    NSString *k = l.categoryKey;
    if (k.length == 0 || [keys containsObject:k])
      continue;
    [keys addObject:k];
    [syms addObject:l.categorySymbol.length ? l.categorySymbol : @"circle"];
  }
  // Show the category nav whenever ANY category is declared (a single-category
  // plugin's sole category still gets its pill). Plugins that set no
  // categoryKey at all get none, as before.
  if (keys.count < 1)
    return @[];
  NSMutableArray<NSArray<NSString *> *> *out = [NSMutableArray array];
  for (NSUInteger i = 0; i < keys.count; i++)
    [out addObject:@[ keys[i], syms[i] ]];
  return out;
}

NSArray<NSString *> *KKLaneCategoryKeys(NSArray<KKLane *> *lanes) {
  NSMutableArray<NSString *> *keys = [NSMutableArray array];
  for (NSArray<NSString *> *pair in KKOrderedLaneCategories(lanes))
    [keys addObject:pair[0]];
  return keys;
}

NSDictionary<NSString *, NSString *> *
KKLaneCategoryByLabel(NSArray<KKLane *> *lanes) {
  NSMutableDictionary<NSString *, NSString *> *byLabel =
      [NSMutableDictionary dictionary];
  for (KKLane *lane in lanes)
    if (lane.categoryKey.length)
      byLabel[lane.key] = lane.categoryKey;
  return byLabel;
}

NSString *KKResolveLaneCategory(NSArray<KKLane *> *lanes, NSString *requested) {
  NSArray<NSArray<NSString *> *> *cats = KKOrderedLaneCategories(lanes);
  if (cats.count < 1)
    return nil;
  if (requested.length)
    for (NSArray<NSString *> *pair in cats)
      if ([pair[0] isEqualToString:requested])
        return requested;
  return cats.firstObject[0];
}

NSArray<NSString *> *KKLaneLayerKeys(NSArray<KKLane *> *lanes) {
  NSMutableArray<NSString *> *keys = [NSMutableArray array];
  for (KKLane *l in lanes) {
    NSString *k = l.layerKey;
    if (k.length && ![keys containsObject:k])
      [keys addObject:k];
  }
  return keys;
}

NSSet<NSString *> *
KKLaneLayerKeysWithKeyposeNearFraction(NSArray<KKLane *> *lanes,
                                       double fraction) {
  double snapped = fraction, best = INFINITY;
  for (KKLane *l in lanes) {
    if (!l.enabled || !l.layerKey.length)
      continue;
    for (KKKeyPose *kp in l.keyposes) {
      double d = fabs(kp.time - fraction);
      if (d < best) {
        best = d;
        snapped = kp.time;
      }
    }
  }
  NSMutableSet<NSString *> *out = [NSMutableSet set];
  for (KKLane *l in lanes) {
    if (!l.enabled || !l.layerKey.length ||
        [out containsObject:(NSString *)l.layerKey])
      continue;
    for (KKKeyPose *kp in l.keyposes)
      if (fabs(kp.time - snapped) < 1.0e-4) {
        [out addObject:l.layerKey];
        break;
      }
  }
  return out;
}

NSDictionary<NSString *, NSString *> *
KKLaneLayerNames(NSArray<KKLane *> *lanes) {
  NSMutableDictionary<NSString *, NSString *> *names =
      [NSMutableDictionary dictionary];
  for (KKLane *l in lanes) {
    NSString *k = l.layerKey;
    if (k.length && names[k] == nil)
      names[k] = l.layerLabel.length ? l.layerLabel : k;
  }
  return names;
}

KKPillToggleRowView *KKMakeLaneLayerPill(NSArray<KKLane *> *lanes,
                                         NSString *selected,
                                         void (^onSelect)(NSString *)) {
  NSArray<NSString *> *keys = KKLaneLayerKeys(lanes);
  if (keys.count < 2)
    return nil;
  NSDictionary<NSString *, NSString *> *names = KKLaneLayerNames(lanes);
  NSMutableArray<NSString *> *labels = [NSMutableArray array];
  for (NSString *k in keys)
    [labels addObject:KKTruncatedLayerName(names[k] ?: k)];
  // Never "no owner": a caller whose selection isn't in this lane set lands on
  // the first layer rather than on an all-owners page.
  NSUInteger found =
      selected.length ? [keys indexOfObject:selected] : NSNotFound;
  NSUInteger selIdx = (found == NSNotFound) ? 0 : found;

  KKPillToggleRowView *pill =
      [[KKPillToggleRowView alloc] initWithLabels:labels];
  pill.translatesAutoresizingMaskIntoConstraints = NO;
  pill.grouped = YES;
  pill.radioMode = YES;
  NSMutableArray<NSNumber *> *states = [NSMutableArray array];
  for (NSUInteger i = 0; i < labels.count; i++)
    [states addObject:@(i == selIdx)];
  pill.states = states;
  pill.onToggled = ^(NSInteger index, BOOL isOn) {
    if (!isOn || index < 0 || index >= (NSInteger)keys.count)
      return;
    if (onSelect)
      onSelect(keys[index]);
  };
  return pill;
}

NSImage *KKCategorySymbolImage(NSString *symbolName,
                               NSString *accessibilityKey) {
  NSImage *img = [NSImage imageWithSystemSymbolName:symbolName
                           accessibilityDescription:accessibilityKey];
  return img ?: [[NSImage alloc] initWithSize:NSMakeSize(11, 11)];
}

// One unit per category run (consecutive same-category lanes, mirroring the
// filter model's compound grouping) or per bare uncategorised lane. A category
// unit reads `Category > lane, lane`; a bare lane is just its localized label.
static NSArray<NSString *> *_kkCategoryUnits(NSArray<KKLane *> *lanes) {
  NSMutableArray<NSString *> *units = [NSMutableArray array];
  NSInteger i = 0;
  while (i < (NSInteger)lanes.count) {
    KKLane *l = lanes[i];
    NSString *cat = l.categoryKey;
    if (cat.length) {
      NSMutableArray<NSString *> *labels =
          [NSMutableArray arrayWithObject:KKLocalizedParamName(l.displayName)];
      NSInteger j = i + 1;
      while (j < (NSInteger)lanes.count && [lanes[j].categoryKey
                                               isEqualToString:cat]) {
        [labels addObject:KKLocalizedParamName(lanes[j].displayName)];
        j++;
      }
      [units
          addObject:[NSString
                        stringWithFormat:@"%@ > %@", KKLocalizedParamName(cat),
                                         [labels
                                             componentsJoinedByString:@", "]]];
      i = j;
    } else {
      [units addObject:KKLocalizedParamName(l.displayName)];
      i++;
    }
  }
  return units;
}

NSString *KKHierarchicalLaneSummary(NSArray<KKLane *> *lanes) {
  if (lanes.count == 0)
    return @"";

  BOOL hasLayers = NO;
  for (KKLane *l in lanes)
    if (l.layerKey.length) {
      hasLayers = YES;
      break;
    }

  if (hasLayers) {
    // One unit per layer (first-appearance order), prefixed by the layer name,
    // its category groups joined by ", "; layers joined by " | ".
    NSMutableArray<NSString *> *layerKeys = [NSMutableArray array];
    NSMutableSet<NSString *> *seen = [NSMutableSet set];
    for (KKLane *l in lanes) {
      NSString *k = l.layerKey ?: @"";
      if (![seen containsObject:k]) {
        [seen addObject:k];
        [layerKeys addObject:k];
      }
    }
    NSMutableArray<NSString *> *layerStrings = [NSMutableArray array];
    for (NSString *k in layerKeys) {
      NSMutableArray<KKLane *> *layerLanes = [NSMutableArray array];
      NSString *layerLabel = k;
      for (KKLane *l in lanes)
        if ([(l.layerKey ?: @"") isEqualToString:k]) {
          [layerLanes addObject:l];
          if (l.layerLabel.length)
            layerLabel = l.layerLabel;
        }
      NSString *inner =
          [_kkCategoryUnits(layerLanes) componentsJoinedByString:@", "];
      NSString *name = KKTruncatedLayerName(layerLabel);
      [layerStrings
          addObject:(inner.length
                         ? [NSString stringWithFormat:@"%@ > %@", name, inner]
                         : name)];
    }
    return [layerStrings componentsJoinedByString:@" | "];
  }

  // No layers: category units joined by " | " when any category exists,
  // otherwise a flat comma list of bare lanes.
  BOOL hasCategories = NO;
  for (KKLane *l in lanes)
    if (l.categoryKey.length) {
      hasCategories = YES;
      break;
    }
  return [_kkCategoryUnits(lanes)
      componentsJoinedByString:(hasCategories ? @" | " : @", ")];
}

KKPillToggleRowView *KKMakeLaneCategoryPill(NSArray<KKLane *> *lanes,
                                            NSString *selected,
                                            void (^onSelect)(NSString *)) {
  NSArray<NSArray<NSString *> *> *cats = KKOrderedLaneCategories(lanes);
  if (cats.count < 1)
    return nil;

  NSMutableArray<NSString *> *keys = [NSMutableArray array];
  NSMutableArray<NSString *> *names = [NSMutableArray array];
  NSMutableArray<NSImage *> *icons = [NSMutableArray array];
  for (NSArray<NSString *> *pair in cats) {
    [keys addObject:pair[0]];
    [names addObject:KKLocalizedParamName(pair[0])];
    [icons addObject:KKCategorySymbolImage(pair[1], pair[0])];
  }
  NSString *sel = KKResolveLaneCategory(lanes, selected);
  NSUInteger selIdx = sel ? [keys indexOfObject:sel] : 0;
  if (selIdx == NSNotFound)
    selIdx = 0;

  KKPillToggleRowView *pill =
      [[KKPillToggleRowView alloc] initWithLabels:names icons:icons];
  pill.translatesAutoresizingMaskIntoConstraints = NO;
  pill.grouped = YES;
  pill.radioMode = YES;
  NSMutableArray<NSNumber *> *states = [NSMutableArray array];
  for (NSUInteger i = 0; i < keys.count; i++)
    [states addObject:@(i == selIdx)];
  pill.states = states;
  pill.onToggled = ^(NSInteger index, BOOL isOn) {
    if (!isOn || index < 0 || index >= (NSInteger)keys.count)
      return;
    if (onSelect)
      onSelect(keys[index]);
  };
  return pill;
}
