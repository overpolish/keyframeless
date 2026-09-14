/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKScopedDefaults.h"

static NSString *const kSuiteName = @"group.com.keyframeless";
static NSString *const kKeyPrefix = @"KKScopedDefault.";
static NSString *const kFallbackScope = @"shared";

static NSLock *KKScopedDefaultsLock(void) {
  static NSLock *lock;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    lock = [[NSLock alloc] init];
  });
  return lock;
}

static NSString *_activeScope = nil;
static NSMutableDictionary<NSString *, id> *_cache = nil;
// Cached "nothing stored" marker, so a miss costs a dictionary lookup rather
// than a defaults read on every interval.
static NSString *const kMissMarker = @"<none>";

static NSUserDefaults *KKScopedDefaultsStore(void) {
  static NSUserDefaults *defaults;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    defaults = [[NSUserDefaults alloc] initWithSuiteName:kSuiteName]
                   ?: [NSUserDefaults standardUserDefaults];
    // Another process (the inspector's ViewBridge writing while the render
    // process holds a cached read) invalidates the cache through cfprefsd's
    // change notification.
    [[NSNotificationCenter defaultCenter]
        addObserverForName:NSUserDefaultsDidChangeNotification
                    object:nil
                     queue:nil
                usingBlock:^(NSNotification *note) {
                  NSLock *lock = KKScopedDefaultsLock();
                  [lock lock];
                  [_cache removeAllObjects];
                  [lock unlock];
                }];
  });
  return defaults;
}

void KKDefaultsSetActiveScope(NSString *scope) {
  NSLock *lock = KKScopedDefaultsLock();
  [lock lock];
  _activeScope = [scope copy];
  [lock unlock];
}

NSString *KKDefaultsActiveScope(void) {
  NSLock *lock = KKScopedDefaultsLock();
  [lock lock];
  NSString *scope = _activeScope ?: kFallbackScope;
  [lock unlock];
  return scope;
}

static NSString *KKScopedDefaultsKey(NSString *field, NSString *scope) {
  NSString *resolved = scope.length ? scope : KKDefaultsActiveScope();
  return [NSString stringWithFormat:@"%@%@.%@", kKeyPrefix, field, resolved];
}

id KKScopedDefaultRead(NSString *field, NSString *scope) {
  NSString *key = KKScopedDefaultsKey(field, scope);
  NSLock *lock = KKScopedDefaultsLock();
  [lock lock];
  id cached = _cache[key];
  [lock unlock];
  if (cached)
    return cached == kMissMarker ? nil : cached;

  id stored = [KKScopedDefaultsStore() objectForKey:key];
  [lock lock];
  if (!_cache)
    _cache = [NSMutableDictionary dictionary];
  _cache[key] = stored ?: kMissMarker;
  [lock unlock];
  return stored;
}

void KKScopedDefaultWrite(id value, NSString *field, NSString *scope) {
  NSString *key = KKScopedDefaultsKey(field, scope);
  if (value)
    [KKScopedDefaultsStore() setObject:value forKey:key];
  else
    [KKScopedDefaultsStore() removeObjectForKey:key];
  NSLock *lock = KKScopedDefaultsLock();
  [lock lock];
  if (!_cache)
    _cache = [NSMutableDictionary dictionary];
  _cache[key] = value ?: kMissMarker;
  [lock unlock];
}

NSUInteger KKScopedDefaultsCopyScope(NSString *fromScope, NSString *toScope) {
  if (!fromScope.length || !toScope.length ||
      [fromScope isEqualToString:toScope])
    return 0;
  // Field-agnostic: match on the key's scope suffix so a new kind of default
  // (added later, or a plugin's own) is carried over without touching this.
  NSString *fromSuffix = [@"." stringByAppendingString:fromScope];
  NSUInteger copied = 0;
  NSDictionary<NSString *, id> *all =
      [KKScopedDefaultsStore() dictionaryRepresentation];
  for (NSString *key in all) {
    if (![key hasPrefix:kKeyPrefix] || ![key hasSuffix:fromSuffix])
      continue;
    NSString *field = [key substringWithRange:
                               NSMakeRange(kKeyPrefix.length,
                                           key.length - kKeyPrefix.length -
                                               fromSuffix.length)];
    if (!field.length || KKScopedDefaultRead(field, toScope))
      continue; // the destination already has its own
    KKScopedDefaultWrite(all[key], field, toScope);
    copied++;
  }
  return copied;
}
