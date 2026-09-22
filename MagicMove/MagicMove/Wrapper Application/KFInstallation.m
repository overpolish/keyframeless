/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KFInstallation.h"

#import <unistd.h>

NSString *const KFSystemTemplateRoot = @"/Library/Application Support/Final Cut Pro/Templates.localized";
NSString *const KFUserTemplateRoot = @"Movies/Motion Templates.localized";

NSString *const KFInstallMetadataKey = @"KFInstall";
NSString *const KFApplicationDirectoryKey = @"ApplicationDirectory";
NSString *const KFTemplateRelativePathKey = @"TemplateRelativePath";
NSString *const KFPreferencesSuiteKey = @"PreferencesSuite";
NSString *const KFProductNameKey = @"ProductName";

static BOOL KFWritable(NSURL *url) {
  return access(url.fileSystemRepresentation, W_OK) == 0;
}

static BOOL KFIsDirectory(NSURL *url) {
  NSNumber *directory = nil;
  [url getResourceValue:&directory forKey:NSURLIsDirectoryKey error:NULL];
  return directory.boolValue;
}

// Unlinking needs write permission on the containing directory; emptying a
// directory needs it on that directory and on every directory inside it.
static BOOL KFRemovableWithoutPrivileges(NSURL *url) {
  if (!KFWritable(url.URLByDeletingLastPathComponent))
    return NO;
  if (!KFIsDirectory(url))
    return YES;
  if (!KFWritable(url))
    return NO;
  NSDirectoryEnumerator *contents =
      [NSFileManager.defaultManager enumeratorAtURL:url
                         includingPropertiesForKeys:@[ NSURLIsDirectoryKey ]
                                            options:0
                                       errorHandler:nil];
  for (NSURL *child in contents) {
    if (KFIsDirectory(child) && !KFWritable(child))
      return NO;
  }
  return YES;
}

