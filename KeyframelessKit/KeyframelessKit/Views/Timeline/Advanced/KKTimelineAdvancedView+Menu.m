/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKKeyposeClipboard.h"
#import "KKLocalized.h"
#import "KKTimelineAdvancedView_Private.h"

#import "KKTimelineScrubMath.h"
#import <KeyframelessKit/KKTimingEvaluation.h>

@implementation KKTimelineAdvancedView (Menu)

- (NSMenu *)menuForEvent:(NSEvent *)event {
  if (_interactionsBlocked)
    return nil;
  NSPoint pt = [self convertPoint:event.locationInWindow fromView:nil];
  _menuPillLabel = nil;
  _menuPillKPIdx = -1;
  _menuGapLabel = nil;
  _menuGapAIdx = -1;
  _menuGapLaneRow = -1;
  _menuGapFrac = 0.0;
  NSInteger laneIdx = -1, kpIdx = -1;
  BOOL hitPill = [self _pillAtPoint:pt lane:&laneIdx kp:&kpIdx];
  NSArray<KKLane *> *anim = [self _animatableLanes];
  if (hitPill && laneIdx < (NSInteger)anim.count) {
    _menuPillLabel = [anim[laneIdx].label copy];
    _menuPillKPIdx = kpIdx;
  } else {
    NSInteger row = [self _laneRowAtPoint:pt];
    NSRect tracks = [self _tracksRect];
    if (row >= 0 && row < (NSInteger)anim.count && pt.x >= NSMinX(tracks) &&
        pt.x <= NSMaxX(tracks)) {
      double frac = [self _fracForX:pt.x inLane:anim[row] inTracks:tracks];
      NSInteger aIdx = [self _intervalStartKPIdxInLane:anim[row] atFrac:frac];
      _menuGapLabel = [anim[row].label copy];
      _menuGapAIdx = aIdx;
      _menuGapLaneRow = row;
      _menuGapFrac = frac;
    }
  }

  NSMenu *menu = [[NSMenu alloc] init];
  // Explicit enablement so a non-matching Paste can be greyed (the default
  // autoenable would keep it live because self responds to the action).
  menu.autoenablesItems = NO;
  NSArray<KKKeyposeClipboardEntry *> *clip = [KKKeyposeClipboard readEntries];
  BOOL hasSelection = _selection.count > 0;
  if (hasSelection) {
    [menu addItemWithTitle:KKLoc(@"Reverse", @"Context menu: reverse keyposes.")
                    action:@selector(_menuReverseSelection:)
             keyEquivalent:@""]
        .target = self;
    [menu addItemWithTitle:KKLoc(@"Distribute Evenly",
                                 @"Context menu: space keyposes evenly.")
                    action:@selector(_menuDistributeEvenly:)
             keyEquivalent:@""]
        .target = self;
    [menu addItem:[NSMenuItem separatorItem]];
    [self _addCopyPasteItemsToMenu:menu clip:clip];
    [menu addItem:[NSMenuItem separatorItem]];
    [menu addItemWithTitle:KKLoc(@"Delete", @"Context menu: delete.")
                    action:@selector(_menuDeleteSelection:)
             keyEquivalent:@""]
        .target = self;
  } else if (_menuPillLabel) {
    [menu addItemWithTitle:KKLoc(@"Remove Keypose",
                                 @"Context menu: remove keypose.")
                    action:@selector(_menuRemovePill:)
             keyEquivalent:@""]
        .target = self;
    [menu addItem:[NSMenuItem separatorItem]];
    [self _addCopyPasteItemsToMenu:menu clip:clip];
  } else if (_menuGapLabel) {
    [menu addItemWithTitle:KKLoc(@"Add Keypose Here",
                                 @"Context menu: add keypose.")
                    action:@selector(_menuAddKeyposeAtGap:)
             keyEquivalent:@""]
        .target = self;
    if (_menuGapAIdx >= 0) {
      KKLane *gapLane = nil;
      for (KKLane *l in anim)
        if ([l.label isEqualToString:_menuGapLabel]) {
          gapLane = l;
          break;
        }
      KKInterval *iv =
          (gapLane && _menuGapAIdx + 1 < (NSInteger)gapLane.keyposes.count)
              ? gapLane.keyposes[_menuGapAIdx].outgoing
              : nil;
      if (iv) {
        [menu addItem:[NSMenuItem separatorItem]];
        NSString *title =
            iv.endpointsLinked
                ? KKLoc(@"Unlink Endpoints", @"Context menu: unlink endpoints.")
                : KKLoc(@"Link Endpoints", @"Context menu: link endpoints.");
        [menu addItemWithTitle:title
                        action:@selector(_menuToggleGapLink:)
                 keyEquivalent:@""]
            .target = self;
      }
    }
  } else {
    return nil;
  }
  return menu;
}

