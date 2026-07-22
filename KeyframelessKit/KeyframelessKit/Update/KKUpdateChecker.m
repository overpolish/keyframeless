/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKUpdateChecker.h"
#import "KKLog.h"
#import <AppKit/AppKit.h>

static NSString *KKUpdateBaseURL(void) {
#if DEBUG
  return @"http://localhost:8000";
#else
  return @"https://update.keyframeless.overpolish.co";
#endif
}

static NSString *KKFeedbackBaseURL(void) {
#if DEBUG
  // `wrangler dev` in feedback-worker/ serves the form + /submit here.
  return @"http://localhost:8787/";
#else
  return @"https://feedback.keyframeless.overpolish.co/";
#endif
}

static NSString *const kCachedVersionKey =
    @"co.overpolish.keyframeless.cachedAvailableVersion";

static NSDictionary<NSString *, NSString *> *KKBundleIDToComponent(void) {
  return @{
    @"co.overpolish.keyframeless.Keyframeless-X" : @"keyframelessx",
    @"co.overpolish.keyframeless.Keyframeless-X.Keyframeless-X-FCP" :
        @"keyframelessx",
    // FxPlug plugins: current reverse-DNS ids (host + .PlugIn extension). The
    // bare and -XPC-Service ids are the pre-standardization installs, kept so
    // they still resolve to a changelog and get prompted to update.
    @"co.overpolish.keyframeless.Rounded" : @"rounded",
    @"co.overpolish.keyframeless.Rounded.PlugIn" : @"rounded",
    @"Rounded" : @"rounded",
    @"Rounded-XPC-Service" : @"rounded",
    @"co.overpolish.keyframeless.MagicMove" : @"magicmove",
    @"co.overpolish.keyframeless.MagicMove.PlugIn" : @"magicmove",
    @"co.overpolish.keyframeless.Mirage" : @"mirage",
    @"co.overpolish.keyframeless.Mirage.PlugIn" : @"mirage",
    @"MagicMove" : @"magicmove",
    @"MagicMove-XPC-Service" : @"magicmove",
    @"co.overpolish.keyframeless.Canvas" : @"canvas",
    @"co.overpolish.keyframeless.Canvas.PlugIn" : @"canvas",
    @"Canvas" : @"canvas",
    @"Canvas-XPC-Service" : @"canvas",
    @"co.overpolish.keyframeless.Glow" : @"glow",
    @"co.overpolish.keyframeless.Glow.PlugIn" : @"glow",
    @"Glow" : @"glow",
    @"Glow-XPC-Service" : @"glow"
  };
}

// The standalone "Keyframeless AI" helper installs its version manifest beside
// the binary (staged in build-and-sign.sh, installed by the pkg). Reading it
// tells us the INSTALLED helper version, independent of the running plugin.
static NSString *const kAIHelperVersionPlist =
    @"/Library/Application Support/Keyframeless/kk-ai-helper.plist";

@implementation KKUpdateChecker {
  NSString *_componentKey;
  BOOL _checkedThisSession;
  BOOL _aiCheckedThisSession;
}

+ (instancetype)shared {
  static KKUpdateChecker *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[KKUpdateChecker alloc] init];
  });
  return instance;
}

