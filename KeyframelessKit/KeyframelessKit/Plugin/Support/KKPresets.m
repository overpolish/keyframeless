/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKPresets.h"

#import "KKLocalized.h"

static NSString *const kFileName = @"presets.json";
// Bundled built-ins for every plugin, keyed by plugin key (the plugin's bundle
// identifier). One flat file so the lookup is robust to any bundle id - Xcode
// flattens resources to the framework bundle root.
static NSString *const kBuiltinResource = @"builtin_presets";

static NSURL *_presetsFileURL(void) {
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

@implementation KKPreset

- (NSString *)displayName {
  if (!_builtin)
    return _name;
  // Built-in names are stable English keys in the KKLocalizable table.
  return NSLocalizedStringFromTableInBundle(_name, @"KKLocalizable",
                                            KKLocalizationBundle(), nil)
             ?: _name;
}

@end

@implementation KKPresets {
  NSMutableArray<KKPreset *> *_userItems;
  // Built-ins are loaded once per plugin key and cached.
  NSMutableDictionary<NSString *, NSArray<KKPreset *> *> *_builtinsByPlugin;
  // The parsed builtin_presets.json root (pluginKey -> array of entries),
  // loaded lazily once.
  NSDictionary *_builtinRoot;
  BOOL _builtinRootLoaded;
}

+ (instancetype)shared {
  static KKPresets *instance;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[KKPresets alloc] init];
  });
  return instance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _userItems = [NSMutableArray new];
    _builtinsByPlugin = [NSMutableDictionary new];
    [self _load];
  }
  return self;
}

- (NSArray<KKPreset *> *)presetsForPluginKey:(NSString *)pluginKey {
  NSComparator byName = ^(KKPreset *a, KKPreset *b) {
    return [a.displayName localizedCaseInsensitiveCompare:b.displayName];
  };

  NSArray<KKPreset *> *builtins = [[self _builtinsForPluginKey:pluginKey]
      sortedArrayUsingComparator:byName];

  NSMutableArray<KKPreset *> *userMatches = [NSMutableArray new];
  for (KKPreset *p in _userItems)
    if ([p.pluginKey isEqualToString:pluginKey])
      [userMatches addObject:p];
  [userMatches sortUsingComparator:byName];

  NSMutableArray<KKPreset *> *all = [NSMutableArray new];
  [all addObjectsFromArray:builtins];
  [all addObjectsFromArray:userMatches];
  return all;
}

- (KKPreset *)addPresetWithName:(NSString *)name
                      pluginKey:(NSString *)pluginKey
                   timelineJSON:(NSString *)timelineJSON {
  KKPreset *p = [[KKPreset alloc] init];
  p.identifier = [[NSUUID UUID] UUIDString];
  p.name = name;
  p.pluginKey = pluginKey;
  p.timelineJSON = timelineJSON;
  p.builtin = NO;
  [_userItems addObject:p];
  [self _save];
  return p;
}

- (void)removePresetWithIdentifier:(NSString *)identifier {
  NSUInteger idx = [self _userIndexForIdentifier:identifier];
  if (idx != NSNotFound) {
    [_userItems removeObjectAtIndex:idx];
    [self _save];
  }
}

- (void)renamePresetWithIdentifier:(NSString *)identifier
                            toName:(NSString *)name {
  NSUInteger idx = [self _userIndexForIdentifier:identifier];
  if (idx != NSNotFound) {
    _userItems[idx].name = name;
    [self _save];
  }
}

- (void)updatePresetWithIdentifier:(NSString *)identifier
                      timelineJSON:(NSString *)timelineJSON {
  NSUInteger idx = [self _userIndexForIdentifier:identifier];
  if (idx != NSNotFound) {
    _userItems[idx].timelineJSON = timelineJSON;
    [self _save];
  }
}

- (NSUInteger)_userIndexForIdentifier:(NSString *)identifier {
  return [_userItems
      indexOfObjectPassingTest:^(KKPreset *p, NSUInteger i, BOOL *stop) {
        return [p.identifier isEqualToString:identifier];
      }];
}

- (NSArray<KKPreset *> *)_builtinsForPluginKey:(NSString *)pluginKey {
  NSArray<KKPreset *> *cached = _builtinsByPlugin[pluginKey];
  if (cached)
    return cached;

  if (!_builtinRootLoaded) {
    _builtinRootLoaded = YES;
    NSURL *url = [KKLocalizationBundle() URLForResource:kBuiltinResource
                                          withExtension:@"json"];
    NSData *data = url ? [NSData dataWithContentsOfURL:url] : nil;
    id root = data ? [NSJSONSerialization JSONObjectWithData:data
                                                     options:0
                                                       error:nil]
                   : nil;
    if ([root isKindOfClass:[NSDictionary class]])
      _builtinRoot = root;
  }

  NSMutableArray<KKPreset *> *items = [NSMutableArray new];
  NSArray *arr = _builtinRoot[pluginKey];
  if ([arr isKindOfClass:[NSArray class]]) {
    for (NSDictionary *d in arr) {
      if (![d isKindOfClass:[NSDictionary class]])
        continue;
      NSString *identifier = d[@"id"];
      NSString *name = d[@"name"];
      // `timeline` may be an embedded JSON object (authorable) or an already
      // serialized string; normalize to a string.
      NSString *timeline = nil;
      id timelineVal = d[@"timeline"];
      if ([timelineVal isKindOfClass:[NSString class]]) {
        timeline = timelineVal;
      } else if ([timelineVal isKindOfClass:[NSDictionary class]]) {
        NSData *td = [NSJSONSerialization dataWithJSONObject:timelineVal
                                                     options:0
                                                       error:nil];
        timeline = td ? [[NSString alloc] initWithData:td
                                              encoding:NSUTF8StringEncoding]
                      : nil;
      }
      if (!identifier.length || !name.length || !timeline.length)
        continue;
      KKPreset *p = [[KKPreset alloc] init];
      p.identifier = identifier;
      p.name = name;
      p.pluginKey = pluginKey;
      p.timelineJSON = timeline;
      p.builtin = YES;
      [items addObject:p];
    }
  }
  _builtinsByPlugin[pluginKey] = items;
  return items;
}

- (void)_load {
  NSURL *url = _presetsFileURL();
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
    NSString *pluginKey = d[@"pluginKey"];
    NSString *timeline = d[@"timeline"];
    if (!identifier.length || !name.length || !pluginKey.length ||
        !timeline.length)
      continue;
    KKPreset *p = [[KKPreset alloc] init];
    p.identifier = identifier;
    p.name = name;
    p.pluginKey = pluginKey;
    p.timelineJSON = timeline;
    p.builtin = NO;
    [_userItems addObject:p];
  }
}

- (void)_save {
  NSURL *url = _presetsFileURL();
  if (!url)
    return;
  NSMutableArray *arr = [NSMutableArray new];
  for (KKPreset *p in _userItems) {
    [arr addObject:@{
      @"id" : p.identifier,
      @"name" : p.name,
      @"pluginKey" : p.pluginKey,
      @"timeline" : p.timelineJSON
    }];
  }
  NSData *data = [NSJSONSerialization dataWithJSONObject:arr
                                                 options:0
                                                   error:nil];
  if (data)
    [data writeToURL:url atomically:YES];
}

@end