// Copy is single-keypose only (one value, one lane); with a multi-selection it
// is omitted entirely - per the design, you copy one value and paste it onto
// many. Paste is always shown but greyed unless the clipboard holds an entry
// whose lane (label + valueType + component count) matches a target keypose.
- (void)_addCopyPasteItemsToMenu:(NSMenu *)menu
                            clip:(NSArray<KKKeyposeClipboardEntry *> *)clip {
  NSString *cLabel;
  NSInteger cKP;
  if ([self _singleCopyTargetLabel:&cLabel kpIdx:&cKP])
    [menu addItemWithTitle:KKLoc(@"Copy Values",
                                 @"Context menu: copy keypose values.")
                    action:@selector(_menuCopyValue:)
             keyEquivalent:@""]
        .target = self;
  NSMenuItem *paste =
      [menu addItemWithTitle:KKLoc(@"Paste Values",
                                   @"Context menu: paste keypose values.")
                      action:@selector(_menuPasteValue:)
               keyEquivalent:@""];
  paste.target = self;
  paste.enabled = [self _canPasteEntries:clip];
}

// The single keypose a Copy would capture: the lone selected pill, or - with no
// selection - the right-clicked pill. nil when 2+ are selected.
- (BOOL)_singleCopyTargetLabel:(NSString *_Nullable *_Nullable)outLabel
                         kpIdx:(NSInteger *_Nullable)outKP {
  if (_selection.count == 1)
    return [self _decodeSelectionKey:_selection.anyObject
                               label:outLabel
                               kpIdx:outKP];
  if (_selection.count == 0 && _menuPillLabel) {
    if (outLabel)
      *outLabel = _menuPillLabel;
    if (outKP)
      *outKP = _menuPillKPIdx;
    return YES;
  }
  return NO;
}

// Selection keys a Paste would write to: every selected pill, or - with no
// selection - just the right-clicked pill.
- (NSArray<NSString *> *)_pasteTargetSelectionKeys {
  if (_selection.count > 0)
    return _selection.allObjects;
  if (_menuPillLabel)
    return @[ [self _selectionKeyForLabel:_menuPillLabel
                                    kpIdx:_menuPillKPIdx] ];
  return @[];
}

- (BOOL)_canPasteEntries:(NSArray<KKKeyposeClipboardEntry *> *)entries {
  if (entries.count == 0)
    return NO;
  for (NSString *key in [self _pasteTargetSelectionKeys]) {
    NSString *label;
    NSInteger kp;
    if (![self _decodeSelectionKey:key label:&label kpIdx:&kp])
      continue;
    KKLane *lane = [self _animatableLaneForLabel:label];
    if (!lane)
      continue;
    for (KKKeyposeClipboardEntry *e in entries)
      if ([e matchesLane:lane])
        return YES;
  }
  return NO;
}

- (void)_menuCopyValue:(id)sender {
  NSString *label;
  NSInteger kpIdx;
  if (![self _singleCopyTargetLabel:&label kpIdx:&kpIdx])
    return;
  KKLane *lane = [self _animatableLaneForLabel:label];
  if (!lane || kpIdx < 0 || kpIdx >= (NSInteger)lane.keyposes.count)
    return;
  KKKeyposeClipboardEntry *e =
      [KKKeyposeClipboard entryForKeypose:lane.keyposes[kpIdx] lane:lane];
  [KKKeyposeClipboard writeEntries:@[ e ]];
}