- (instancetype)init {
  self = [super init];
  if (self) {
    NSString *bundleID = [[NSBundle mainBundle] bundleIdentifier] ?: @"";
    _componentKey = KKBundleIDToComponent()[bundleID];
    if (!_componentKey) {
      KKLogWarn(@"Unknown bundle identifier: %@", bundleID);
    }

    _currentVersion =
        [[NSBundle mainBundle]
            objectForInfoDictionaryKey:@"CFBundleShortVersionString"]
            ?: @"0.0.0";

    if (_componentKey) {
      _notesURL = [NSURL
          URLWithString:[NSString stringWithFormat:@"%@/%@/", KKUpdateBaseURL(),
                                                   _componentKey]];
    }

    NSURLComponents *feedback =
        [NSURLComponents componentsWithString:KKFeedbackBaseURL()];
    NSMutableArray<NSURLQueryItem *> *feedbackItems = [NSMutableArray array];
    if (_componentKey) {
      [feedbackItems
          addObject:[NSURLQueryItem queryItemWithName:@"plugin"
                                                value:_componentKey]];
    }
    [feedbackItems
        addObject:[NSURLQueryItem queryItemWithName:@"version"
                                              value:_currentVersion]];
    feedback.queryItems = feedbackItems;
    _feedbackURL = feedback.URL;

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    _availableVersion = [defaults stringForKey:kCachedVersionKey];
    // Validate cached version against current - clear stale cache from
    // pre-update
    if (_availableVersion && ![self isVersion:_availableVersion
                                    newerThan:_currentVersion]) {
      _availableVersion = nil;
      [defaults removeObjectForKey:kCachedVersionKey];
    }

    _updateAvailable = _availableVersion != nil;
    _downloadURL = _updateAvailable ? _notesURL : nil;
  }
  return self;
}

- (void)checkWithCompletion:(void (^)(BOOL))completion {
  if (_checkedThisSession) {
    KKLogDebug(@"Skipping update check - already checked this session");
    if (completion) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(self.updateAvailable);
      });
    }
    return;
  }

  _checkedThisSession = YES;
  [self fetchVersionWithCompletion:completion];
}

- (void)forceCheckWithCompletion:(void (^)(BOOL))completion {
  [self fetchVersionWithCompletion:completion];
}

- (void)fetchVersionWithCompletion:(void (^)(BOOL))completion {
  if (!self.notesURL) {
    KKLogWarn(@"No notes URL (unknown component); skipping update check");
    [self callCompletion:completion];
    return;
  }

  NSMutableURLRequest *request =
      [NSMutableURLRequest requestWithURL:self.notesURL];
  request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;

  KKLogInfo(@"Checking for updates at %@", self.notesURL);

  NSURLSessionDataTask *task = [[NSURLSession sharedSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response,
                            NSError *error) {
          if (error) {
            KKLogWarn(@"Update check failed: %@", error.localizedDescription);
            [self callCompletion:completion];
            return;
          }

          NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
          if (http.statusCode != 200) {
            KKLogWarn(@"Update check got HTTP %ld", (long)http.statusCode);
            [self clearCacheAndComplete:completion];
            return;
          }

          NSString *body = [[NSString alloc] initWithData:data
                                                 encoding:NSUTF8StringEncoding];
          [self processVersion:[self versionFromHTML:body]
                    completion:completion];
        }];
  [task resume];
}

// Pulls the value out of <meta name="kk-version" content="X.Y.Z"> - a stable
// contract embedded in each release-notes page (not visible-markup scraping).
- (nullable NSString *)versionFromHTML:(nullable NSString *)htmlBody {
  if (htmlBody.length == 0)
    return nil;
  NSRegularExpression *re = [NSRegularExpression
      regularExpressionWithPattern:
          @"<meta[^>]*name=\"kk-version\"[^>]*content=\"([^\"]+)\""
                           options:NSRegularExpressionCaseInsensitive
                             error:nil];
  NSTextCheckingResult *m =
      [re firstMatchInString:htmlBody
                     options:0
                       range:NSMakeRange(0, htmlBody.length)];
  if (!m)
    return nil;
  return [htmlBody substringWithRange:[m rangeAtIndex:1]];
}

