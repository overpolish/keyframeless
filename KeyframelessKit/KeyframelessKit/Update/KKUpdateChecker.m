/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKUpdateChecker.h"
#import "KKLog.h"
#import <AppKit/AppKit.h>

static NSString *const kOwner = @"overpolish";
static NSString *const kRepo = @"keyframeless";
static NSString *const kCachedVersionKey =
    @"co.overpolish.keyframeless.cachedAvailableVersion";
static NSString *const kCachedNewKeysKey =
    @"co.overpolish.keyframeless.cachedAvailableComponentKeys";
static NSString *const kCachedURLKey =
    @"co.overpolish.keyframeless.cachedDownloadURL";

static NSDictionary<NSString *, NSString *> *KKKnownComponents(void) {
  return @{
    @"keyframelessx" : @"Keyframeless X",
    @"rounded" : @"Rounded",
    @"motionblur" : @"MotionBlur",
    @"magicmove" : @"MagicMove",
    @"glow" : @"Glow"
  };
}

static NSDictionary<NSString *, NSString *> *KKBundleIDToComponent(void) {
  return @{
    @"co.overpolish.keyframeless.Keyframeless-X" : @"keyframelessx",
    @"co.overpolish.keyframeless.Keyframeless-X.Keyframeless-X-FCP" :
        @"keyframelessx",
    @"MotionBlur" : @"motionblur",
    @"MotionBlur-XPC-Service" : @"motionblur",
    @"Rounded" : @"rounded",
    @"Rounded-XPC-Service" : @"rounded",
    @"MagicMove" : @"magicmove",
    @"MagicMove-XPC-Service" : @"magicmove",
    @"Glow" : @"glow",
    @"Glow-XPC-Service" : @"glow"
  };
}

@implementation KKUpdateChecker {
  KKLog *_log;
  NSString *_componentKey;
  BOOL _checkedThisSession;
}

+ (instancetype)shared {
  static KKUpdateChecker *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[KKUpdateChecker alloc] init];
  });
  return instance;
}

+ (nullable NSString *)displayNameForComponent:(NSString *)componentID {
  return KKKnownComponents()[componentID];
}

- (instancetype)init {
  self = [super init];
  if (self) {
    _log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless.updateChecker"];

    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    _componentKey = KKBundleIDToComponent()[bundleID];
    if (!_componentKey) {
      [_log warn:@"Unknown bundle identifier: %@", bundleID];
    }

    _currentVersion =
        [[NSBundle mainBundle]
            objectForInfoDictionaryKey:@"CFBundleShortVersionString"]
            ?: @"0.0.0";

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    _availableVersion = [defaults stringForKey:kCachedVersionKey];
    _availableComponentKeys = [defaults arrayForKey:kCachedNewKeysKey] ?: @[];
    NSString *cachedURL = [defaults stringForKey:kCachedURLKey];
    if (cachedURL) {
      _downloadURL = [NSURL URLWithString:cachedURL];
    }
    // Validate cached version against current — clear stale cache from
    // pre-update
    if (_availableVersion && ![self isVersion:_availableVersion
                                    newerThan:_currentVersion]) {
      _availableVersion = nil;
      _availableComponentKeys = @[];
      _downloadURL = nil;
      [defaults removeObjectForKey:kCachedVersionKey];
      [defaults removeObjectForKey:kCachedNewKeysKey];
      [defaults removeObjectForKey:kCachedURLKey];
    }

    _updateAvailable =
        _availableVersion != nil || _availableComponentKeys.count > 0;
  }
  return self;
}

- (void)checkWithCompletion:(void (^)(BOOL))completion {
  if (_checkedThisSession) {
    [_log debug:@"Skipping update check — already checked this session"];
    if (completion) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(self.updateAvailable);
      });
    }
    return;
  }

  _checkedThisSession = YES;
  [self fetchManifestWithCompletion:completion];
}

- (void)forceCheckWithCompletion:(void (^)(BOOL))completion {
  [self fetchManifestWithCompletion:completion];
}

- (void)fetchManifestWithCompletion:(void (^)(BOOL))completion {
  NSString *urlString = [NSString
      stringWithFormat:@"https://api.github.com/repos/%@/%@/releases/latest",
                       kOwner, kRepo];
  NSURL *url = [NSURL URLWithString:urlString];
  NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url];
  [request setValue:@"application/vnd.github+json"
      forHTTPHeaderField:@"Accept"];
  [request setValue:@"2022-11-28" forHTTPHeaderField:@"X-GitHub-Api-Version"];

  [_log info:@"Checking for updates…"];

  NSURLSessionDataTask *task = [[NSURLSession sharedSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response,
                            NSError *error) {
          if (error) {
            [self->_log
                warn:@"Update check failed: %@", error.localizedDescription];
            [self callCompletion:completion];
            return;
          }

          NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
          if (http.statusCode != 200) {
            [self->_log
                warn:@"Update check got HTTP %ld", (long)http.statusCode];
            [self clearCacheAndComplete:completion];
            return;
          }

          NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                               options:0
                                                                 error:nil];
          NSArray *assets = json[@"assets"];
          if (![assets isKindOfClass:[NSArray class]]) {
            [self->_log warn:@"No assets array in release response"];
            [self clearCacheAndComplete:completion];
            return;
          }

          NSString *htmlURL = json[@"html_url"];

          NSURL *manifestURL = nil;
          for (NSDictionary *asset in assets) {
            if ([asset[@"name"] isEqualToString:@"manifest.json"]) {
              NSString *assetURL = asset[@"browser_download_url"];
              if (assetURL) {
                manifestURL = [NSURL URLWithString:assetURL];
              }
              break;
            }
          }

          if (!manifestURL) {
            [self->_log warn:@"No manifest.json asset found in release"];
            [self clearCacheAndComplete:completion];
            return;
          }

          [self downloadManifest:manifestURL
                      releaseURL:htmlURL
                      completion:completion];
        }];
  [task resume];
}