- (void)_menuPasteValue:(id)sender {
  NSArray<KKKeyposeClipboardEntry *> *entries =
      [KKKeyposeClipboard readEntries];
  if (entries.count == 0)
    return;

  // Group target indices per lane so each lane is rewritten in one pass.
  NSMutableDictionary<NSString *, NSMutableIndexSet *> *byLane =
      [NSMutableDictionary dictionary];
  for (NSString *key in [self _pasteTargetSelectionKeys]) {
    NSString *label;
    NSInteger kp;
    if (![self _decodeSelectionKey:key label:&label kpIdx:&kp] || kp < 0)
      continue;
    NSMutableIndexSet *s = byLane[label];
    if (!s) {
      s = [NSMutableIndexSet indexSet];
      byLane[label] = s;
    }
    [s addIndex:(NSUInteger)kp];
  }

  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  BOOL changed = NO;
  for (NSString *label in byLane) {
    NSInteger li = -1;
    for (NSInteger i = 0; i < (NSInteger)lanes.count; i++)
      if ([lanes[i].label isEqualToString:label]) {
        li = i;
        break;
      }
    if (li < 0)
      continue;
    KKLane *lane = lanes[li];
    KKKeyposeClipboardEntry *match = nil;
    for (KKKeyposeClipboardEntry *e in entries)
      if ([e matchesLane:lane]) {
        match = e;
        break;
      }
    if (!match)
      continue;
    NSMutableArray<KKKeyPose *> *kps = [lane.keyposes mutableCopy];
    __block BOOL laneChanged = NO;
    [byLane[label] enumerateIndexesUsingBlock:^(NSUInteger idx, BOOL *stop) {
      if (idx >= kps.count)
        return;
      kps[idx] = [match applyToKeypose:kps[idx]];
      laneChanged = YES;
      // Mirror the value (not the spatial handles - those are per-keypose path
      // tangents) across a linked-endpoint run, matching a manual value edit so
      // a Hold pasted on one side stays consistent.
      NSInteger k = (NSInteger)idx;
      while (k > 0 && kps[k - 1].outgoing.endpointsLinked) {
        KKKeyPose *nk = [kps[k - 1] copy];
        nk.values = match.values;
        nk.geometrySnapshot = match.geometrySnapshot; // geometry lane: mirror shape
        kps[k - 1] = nk;
        k--;
      }
      k = (NSInteger)idx;
      while (k + 1 < (NSInteger)kps.count && kps[k].outgoing.endpointsLinked) {
        KKKeyPose *nk = [kps[k + 1] copy];
        nk.values = match.values;
        nk.geometrySnapshot = match.geometrySnapshot; // geometry lane: mirror shape
        kps[k + 1] = nk;
        k++;
      }
    }];
    if (!laneChanged)
      continue;
    KKLane *nl = [lane copy];
    nl.keyposes = kps;
    lanes[li] = nl;
    changed = YES;
  }
  if (!changed)
    return;
  t.lanes = lanes;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

- (void)_menuToggleGapLink:(id)sender {
  if (_menuGapLabel && _menuGapAIdx >= 0)
    [self _toggleLinkForLabel:_menuGapLabel kpIdx:_menuGapAIdx];
}

- (void)_menuRemovePill:(id)sender {
  if (!_menuPillLabel)
    return;
  NSArray<KKLane *> *anim = [self _animatableLanes];
  NSInteger li = -1;
  for (NSInteger i = 0; i < (NSInteger)anim.count; i++)
    if ([anim[i].label isEqualToString:_menuPillLabel]) {
      li = i;
      break;
    }
  if (li >= 0)
    [self _removeKPInLaneIdx:li kpIdx:_menuPillKPIdx];
}

- (void)_menuAddKeyposeAtGap:(id)sender {
  if (_menuGapLaneRow < 0)
    return;
  [self _addAndOpenKPForLaneIdx:_menuGapLaneRow atFrac:_menuGapFrac];
}

- (void)_menuDeleteSelection:(id)sender {
  if (_selection.count > 0)
    [self _deleteSelectedKPs];
}

// Per-lane time-mirror around the lane's selection midpoint. Curves are NOT
// auto-flipped (user can tweak in the gap popover); times reversing alone is
// the natural "undo direction".
- (void)_menuReverseSelection:(id)sender {
  if (_selection.count == 0)
    return;
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  BOOL changed = NO;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    KKLane *src = lanes[i];
    if (!src.enabled)
      continue;
    NSMutableArray<NSNumber *> *selIdx = [NSMutableArray array];
    for (NSString *key in _selection) {
      NSString *kLabel;
      NSInteger kIdx;
      if (![self _decodeSelectionKey:key label:&kLabel kpIdx:&kIdx])
        continue;
      if (![kLabel isEqualToString:src.label])
        continue;
      [selIdx addObject:@(kIdx)];
    }
    if (selIdx.count < 2)
      continue;
    [selIdx sortUsingSelector:@selector(compare:)];
    NSMutableArray<KKKeyPose *> *kps = [src.keyposes mutableCopy];
    double minT = kps[selIdx.firstObject.integerValue].time;
    double maxT = kps[selIdx.lastObject.integerValue].time;
    double mid = (minT + maxT) * 0.5;
    for (NSNumber *n in selIdx) {
      NSInteger idx = n.integerValue;
      KKKeyPose *kp = kps[idx];
      double newT = 2.0 * mid - kp.time;
      KKKeyPose *moved = [kp keyposeBySettingTime:newT];
      kps[idx] = moved;
    }
    [kps sortUsingComparator:^NSComparisonResult(KKKeyPose *a, KKKeyPose *b) {
      return a.time < b.time   ? NSOrderedAscending
             : a.time > b.time ? NSOrderedDescending
                               : NSOrderedSame;
    }];
    KKLane *nl = [src copy];
    nl.keyposes = kps;
    lanes[i] = nl;
    changed = YES;
  }
  if (!changed)
    return;
  [_selection removeAllObjects];
  [_selectedGaps removeAllObjects];
  t.lanes = lanes;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

- (void)_menuDistributeEvenly:(id)sender {
  if (_selection.count < 3)
    return;
  KKTimeline *t = [_timeline copy];
  NSMutableArray<KKLane *> *lanes = [t.lanes mutableCopy];
  BOOL changed = NO;
  for (NSInteger i = 0; i < (NSInteger)lanes.count; i++) {
    KKLane *src = lanes[i];
    if (!src.enabled)
      continue;
    NSMutableArray<NSNumber *> *selIdx = [NSMutableArray array];
    for (NSString *key in _selection) {
      NSString *kLabel;
      NSInteger kIdx;
      if (![self _decodeSelectionKey:key label:&kLabel kpIdx:&kIdx])
        continue;
      if (![kLabel isEqualToString:src.label])
        continue;
      [selIdx addObject:@(kIdx)];
    }
    if (selIdx.count < 3)
      continue;
    [selIdx sortUsingSelector:@selector(compare:)];
    NSMutableArray<KKKeyPose *> *kps = [src.keyposes mutableCopy];
    double minT = kps[selIdx.firstObject.integerValue].time;
    double maxT = kps[selIdx.lastObject.integerValue].time;
    NSInteger n = (NSInteger)selIdx.count;
    for (NSInteger k = 1; k + 1 < n; k++) {
      NSInteger idx = selIdx[k].integerValue;
      KKKeyPose *kp = kps[idx];
      double newT = minT + (maxT - minT) * ((double)k / (double)(n - 1));
      newT =
          KKSnapFracToFrame(newT, [self _clipDuration], _frameDurationSeconds);
      KKKeyPose *moved = [kp keyposeBySettingTime:newT];
      kps[idx] = moved;
    }
    [kps sortUsingComparator:^NSComparisonResult(KKKeyPose *a, KKKeyPose *b) {
      return a.time < b.time   ? NSOrderedAscending
             : a.time > b.time ? NSOrderedDescending
                               : NSOrderedSame;
    }];
    KKLane *nl = [src copy];
    nl.keyposes = kps;
    lanes[i] = nl;
    changed = YES;
  }
  if (!changed)
    return;
  [_selection removeAllObjects];
  [_selectedGaps removeAllObjects];
  t.lanes = lanes;
  _timeline = t;
  [self setNeedsDisplay:YES];
  if (self.onTimelineMutated)
    self.onTimelineMutated(t);
}

@end