static NSString *KFShellQuoted(NSURL *url) {
  NSString *escaped = [url.path stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"];
  return [NSString stringWithFormat:@"'%@'", escaped];
}

@implementation KFInstalledItem

- (instancetype)initWithLabel:(NSString *)label url:(NSURL *)url {
  self = [super init];
  if (self) {
    _label = [label copy];
    _url = url;
    _requiresAdministrator = !KFRemovableWithoutPrivileges(url);
  }
  return self;
}

@end

@implementation KFInstallation {
  NSMutableArray<KFInstalledItem *> *_found;
  NSMutableArray<NSURL *> *_removals;
  NSMutableArray<NSURL *> *_prunes;
  NSString *_packageIdentifier;
}

+ (NSString *)packageIdentifierForBundle:(NSBundle *)bundle {
  NSString *identifier = bundle.bundleIdentifier;
  return identifier ? [identifier stringByAppendingString:@".pkg"] : nil;
}

+ (BOOL)receiptPresentForPackage:(NSString *)identifier {
  NSTask *task = [[NSTask alloc] init];
  task.executableURL = [NSURL fileURLWithPath:@"/usr/sbin/pkgutil"];
  task.arguments = @[ @"--pkg-info", identifier ];
  task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
  task.standardError = NSFileHandle.fileHandleWithNullDevice;
  if (![task launchAndReturnError:NULL])
    return NO;
  [task waitUntilExit];
  return task.terminationStatus == 0;
}

// The uninstaller removes the copy it is running from, so the path has to look
// like an installed plugin. A bundle without the .app wrapper, or sitting at
// the root of a volume, is not ours to delete.
static BOOL KFRemovableBundle(NSURL *bundleURL) {
  return bundleURL.isFileURL && [bundleURL.pathExtension isEqualToString:@"app"] &&
         bundleURL.pathComponents.count >= 3;
}

+ (instancetype)installationForBundle:(NSURL *)bundleURL
                             metadata:(NSDictionary<NSString *, NSString *> *)metadata
                                 home:(NSURL *)home
                           systemRoot:(NSURL *)systemRoot
                              package:(NSString *)package
                       receiptPresent:(BOOL)receiptPresent {
  return [[self alloc] initWithBundle:bundleURL
                             metadata:metadata
                                 home:home
                           systemRoot:systemRoot
                              package:package
                              receipt:receiptPresent];
}

- (instancetype)initWithBundle:(NSURL *)bundleURL
                      metadata:(NSDictionary<NSString *, NSString *> *)metadata
                          home:(NSURL *)home
                    systemRoot:(NSURL *)systemRoot
                       package:(NSString *)package
                       receipt:(BOOL)receiptPresent {
  self = [super init];
  if (!self)
    return nil;
  _packageIdentifier = [package copy];
  _receiptPresent = receiptPresent;
  _productName = metadata[KFProductNameKey] ?: @"";
  _preferencesSuite = metadata[KFPreferencesSuiteKey];
  _found = [NSMutableArray array];
  _removals = [NSMutableArray array];
  _prunes = [NSMutableArray array];

  NSString *applicationDirectory = metadata[KFApplicationDirectoryKey];
  if (bundleURL && KFRemovableBundle(bundleURL) &&
      [NSFileManager.defaultManager fileExistsAtPath:bundleURL.path]) {
    [self add:@"Plug-in" at:bundleURL];
    NSURL *parent = bundleURL.URLByDeletingLastPathComponent;
    if (applicationDirectory.length &&
        [parent.lastPathComponent isEqualToString:applicationDirectory.lastPathComponent])
      [_prunes addObject:parent];
  }

  NSString *template = metadata[KFTemplateRelativePathKey];
  if (template.length) {
    NSURL *systemTemplate = [[systemRoot URLByAppendingPathComponent:[KFSystemTemplateRoot substringFromIndex:1]]
        URLByAppendingPathComponent:template];
    NSURL *userTemplate =
        [[home URLByAppendingPathComponent:KFUserTemplateRoot] URLByAppendingPathComponent:template];
    for (NSArray *candidate in @[
           @[ @"Template (all users)", systemTemplate ],
           @[ @"Template (this user)", userTemplate ],
         ]) {
      NSURL *url = candidate[1];
      if (![NSFileManager.defaultManager fileExistsAtPath:url.path])
        continue;
      [self add:candidate[0] at:url];
      [_prunes addObject:url.URLByDeletingLastPathComponent];
    }
  }
  return self;
}

- (void)add:(NSString *)label at:(NSURL *)url {
  [_found addObject:[[KFInstalledItem alloc] initWithLabel:label url:url]];
  [_removals addObject:url];
}

- (NSArray<KFInstalledItem *> *)items {
  return _found;
}

- (NSArray<NSURL *> *)removalURLs {
  return _removals;
}

- (NSArray<NSURL *> *)pruneDirectories {
  return _prunes;
}

// A receipt on its own is not an installation: it records what a package
// wrote, and only root can retire it, so one can outlive the files.
- (BOOL)isInstalled {
  return _found.count > 0;
}

- (BOOL)requiresAdministrator {
  for (KFInstalledItem *item in _found) {
    if (item.requiresAdministrator)
      return YES;
  }
  for (NSURL *prune in _prunes) {
    if (!KFWritable(prune.URLByDeletingLastPathComponent))
      return YES;
  }
  return NO;
}

- (NSString *)privilegedCommandForRemovals:(NSArray<NSURL *> *)removals prunes:(NSArray<NSURL *> *)prunes {
  NSMutableArray<NSString *> *commands = [NSMutableArray array];
  for (NSURL *url in removals)
    [commands addObject:[NSString stringWithFormat:@"/bin/rm -rf %@", KFShellQuoted(url)]];
  // A shared folder survives while another plugin still fills it, so a failed
  // rmdir is the expected outcome rather than an error.
  for (NSURL *url in prunes)
    [commands addObject:[NSString stringWithFormat:@"/bin/rmdir %@ 2>/dev/null || true", KFShellQuoted(url)]];
  // Forgetting a receipt that has already gone is not a reason to fail.
  if (self.receiptPresent && _packageIdentifier.length)
    [commands addObject:[NSString stringWithFormat:@"/usr/sbin/pkgutil --forget %@ >/dev/null 2>&1 || true",
                                                   _packageIdentifier]];
  return [commands componentsJoinedByString:@"; "];
}

@end
