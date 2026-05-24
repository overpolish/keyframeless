/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Checks this component's release-notes page on the docs site for a
/// `<meta name="kk-version">` tag and compares it to the running version.
/// (DEBUG points at `http://localhost:8000`, release at the Pages custom
/// domain.)
///
/// Call `-checkWithCompletion:` on launch (once per session) or
/// `-forceCheckWithCompletion:` for a manual refresh.
@interface KKUpdateChecker : NSObject

/// The running component's version from its main bundle.
@property(nonatomic, copy, readonly) NSString *currentVersion;

/// The newer version from the docs site, or nil if up to date.
@property(nonatomic, copy, readonly, nullable) NSString *availableVersion;

/// YES when this component has an update available.
@property(nonatomic, assign, readonly) BOOL updateAvailable;

/// This component's release-notes page (always set when the component is known)
/// - the "What's New" destination, which itself links out to Payhip.
@property(nonatomic, copy, readonly, nullable) NSURL *notesURL;

/// The release-notes page when an update is available, else nil (banner
/// target).
@property(nonatomic, copy, readonly, nullable) NSURL *downloadURL;

+ (instancetype)shared;

/// Checks the docs site once per session. Calls `completion` on the main queue.
- (void)checkWithCompletion:(nullable void (^)(BOOL updateAvailable))completion;

/// Checks regardless of whether a check already ran this session.
/// Calls `completion` on the main queue.
- (void)forceCheckWithCompletion:
    (nullable void (^)(BOOL updateAvailable))completion;

@end

NS_ASSUME_NONNULL_END