- (void)processVersion:(nullable NSString *)latest
            completion:(void (^)(BOOL))completion {
  NSString *newerVersion = nil;
  if (latest && [self isVersion:latest newerThan:_currentVersion]) {
    KKLogInfo(@"Update available for %@: %@ -> %@", _componentKey,
              _currentVersion, latest);
    newerVersion = latest;
  } else {
    KKLogDebug(@"%@ is up to date (%@; latest %@)", _componentKey,
               _currentVersion, latest ?: @"?");
  }

  BOOL hasUpdate = newerVersion != nil;

  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  if (hasUpdate) {
    [defaults setObject:newerVersion forKey:kCachedVersionKey];
  } else {
    [defaults removeObjectForKey:kCachedVersionKey];
  }

  dispatch_async(dispatch_get_main_queue(), ^{
    self->_availableVersion = newerVersion;
    self->_updateAvailable = hasUpdate;
    self->_downloadURL = hasUpdate ? self->_notesURL : nil;
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
  [[NSUserDefaults standardUserDefaults] removeObjectForKey:kCachedVersionKey];

  dispatch_async(dispatch_get_main_queue(), ^{
    self->_availableVersion = nil;
    self->_updateAvailable = NO;
    self->_downloadURL = nil;
    if (completion)
      completion(NO);
  });
}

- (nullable NSString *)readInstalledAIVersion {
  NSDictionary *manifest =
      [NSDictionary dictionaryWithContentsOfFile:kAIHelperVersionPlist];
  NSString *v = manifest[@"CFBundleShortVersionString"];
  return v.length ? v : nil;
}

- (void)checkAIUpdateWithCompletion:(void (^)(BOOL))completion {
  NSString *installed = [self readInstalledAIVersion];
  self->_aiCurrentVersion = installed;
  self->_aiNotesURL = [NSURL
      URLWithString:[NSString stringWithFormat:@"%@/ai/", KKUpdateBaseURL()]];

  // No manifest = the Keyframeless AI helper isn't installed, so there's
  // nothing to update. (Cloud-only / BYOK users never install it.)
  if (!installed) {
    dispatch_async(dispatch_get_main_queue(), ^{
      self->_aiAvailableVersion = nil;
      self->_aiUpdateAvailable = NO;
      if (completion)
        completion(NO);
    });
    return;
  }

  // Once per session: the shipped version doesn't change mid-session, and the
  // popover can open repeatedly. Report the cached result on subsequent opens.
  if (_aiCheckedThisSession) {
    dispatch_async(dispatch_get_main_queue(), ^{
      if (completion)
        completion(self.aiUpdateAvailable);
    });
    return;
  }
  _aiCheckedThisSession = YES;

  NSMutableURLRequest *request =
      [NSMutableURLRequest requestWithURL:self->_aiNotesURL];
  request.cachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
  KKLogInfo(@"Checking for Keyframeless AI updates at %@", self->_aiNotesURL);

  NSURLSessionDataTask *task = [[NSURLSession sharedSession]
      dataTaskWithRequest:request
        completionHandler:^(NSData *data, NSURLResponse *response,
                            NSError *error) {
          NSString *latest = nil;
          if (error) {
            KKLogWarn(@"Keyframeless AI update check failed: %@",
                      error.localizedDescription);
          } else if (((NSHTTPURLResponse *)response).statusCode == 200) {
            NSString *body =
                [[NSString alloc] initWithData:data
                                      encoding:NSUTF8StringEncoding];
            latest = [self versionFromHTML:body];
          }
          BOOL hasUpdate = latest && [self isVersion:latest
                                           newerThan:installed];
          if (hasUpdate)
            KKLogInfo(@"Keyframeless AI update available: %@ -> %@", installed,
                      latest);
          dispatch_async(dispatch_get_main_queue(), ^{
            self->_aiAvailableVersion = hasUpdate ? latest : nil;
            self->_aiUpdateAvailable = hasUpdate;
            if (completion)
              completion(hasUpdate);
          });
        }];
  [task resume];
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

  // Base versions equal - release is newer than pre-release (1.0.1 > 1.0.1-v0)
  if (dashA.location == NSNotFound && dashB.location != NSNotFound)
    return YES;

  return NO;
}

@end
