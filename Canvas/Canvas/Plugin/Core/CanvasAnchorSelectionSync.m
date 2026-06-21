/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasAnchorSelectionSync.h"

// Shared with the mini-viewer feed files (same /tmp convention, cross-process).
static NSString *const kSelectionSyncPath = @"/tmp/canvas-anchorsel.json";

static NSDictionary *ReadSelectionFile(void) {
  NSData *data = [NSData dataWithContentsOfFile:kSelectionSyncPath];
  if (!data.length)
    return nil;
  id obj = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
  return [obj isKindOfClass:[NSDictionary class]] ? obj : nil;
}

void CanvasPublishAnchorSelection(NSString *writerTag, NSString *layerID,
                                  NSIndexSet *indices) {
  if (!writerTag.length)
    return;
  // Monotonic generation: read the current value and bump it, so the other
  // surface can tell a newer publish from one it already applied.
  long long gen = 0;
  NSDictionary *cur = ReadSelectionFile();
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
  NSData *data = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
  [data writeToFile:kSelectionSyncPath atomically:YES];
}

NSIndexSet *CanvasConsumeAnchorSelection(NSString *readerTag, NSString *layerID) {
  if (!readerTag.length)
    return nil;
  // Per-reader high-water mark of the generation already applied.
  static NSMutableDictionary<NSString *, NSNumber *> *seen;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    seen = [NSMutableDictionary dictionary];
  });

  NSDictionary *cur = ReadSelectionFile();
  if (!cur)
    return nil;
  NSString *writer = cur[@"writer"];
  if ([writer isEqualToString:readerTag])
    return nil; // our own write
  if (![cur[@"layer"] isEqualToString:(layerID ?: @"")])
    return nil; // a different layer's selection
  long long gen =
      [cur[@"gen"] isKindOfClass:[NSNumber class]] ? [cur[@"gen"] longLongValue]
                                                   : 0;
  long long lastSeen = [seen[readerTag] longLongValue];
  if (gen <= lastSeen)
    return nil; // already applied
  seen[readerTag] = @(gen);

  NSArray *idx = cur[@"idx"];
  if (![idx isKindOfClass:[NSArray class]])
    return [NSIndexSet indexSet];
  NSMutableIndexSet *set = [NSMutableIndexSet indexSet];
  for (NSNumber *n in idx)
    if ([n isKindOfClass:[NSNumber class]])
      [set addIndex:n.unsignedIntegerValue];
  return set;
}
