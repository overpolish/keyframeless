/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKUpdateChecker.h"
#import "KKLog.h"
#import <AppKit/AppKit.h>
#import <UserNotifications/UserNotifications.h>

static NSString *const kOwner = @"overpolish";
static NSString *const kRepo = @"keyframeless";
static NSString *const kCategoryUpdate = @"co.overpolish.keyframeless.update";
static NSString *const kActionDownload = @"DOWNLOAD_ACTION";
static NSString *const kLastCheckKey =
    @"co.overpolish.keyframeless.lastUpdateCheck";
static NSString *const kCachedVersionKey =
    @"co.overpolish.keyframeless.cachedLatestVersion";
static NSString *const kCachedURLKey =
    @"co.overpolish.keyframeless.cachedDownloadURL";
static NSTimeInterval const kCheckInterval = 86400; // 24 hours

@interface KKUpdateChecker () <UNUserNotificationCenterDelegate>
@end

@implementation KKUpdateChecker {
  KKLog *_log;
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
    _log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless.updateChecker"];

    _currentVersion =
        [[NSBundle mainBundle]
            objectForInfoDictionaryKey:@"CFBundleShortVersionString"]
            ?: @"0.0.0";

    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    _latestVersion = [defaults stringForKey:kCachedVersionKey];
    NSString *cachedURL = [defaults stringForKey:kCachedURLKey];
    if (cachedURL) {
      _downloadURL = [NSURL URLWithString:cachedURL];
    }
    _updateAvailable = [self isVersion:_latestVersion
                             newerThan:_currentVersion];
  }
  return self;
}

- (void)checkWithCompletion:(void (^)(BOOL))completion {
  NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
  NSDate *lastCheck = [defaults objectForKey:kLastCheckKey];
  if (lastCheck &&
      [[NSDate date] timeIntervalSinceDate:lastCheck] < kCheckInterval) {
    [_log debug:@"Skipping update check — last check was %@", lastCheck];
    if (completion) {
      dispatch_async(dispatch_get_main_queue(), ^{
        completion(self.updateAvailable);
      });
    }
    return;
  }

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
            dispatch_async(dispatch_get_main_queue(), ^{
              if (completion)
                completion(self.updateAvailable);
            });
            return;
          }

          NSHTTPURLResponse *http = (NSHTTPURLResponse *)response;
          if (http.statusCode != 200) {
            [self->_log
                warn:@"Update check got HTTP %ld", (long)http.statusCode];
            dispatch_async(dispatch_get_main_queue(), ^{
              if (completion)
                completion(self.updateAvailable);
            });
            return;
          }

          NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data
                                                               options:0
                                                                 error:nil];
          NSString *tag = json[@"tag_name"];
          NSString *htmlURL = json[@"html_url"];

          if (!tag) {
            [self->_log warn:@"No tag_name in release response"];
            dispatch_async(dispatch_get_main_queue(), ^{
              if (completion)
                completion(self.updateAvailable);
            });
            return;
          }

          // Strip leading "v" from tag (e.g. "v1.2" -> "1.2")
          NSString *version = tag;
          if ([version hasPrefix:@"v"] || [version hasPrefix:@"V"]) {
            version = [version substringFromIndex:1];
          }

          BOOL newer = [self isVersion:version newerThan:self.currentVersion];

          [self->_log info:@"Latest: %@ Current: %@ Update: %@", version,
                           self.currentVersion, newer ? @"YES" : @"NO"];

          NSUserDefaults *defs = [NSUserDefaults standardUserDefaults];
          [defs setObject:[NSDate date] forKey:kLastCheckKey];
          [defs setObject:version forKey:kCachedVersionKey];
          if (htmlURL) {
            [defs setObject:htmlURL forKey:kCachedURLKey];
          }

          dispatch_async(dispatch_get_main_queue(), ^{
            self->_latestVersion = version;
            self->_updateAvailable = newer;
            if (htmlURL) {
              self->_downloadURL = [NSURL URLWithString:htmlURL];
            }
            if (completion)
              completion(newer);
          });
        }];
  [task resume];
}

- (void)checkAndNotify {
  UNUserNotificationCenter *center =
      [UNUserNotificationCenter currentNotificationCenter];
  center.delegate = self;

  UNNotificationAction *downloadAction = [UNNotificationAction
      actionWithIdentifier:kActionDownload
                     title:@"Download"
                   options:UNNotificationActionOptionForeground];

  UNNotificationCategory *category =
      [UNNotificationCategory categoryWithIdentifier:kCategoryUpdate
                                             actions:@[ downloadAction ]
                                   intentIdentifiers:@[]
                                             options:0];

  [center setNotificationCategories:[NSSet setWithObject:category]];

  [self checkWithCompletion:^(BOOL updateAvailable) {
    if (!updateAvailable)
      return;

    NSString *version = self.latestVersion ?: @"new version";

    UNMutableNotificationContent *content =
        [[UNMutableNotificationContent alloc] init];
    content.title = @"Keyframeless Update Available";
    content.body = [NSString
        stringWithFormat:@"Version %@ is ready to download.", version];
    content.categoryIdentifier = kCategoryUpdate;

    UNNotificationRequest *request =
        [UNNotificationRequest requestWithIdentifier:kCategoryUpdate
                                             content:content
                                             trigger:nil];

    [center
        requestAuthorizationWithOptions:UNAuthorizationOptionAlert
                      completionHandler:^(BOOL granted, NSError *error) {
                        [self->_log debug:@"Notification auth granted: %d, "
                                          @"error: %@",
                                          granted, error];
                        if (!granted)
                          return;
                        [center
                            addNotificationRequest:request
                             withCompletionHandler:^(NSError *err) {
                               if (err) {
                                 [self->_log
                                     error:@"Notification send failed: %@",
                                           err];
                               } else {
                                 [self->_log debug:@"Notification scheduled"];
                               }
                             }];
                      }];
  }];
}

- (void)userNotificationCenter:(UNUserNotificationCenter *)center
    didReceiveNotificationResponse:(UNNotificationResponse *)response
             withCompletionHandler:(void (^)(void))completionHandler {
  if ([response.actionIdentifier isEqualToString:kActionDownload]) {
    NSURL *url = self.downloadURL;
    if (url) {
      [_log debug:@"Opening download URL: %@", url];
      [[NSWorkspace sharedWorkspace] openURL:url];
    }
  }
  completionHandler();
}

/// Simple numeric version comparison (e.g. "1.2.3" > "1.2").
- (BOOL)isVersion:(nullable NSString *)a newerThan:(nullable NSString *)b {
  if (!a || !b)
    return NO;

  NSArray<NSString *> *partsA = [a componentsSeparatedByString:@"."];
  NSArray<NSString *> *partsB = [b componentsSeparatedByString:@"."];
  NSUInteger count = MAX(partsA.count, partsB.count);

  for (NSUInteger i = 0; i < count; i++) {
    NSInteger va = (i < partsA.count) ? partsA[i].integerValue : 0;
    NSInteger vb = (i < partsB.count) ? partsB[i].integerValue : 0;
    if (va > vb)
      return YES;
    if (va < vb)
      return NO;
  }
  return NO;
}

@end
