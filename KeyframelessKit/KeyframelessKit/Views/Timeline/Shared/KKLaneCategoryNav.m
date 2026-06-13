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
  if (keys.count < 2)
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
      byLabel[lane.label] = lane.categoryKey;
  return byLabel;
}

NSString *KKResolveLaneCategory(NSArray<KKLane *> *lanes, NSString *requested) {
  NSArray<NSArray<NSString *> *> *cats = KKOrderedLaneCategories(lanes);
  if (cats.count < 2)
    return nil;
  if (requested.length)
    for (NSArray<NSString *> *pair in cats)
      if ([pair[0] isEqualToString:requested])
        return requested;
  return cats.firstObject[0];
}

NSImage *KKCategorySymbolImage(NSString *symbolName,
                               NSString *accessibilityKey) {
  NSImage *img = [NSImage imageWithSystemSymbolName:symbolName
                           accessibilityDescription:accessibilityKey];
  return img ?: [[NSImage alloc] initWithSize:NSMakeSize(11, 11)];
}

KKPillToggleRowView *KKMakeLaneCategoryPill(NSArray<KKLane *> *lanes,
                                            NSString *selected,
                                            void (^onSelect)(NSString *)) {
  NSArray<NSArray<NSString *> *> *cats = KKOrderedLaneCategories(lanes);
  if (cats.count < 2)
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
