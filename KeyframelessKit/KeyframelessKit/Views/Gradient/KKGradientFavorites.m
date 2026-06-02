/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKGradientFavorites.h"

static NSString *const kFileName = @"gradient_favorites.json";

static NSURL *_favoritesFileURL(void) {
  NSArray<NSString *> *paths = NSSearchPathForDirectoriesInDomains(
      NSApplicationSupportDirectory, NSUserDomainMask, YES);
  if (paths.count == 0)
    return nil;
  NSString *dir =
      [paths.firstObject stringByAppendingPathComponent:@"Keyframeless"];
  [[NSFileManager defaultManager] createDirectoryAtPath:dir
                            withIntermediateDirectories:YES
                                             attributes:nil
                                                  error:nil];
  return [NSURL fileURLWithPath:[dir stringByAppendingPathComponent:kFileName]];
}

static NSArray<NSDictionary *> *
_stopsToArray(NSArray<KKGradientStop *> *stops) {
  NSMutableArray *arr = [NSMutableArray new];
  for (KKGradientStop *s in stops) {
    CGFloat r = 0, g = 0, b = 0, a = 0;
    NSColor *c = [s.color colorUsingColorSpace:[NSColorSpace sRGBColorSpace]];
    if (c)
      [c getRed:&r green:&g blue:&b alpha:&a];
    else
      [s.color getRed:&r green:&g blue:&b alpha:&a];
    [arr addObject:@{
      @"p" : @((double)s.position),
      @"r" : @((double)r),
      @"g" : @((double)g),
      @"b" : @((double)b),
      @"m" : @((double)s.midpoint)
    }];
  }
  return arr;
}

static NSArray<KKGradientStop *> *_arrayToStops(NSArray<NSDictionary *> *arr) {
  NSMutableArray<KKGradientStop *> *stops = [NSMutableArray new];
  for (NSDictionary *d in arr) {
    if (![d isKindOfClass:[NSDictionary class]])
      continue;
    CGFloat midpoint = d[@"m"] ? [d[@"m"] doubleValue] : 0.5;
    [stops addObject:[KKGradientStop
                         stopWithPosition:[d[@"p"] doubleValue]
                                    color:[NSColor
                                              colorWithRed:[d[@"r"] doubleValue]
                                                     green:[d[@"g"] doubleValue]
                                                      blue:[d[@"b"] doubleValue]
                                                     alpha:1.0]
                                 midpoint:midpoint]];
  }
  return stops;
}

@implementation KKGradientFavorite

+ (instancetype)favoriteWithName:(NSString *)name
                           stops:(NSArray<KKGradientStop *> *)stops {
  KKGradientFavorite *fav = [[KKGradientFavorite alloc] init];
  fav.identifier = [[NSUUID UUID] UUIDString];
  fav.name = name;
  fav.stops = stops;
  return fav;
}

@end

@implementation KKGradientFavorites {
  NSMutableArray<KKGradientFavorite *> *_items;
}

+ (instancetype)shared {
  static KKGradientFavorites *instance;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[KKGradientFavorites alloc] init];
  });
  return instance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _items = [NSMutableArray new];
    [self _load];
  }
  return self;
}

- (NSArray<KKGradientFavorite *> *)favorites {
  return [_items sortedArrayUsingComparator:^(KKGradientFavorite *a,
                                              KKGradientFavorite *b) {
    return [a.name localizedCaseInsensitiveCompare:b.name];
  }];
}

- (void)addFavoriteWithName:(NSString *)name
                      stops:(NSArray<KKGradientStop *> *)stops {
  KKGradientFavorite *fav = [KKGradientFavorite favoriteWithName:name
                                                           stops:stops];
  [_items addObject:fav];
  [self _save];
}

- (void)removeFavoriteWithIdentifier:(NSString *)identifier {
  NSUInteger idx = [_items
      indexOfObjectPassingTest:^(KKGradientFavorite *f, NSUInteger i, BOOL *s) {
        return [f.identifier isEqualToString:identifier];
      }];
  if (idx != NSNotFound) {
    [_items removeObjectAtIndex:idx];
    [self _save];
  }
}

- (void)renameFavoriteWithIdentifier:(NSString *)identifier
                              toName:(NSString *)name {
  for (KKGradientFavorite *f in _items) {
    if ([f.identifier isEqualToString:identifier]) {
      f.name = name;
      [self _save];
      return;
    }
  }
}

- (void)updateFavoriteWithIdentifier:(NSString *)identifier
                               stops:(NSArray<KKGradientStop *> *)stops {
  for (KKGradientFavorite *f in _items) {
    if ([f.identifier isEqualToString:identifier]) {
      f.stops = [stops copy];
      [self _save];
      return;
    }
  }
}

- (void)_load {
  NSURL *url = _favoritesFileURL();
  if (!url)
    return;
  NSData *data = [NSData dataWithContentsOfURL:url];
  if (!data)
    return;
  NSArray *arr = [NSJSONSerialization JSONObjectWithData:data
                                                 options:0
                                                   error:nil];
  if (![arr isKindOfClass:[NSArray class]])
    return;
  for (NSDictionary *d in arr) {
    if (![d isKindOfClass:[NSDictionary class]])
      continue;
    NSString *identifier = d[@"id"];
    NSString *name = d[@"name"];
    NSArray *stopsArr = d[@"stops"];
    if (!identifier || !name || !stopsArr)
      continue;
    NSArray<KKGradientStop *> *stops = _arrayToStops(stopsArr);
    if (stops.count < 2)
      continue;
    KKGradientFavorite *fav = [[KKGradientFavorite alloc] init];
    fav.identifier = identifier;
    fav.name = name;
    fav.stops = stops;
    [_items addObject:fav];
  }
}

- (void)_save {
  NSURL *url = _favoritesFileURL();
  if (!url)
    return;
  NSMutableArray *arr = [NSMutableArray new];
  for (KKGradientFavorite *f in _items) {
    [arr addObject:@{
      @"id" : f.identifier,
      @"name" : f.name,
      @"stops" : _stopsToArray(f.stops)
    }];
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:arr
                                                 options:0
                                                   error:nil];
  if (data)
    [data writeToURL:url atomically:YES];
}

@end
