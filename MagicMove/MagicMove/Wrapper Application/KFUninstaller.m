/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KFUninstaller.h"

#import "KFInstallation.h"

#import <Foundation/Foundation.h>

NSString *const KFUninstallErrorDomain = @"com.keyframeless.uninstall";

static KFPrivilegedRunner gPrivilegedRunner;

static NSError *KFError(KFUninstallError code, NSString *description) {
  return [NSError errorWithDomain:KFUninstallErrorDomain
                             code:code
                         userInfo:@{NSLocalizedDescriptionKey : description}];
}

static void KFRun(NSString *launchPath, NSArray<NSString *> *arguments) {
  NSTask *task = [[NSTask alloc] init];
  task.executableURL = [NSURL fileURLWithPath:launchPath];
  task.arguments = arguments;
  task.standardOutput = NSFileHandle.fileHandleWithNullDevice;
  task.standardError = NSFileHandle.fileHandleWithNullDevice;
  if ([task launchAndReturnError:NULL])
    [task waitUntilExit];
}

static NSString *KFAppleScriptQuoted(NSString *command) {
  NSString *escaped = [command stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
  escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
  return [NSString stringWithFormat:@"\"%@\"", escaped];
}

@implementation KFUninstaller

// PlugInKit keeps one registration per plug-in identifier and holds on to it
// after the bundle is gone, so withdraw it before deleting the app.
+ (void)unregisterServicesIn:(NSURL *)serviceDirectory {
  if (!serviceDirectory)
    return;
  NSArray<NSURL *> *contents = [NSFileManager.defaultManager contentsOfDirectoryAtURL:serviceDirectory
                                                          includingPropertiesForKeys:nil
                                                                             options:0
                                                                               error:NULL];
  for (NSURL *service in contents) {
    if ([service.pathExtension isEqualToString:@"pluginkit"])
      KFRun(@"/usr/bin/pluginkit", @[ @"-r", service.path ]);
  }
}

+ (void)setPrivilegedRunner:(KFPrivilegedRunner)runner {
  gPrivilegedRunner = [runner copy];
}

+ (BOOL)runPrivileged:(NSString *)command error:(NSError **)error {
  if (gPrivilegedRunner)
    return gPrivilegedRunner(command, error);
  NSString *source = [NSString stringWithFormat:@"do shell script %@ with administrator privileges",
                                                KFAppleScriptQuoted(command)];
  NSDictionary *failure = nil;
  [[[NSAppleScript alloc] initWithSource:source] executeAndReturnError:&failure];
  if (!failure)
    return YES;
  if (error) {
    BOOL cancelled = [failure[NSAppleScriptErrorNumber] integerValue] == -128;
    *error = cancelled ? KFError(KFUninstallErrorCancelled, @"Uninstall cancelled.")
                       : KFError(KFUninstallErrorPrivilegedCommandFailed,
                                 failure[NSAppleScriptErrorMessage] ?: @"The removal could not be authorized.");
  }
  return NO;
}

// The hosts also leave a sandbox container behind for the service, but only
// containermanagerd may delete one, so the preferences are what is left to
// clear. They live in the plain user domain, and cfprefsd owns the live copy:
// deleting the file behind its back would be undone on the next write.
+ (void)removePreferences:(NSString *)suite {
  if (suite.length)
    KFRun(@"/usr/bin/defaults", @[ @"delete", suite ]);
}

+ (BOOL)removeInstallation:(KFInstallation *)installation
          serviceDirectory:(NSURL *)serviceDirectory
         removePreferences:(BOOL)removePreferences
                     error:(NSError **)error {
  [self unregisterServicesIn:serviceDirectory];
  NSFileManager *files = NSFileManager.defaultManager;

  // Permissions are decided by trying rather than by predicting: an
  // application the user can unlink may still own root-only directories
  // inside, and only the attempt knows.
  NSMutableArray<NSURL *> *refused = [NSMutableArray array];
  for (NSURL *url in installation.removalURLs) {
    if (![files removeItemAtURL:url error:NULL] && [files fileExistsAtPath:url.path])
      [refused addObject:url];
  }

  NSMutableArray<NSURL *> *prunes = [NSMutableArray array];
  for (NSURL *url in installation.pruneDirectories) {
    NSArray<NSURL *> *remaining = [files contentsOfDirectoryAtURL:url
                                      includingPropertiesForKeys:nil
                                                         options:0
                                                           error:NULL];
    if (!remaining)
      continue;
    if (remaining.count == 0 && [files removeItemAtURL:url error:NULL])
      continue;
    // Either something else still uses it, or emptying it needs privileges.
    // The privileged rmdir refuses a folder in use, which is what we want.
    [prunes addObject:url];
  }

  if (refused.count) {
    NSString *command = [installation privilegedCommandForRemovals:refused prunes:prunes];
    if (![self runPrivileged:command error:error])
      return NO;
    for (NSURL *url in refused) {
      if ([files fileExistsAtPath:url.path]) {
        if (error)
          *error = KFError(KFUninstallErrorRemovalFailed,
                           [NSString stringWithFormat:@"%@ is still there.", url.path]);
        return NO;
      }
    }
  }

  if (removePreferences)
    [self removePreferences:installation.preferencesSuite];
  return YES;
}

@end