- (void)downloadManifest:(NSURL *)manifestURL
              releaseURL:(NSString *)releaseURL
              completion:(void (^)(BOOL))completion {
  NSMutableURLRequest *request =
      [NSMutableURLRequest requestWithURL:manifestURL];

  NSURLSessionDataTask *task = [[NSURLSession sharedSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response,
                            NSError *error) {
          if (error) {
            [self->_log warn:@"Manifest download failed: %@",
                             error.localizedDescription];
            [self callCompletion:completion];
            return;
          }

          NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
          if (http.statusCode != 200) {
            [self->_log
                warn:@"Manifest download got HTTP %ld", (long)http.statusCode];
            [self clearCacheAndComplete:completion];
            return;
          }

          NSDictionary *manifest = [NSJSONSerialization JSONObjectWithData:data
                                                                   options:0
                                                                     error:nil];
          if (![manifest isKindOfClass:[NSDictionary class]]) {
            [self->_log warn:@"Failed to parse manifest.json"];
            [self clearCacheAndComplete:completion];
            return;
          }

          [self processManifest:manifest
                     releaseURL:releaseURL
                     completion:completion];
        }];
  [task resume];
}

- (void)processManifest:(NSDictionary *)manifest
             releaseURL:(NSString *)releaseURL
             completion:(void (^)(BOOL))completion {
  NSDictionary<NSString *, NSString *> *known = KKKnownComponents();

  NSString *newerVersion = nil;
  if (_componentKey) {
    NSString *manifestVersion = manifest[_componentKey];
    if ([manifestVersion isKindOfClass:[NSString class]] &&
        [self isVersion:manifestVersion newerThan:_currentVersion]) {
      [_log info:@"Update available for %@: %@ -> %@", _componentKey,
                 _currentVersion, manifestVersion];
      newerVersion = manifestVersion;
    } else {
      [_log debug:@"%@ is up to date (%@)", _componentKey, _currentVersion];
    }
  }

  NSMutableArray<NSString *> *newKeys = [NSMutableArray array];
  for (NSString *key in manifest) {
    if (![manifest[key] isKindOfClass:[NSString class]])
      continue;
    if (!known[key]) {
      [_log info:@"New component in manifest: %@", key];
      [newKeys addObject:key];
    }
  }

  BOOL hasUpdate = newerVersion != nil || newKeys.count > 0;

  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

  if (hasUpdate) {
    if (newerVersion) {
      [defaults setObject:newerVersion forKey:kCachedVersionKey];
    } else {
      [defaults removeObjectForKey:kCachedVersionKey];
    }
    [defaults setObject:[newKeys copy] forKey:kCachedNewKeysKey];
    if (releaseURL) {
      [defaults setObject:releaseURL forKey:kCachedURLKey];
    }
  } else {
    [defaults removeObjectForKey:kCachedVersionKey];
    [defaults removeObjectForKey:kCachedNewKeysKey];
    [defaults removeObjectForKey:kCachedURLKey];
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    self->_availableVersion = newerVersion;
    self->_availableComponentKeys = [newKeys copy];
    self->_updateAvailable = hasUpdate;
    self->_downloadURL =
        hasUpdate && releaseURL ? [NSURL URLWithString:releaseURL] : nil;
    if (completion)
      completion(hasUpdate);
  });
}

- (void)callCompletion:(void (^)(BOOL))completion {
  dispatch_async(dispatch_get_main_queue(), ^{
    if (completion)
      completion(self.updateAvailable);
  });
}

- (void)clearCacheAndComplete:(void (^)(BOOL))completion {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  [defaults removeObjectForKey:kCachedVersionKey];
  [defaults removeObjectForKey:kCachedNewKeysKey];
  [defaults removeObjectForKey:kCachedURLKey];

  dispatch_async(dispatch_get_main_queue(), ^{
    self->_availableVersion = nil;
    self->_availableComponentKeys = @[];
    self->_updateAvailable = NO;
    self->_downloadURL = nil;
    if (completion)
      completion(NO);
  });
}

- (BOOL)isVersion:(nullable NSString *)a newerThan:(nullable NSString *)b {
  if (!a || !b)
    return NO;

  // Strip pre-release suffix (e.g. "1.0.1-v0" → base "1.0.1")
  NSRange dashA = [a rangeOfString:@"-"];
  NSString *baseA =
      dashA.location != NSNotFound ? [a substringToIndex:dashA.location] : a;
  NSRange dashB = [b rangeOfString:@"-"];
  NSString *baseB =
      dashB.location != NSNotFound ? [b substringToIndex:dashB.location] : b;

  NSArray<NSString *> *partsA = [baseA componentsSeparatedByString:@"."];
  NSArray<NSString *> *partsB = [baseB componentsSeparatedByString:@"."];
  NSUInteger count = MAX(partsA.count, partsB.count);

  for (NSUInteger i = 0; i < count; i++) {
    NSInteger va = (i < partsA.count) ? partsA[i].integerValue : 0;
    NSInteger vb = (i < partsB.count) ? partsB[i].integerValue : 0;
    if (va > vb)
      return YES;
    if (va < vb)
      return NO;
  }

  // Base versions equal — release is newer than pre-release (1.0.1 > 1.0.1-v0)
  if (dashA.location == NSNotFound && dashB.location != NSNotFound)
    return YES;

  return NO;
}

@end
