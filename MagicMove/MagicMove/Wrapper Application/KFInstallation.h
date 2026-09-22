/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Where Final Cut Pro and Motion read templates from. The installer writes the
// first for every account; the second is where Motion saves its own and where
// scripts/motion-template.py installs during development.
extern NSString *const KFSystemTemplateRoot;
extern NSString *const KFUserTemplateRoot;

// Each plugin declares what it installs in its application's Info.plist, under
// KFInstall: ApplicationDirectory, TemplateRelativePath, PreferencesSuite and
// ProductName. scripts/build-pkg.sh reads the same dictionary out of the built
// application, so the package and the uninstaller cannot disagree.
extern NSString *const KFInstallMetadataKey;
extern NSString *const KFApplicationDirectoryKey;
extern NSString *const KFTemplateRelativePathKey;
extern NSString *const KFPreferencesSuiteKey;
extern NSString *const KFProductNameKey;

// One thing on disk the uninstaller offers to remove. Items are only created
// for paths that exist, so the UI lists what is really installed.
@interface KFInstalledItem : NSObject
@property(readonly) NSString *label;
@property(readonly) NSURL *url;
// Whether removing it needs privileges. Unlinking needs write permission on
// the containing directory, and emptying a directory needs it on every
// directory inside. The installer leaves its payload writable by
// administrators, so this is normally false.
@property(readonly) BOOL requiresAdministrator;
@end

@interface KFInstallation : NSObject

// `systemRoot` is "/" in production and a temporary directory under test.
// `package` is the installer package identifier, which the build derives from
// the application's bundle identifier.
+ (instancetype)installationForBundle:(nullable NSURL *)bundleURL
                             metadata:(NSDictionary<NSString *, NSString *> *)metadata
                                 home:(NSURL *)home
                           systemRoot:(NSURL *)systemRoot
                              package:(nullable NSString *)package
                       receiptPresent:(BOOL)receiptPresent;

// The package identifier recorded by the installer for an application bundle.
+ (nullable NSString *)packageIdentifierForBundle:(NSBundle *)bundle;

// The receipt is registered by the package installer and is only readable, so
// this runs unprivileged. Forgetting one needs root, which an uninstall no
// longer has to ask for, so a stale receipt can outlive the files it recorded.
+ (BOOL)receiptPresentForPackage:(NSString *)identifier;

@property(readonly) NSString *productName;
@property(readonly, nullable) NSString *preferencesSuite;
@property(readonly) NSArray<KFInstalledItem *> *items;
@property(readonly) BOOL receiptPresent;
// Whether the uninstaller expects to need an administrator password. This is
// what the confirmation says; the removal itself decides by trying.
@property(readonly) BOOL requiresAdministrator;
@property(readonly, getter=isInstalled) BOOL installed;

// Everything to delete, in removal order.
@property(readonly) NSArray<NSURL *> *removalURLs;
// Shared parents to drop once their contents are gone: the Keyframeless folder
// under Applications and the template category other plugins also populate.
// Removed only when empty, so a second installed plugin keeps them.
@property(readonly) NSArray<NSURL *> *pruneDirectories;

// One /bin/sh command line for the paths the current user could not remove
// itself, plus the installer receipt while we have privileges anyway.
- (NSString *)privilegedCommandForRemovals:(NSArray<NSURL *> *)removals
                                    prunes:(NSArray<NSURL *> *)prunes;

@end

NS_ASSUME_NONNULL_END
