/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Checks the latest GitHub release for a `manifest.json` asset and compares
/// this component's version against the manifest entry.
///
/// Call `-checkWithCompletion:` on launch (rate-limited to one network request
/// per 24 hours) or `-forceCheckWithCompletion:` for a manual refresh.
@interface KKUpdateChecker : NSObject

/// The running component's version from its main bundle.
@property(nonatomic, copy, readonly) NSString *currentVersion;

/// The newer version available in the manifest, or nil if up to date.
@property(nonatomic, copy, readonly, nullable) NSString *availableVersion;

/// Manifest keys that aren't in the known component map (new plugins).
@property(nonatomic, copy, readonly)
    NSArray<NSString *> *availableComponentKeys;

/// YES when this component has an update or new components exist.
@property(nonatomic, assign, readonly) BOOL updateAvailable;

/// URL to the GitHub release page.
@property(nonatomic, copy, readonly, nullable) NSURL *downloadURL;

+ (instancetype)shared;

/// Returns the user-facing display name for a component identifier,
/// or nil if the identifier is unknown.
+ (nullable NSString *)displayNameForComponent:(NSString *)componentID;

/// Fetches the manifest from the latest GitHub release if more than 24 hours
/// have elapsed since the last check. Calls `completion` on the main queue.
- (void)checkWithCompletion:(void (^)(BOOL updateAvailable))completion;

/// Fetches the manifest regardless of when the last check occurred.
/// Calls `completion` on the main queue.
- (void)forceCheckWithCompletion:(void (^)(BOOL updateAvailable))completion;

@end

NS_ASSUME_NONNULL_END
