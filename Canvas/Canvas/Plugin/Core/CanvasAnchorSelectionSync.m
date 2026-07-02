/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasAnchorSelectionSync.h"

// Shared with the mini-viewer feed files (same /tmp convention, cross-process).
// Per-instance path keyed by the instance UUID so two stacked (or copy/pasted)
// Canvas clips don't share one file; empty UUID falls back to the static path.
static NSString *const kSelectionSyncPath = @"/tmp/canvas-anchorsel.json";

static NSString *SelectionSyncPathForUUID(NSString *uuid) {
  if (!uuid.length)
    return kSelectionSyncPath;
  return [NSString stringWithFormat:@"/tmp/canvas-anchorsel-%@.json", uuid];
}

static NSDictionary *ReadSelectionFile(NSString *uuid) {
  NSData *data = [NSData dataWithContentsOfFile:SelectionSyncPathForUUID(uuid)];
  if (!data.length)
    return nil;
  id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

void CanvasPublishAnchorSelection(NSString *uuid, NSString *writerTag,
                                  NSString *layerID, NSIndexSet *indices) {
  if (!writerTag.length)
    return;
  // Monotonic generation: read the current value and bump it, so the other
  // surface can tell a newer publish from one it already applied.
  long long gen = 0;
  NSDictionary *cur = ReadSelectionFile(uuid);
  if ([cur[@"gen"] isKindOfClass:[NSNumber class]])
    gen = [cur[@"gen"] longLongValue];
  gen += 1;

  NSMutableArray<NSNumber *> *idx = [NSMutableArray array];
  [indices enumerateIndexesUsingBlock:^(NSUInteger i, BOOL *stop) {
    [idx addObject:@(i)];
  }];
  NSDictionary *out = @{
    @"writer" : writerTag,
    @"gen" : @(gen),
    @"layer" : layerID ?: @"",
    @"idx" : idx,
  };
  NSData *data = [NSJSONSerialization dataWithJSONObject:out
                                                 options:0
                                                   error:nil];
  [data writeToFile:SelectionSyncPathForUUID(uuid) atomically:YES];
}

NSIndexSet *CanvasConsumeAnchorSelection(NSString *uuid, NSString *readerTag,
                                         NSString *layerID) {
  if (!readerTag.length)
    return nil;
  // Per-reader high-water mark of the generation already applied. Keyed by
  // (uuid, readerTag): the ViewBridge process is shared across instances, so a
  // bare "mini"/"osc" key would let one clip's gen suppress another's.
  static NSMutableDictionary<NSString *, NSNumber *> *seen;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    seen = [NSMutableDictionary dictionary];
  });
  NSString *seenKey =
      [NSString stringWithFormat:@"%@:%@", uuid ?: @"", readerTag];

  NSDictionary *cur = ReadSelectionFile(uuid);
  if (!cur)
    return nil;
  NSString *writer = cur[@"writer"];
  if ([writer isEqualToString:readerTag])
    return nil; // our own write
  if (![cur[@"layer"] isEqualToString:(layerID ?: @"")])
    return nil; // a different layer's selection
  long long gen = [cur[@"gen"] isKindOfClass:[NSNumber class]]
                      ? [cur[@"gen"] longLongValue]
                      : 0;
  long long lastSeen = [seen[seenKey] longLongValue];
  if (gen <= lastSeen)
    return nil; // already applied
  seen[seenKey] = @(gen);

  NSArray *idx = cur[@"idx"];
  if (![idx isKindOfClass:[NSArray class]])
    return [NSIndexSet indexSet];
  NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
  for (NSNumber *n in idx)
    if ([n isKindOfClass:[NSNumber class]])
      [set addIndex:n.unsignedIntegerValue];
  return set;
}
