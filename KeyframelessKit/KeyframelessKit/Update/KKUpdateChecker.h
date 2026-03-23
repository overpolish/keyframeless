/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Checks the GitHub Releases API for newer versions of Keyframeless.
///
/// Call `-checkWithCompletion:` to fetch the latest release. The checker
/// rate-limits itself to one network request per day and caches the result
/// in `NSUserDefaults`.
@interface KKUpdateChecker : NSObject

@property(nonatomic, copy, readonly) NSString *currentVersion;
@property(nonatomic, copy, readonly, nullable) NSString *latestVersion;
@property(nonatomic, assign, readonly) BOOL updateAvailable;
@property(nonatomic, copy, readonly, nullable) NSURL *downloadURL;

+ (instancetype)shared;

/// Fetches the latest release from GitHub if a check hasn't been performed
/// in the last 24 hours. Calls `completion` on the main queue.
- (void)checkWithCompletion:(void (^)(BOOL updateAvailable))completion;

/// Checks for updates and posts a system notification with a "Download"
/// action if one is available. Call from `-applicationDidFinishLaunching:`.
- (void)checkAndNotify;

@end

NS_ASSUME_NONNULL_END
