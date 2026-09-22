/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

@class KFInstallation;

NS_ASSUME_NONNULL_BEGIN

extern NSString *const KFUninstallErrorDomain;

typedef NS_ENUM(NSInteger, KFUninstallError) {
  // The authorization dialog was dismissed; the caller leaves the window alone.
  KFUninstallErrorCancelled = 1,
  KFUninstallErrorPrivilegedCommandFailed,
  KFUninstallErrorRemovalFailed,
};

typedef BOOL (^KFPrivilegedRunner)(NSString *command, NSError **error);

@interface KFUninstaller : NSObject

// Removes everything the installation reports. The package leaves its payload
// writable by administrators, so this normally completes without any
// authentication; whatever the current user cannot delete is handled by one
// privileged command afterwards. Saved defaults are removed only when
// `removePreferences` is set.
+ (BOOL)removeInstallation:(KFInstallation *)installation
          serviceDirectory:(nullable NSURL *)serviceDirectory
         removePreferences:(BOOL)removePreferences
                     error:(NSError **)error;

// How that command is run. The default asks for an administrator password
// through the standard macOS dialog; tests substitute their own.
+ (void)setPrivilegedRunner:(nullable KFPrivilegedRunner)runner;

@end

NS_ASSUME_NONNULL_END
