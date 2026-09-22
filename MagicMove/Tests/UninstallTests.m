/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "KFInstallation.h"
#import "KFUninstaller.h"

#import <assert.h>
#import <stdio.h>
#import <stdlib.h>
#import <sys/stat.h>

static NSURL *gRoot;

// Stands in for the KFInstall dictionary a plugin declares in its Info.plist.
static NSDictionary *Metadata(void) {
  return @{
    KFApplicationDirectoryKey : @"/Applications/Keyframeless",
    KFTemplateRelativePathKey : @"Effects.localized/Keyframeless/Magic Move",
    KFPreferencesSuiteKey : @"com.keyframeless.magicmove.preferences",
    KFProductNameKey : @"Magic Move",
  };
}

static NSURL *MakeDirectory(NSURL *base, NSString *relative) {
  NSURL *url = [base URLByAppendingPathComponent:relative];
  assert([NSFileManager.defaultManager createDirectoryAtURL:url
                                withIntermediateDirectories:YES
                                                 attributes:nil
                                                      error:NULL]);
  return url;
}

// A directory nobody may write can still be unlinked while it is empty, so a
// stand-in for root-owned bundle contents has to hold something.
static void MakeFile(NSURL *directory, NSString *name) {
  NSURL *url = [directory URLByAppendingPathComponent:name];
  assert([[NSData data] writeToURL:url atomically:YES]);
}

static NSURL *Sandbox(NSString *name) {
  return MakeDirectory(gRoot, name);
}

static KFInstallation *Installation(NSURL *bundle, NSURL *home, NSURL *system, BOOL receipt) {
  return [KFInstallation installationForBundle:bundle
                                      metadata:Metadata()
                                          home:home
                                    systemRoot:system
                                       package:@"com.keyframeless.MagicMove.pkg"
                                receiptPresent:receipt];
}

static NSString *TemplatePath(NSString *root) {
  return [NSString stringWithFormat:@"%@/%@", root, Metadata()[KFTemplateRelativePathKey]];
}

static NSString *SystemTemplatePath(void) {
  return TemplatePath([KFSystemTemplateRoot substringFromIndex:1]);
}

static NSArray<NSString *> *Labels(KFInstallation *installation) {
  NSMutableArray<NSString *> *labels = [NSMutableArray array];
  for (KFInstalledItem *item in installation.items)
    [labels addObject:item.label];
  return labels;
}

static BOOL Exists(NSURL *url) {
  return [NSFileManager.defaultManager fileExistsAtPath:url.path];
}

static NSString *Command(KFInstallation *installation) {
  return [installation privilegedCommandForRemovals:installation.removalURLs
                                             prunes:installation.pruneDirectories];
}

// Everything the package writes, in the place it writes it: the plug-in in its
// Keyframeless folder, and the template both for all users and for this one.
// The installed payload is writable by administrators, so none of it needs a
// password.
static void testFindsEveryInstalledPiece(void) {
  NSURL *sandbox = Sandbox(@"complete");
  NSURL *system = [sandbox URLByAppendingPathComponent:@"system"];
  NSURL *home = [sandbox URLByAppendingPathComponent:@"home"];
  NSURL *bundle = MakeDirectory(sandbox, @"Applications/Keyframeless/MagicMove.app");
  MakeDirectory(system, SystemTemplatePath());
  MakeDirectory(home, TemplatePath(KFUserTemplateRoot));

  KFInstallation *installation = Installation(bundle, home, system, NO);
  assert(installation.isInstalled);
  assert([installation.productName isEqualToString:@"Magic Move"]);
  assert([Labels(installation) isEqual:(@[ @"Plug-in", @"Template (all users)", @"Template (this user)" ])]);
  assert(installation.removalURLs.count == 3);
  // The Keyframeless folder and the Effects category are shared with other
  // plugins, so they are pruned rather than deleted outright.
  assert(installation.pruneDirectories.count == 3);
  assert([installation.pruneDirectories.firstObject.lastPathComponent isEqualToString:@"Keyframeless"]);
  assert(!installation.requiresAdministrator);
}

// A build run from a derived-data directory, or any copy that is not installed,
// still offers to remove itself but reports no template.
static void testReportsOnlyWhatExists(void) {
  NSURL *sandbox = Sandbox(@"bare");
  NSURL *bundle = MakeDirectory(sandbox, @"Build/Products/Debug/MagicMove.app");
  KFInstallation *installation =
      Installation(bundle, [sandbox URLByAppendingPathComponent:@"home"],
                   [sandbox URLByAppendingPathComponent:@"system"], NO);
  assert([Labels(installation) isEqual:@[ @"Plug-in" ]]);
  // Only the Keyframeless folder is pruned; a build directory is not ours.
  assert(installation.pruneDirectories.count == 0);
}

// Only root can forget a receipt, and the uninstall no longer asks for root,
// so a receipt on its own does not make the product installed. It is cleared
// when privileges are needed for something else.
static void testReceiptIsNotAnInstallation(void) {
  NSURL *sandbox = Sandbox(@"receipt");
  KFInstallation *installation = Installation(nil, [sandbox URLByAppendingPathComponent:@"home"],
                                              [sandbox URLByAppendingPathComponent:@"system"], YES);
  assert(installation.items.count == 0);
  assert(!installation.isInstalled);
  assert(!installation.requiresAdministrator);
  assert([Command(installation) isEqualToString:
                                    @"/usr/sbin/pkgutil --forget com.keyframeless.MagicMove.pkg "
                                    @">/dev/null 2>&1 || true"]);
}

// The uninstaller deletes the bundle it is running from, so a path that is not
// an installed application is left alone rather than removed on a guess.
static void testRefusesImplausibleBundles(void) {
  NSURL *sandbox = Sandbox(@"implausible");
  NSURL *home = [sandbox URLByAppendingPathComponent:@"home"];
  NSURL *system = [sandbox URLByAppendingPathComponent:@"system"];
  NSURL *plain = MakeDirectory(sandbox, @"Applications/Keyframeless/MagicMove");
  assert(Installation(plain, home, system, NO).items.count == 0);
  assert(Installation([NSURL fileURLWithPath:@"/"], home, system, NO).items.count == 0);
  assert(Installation([NSURL URLWithString:@"https://example.com/MagicMove.app"], home, system, NO).items.count == 0);
}

// A locked containing directory means the item cannot be unlinked at all.
static void testLockedDirectoriesNeedAdministrator(void) {
  NSURL *sandbox = Sandbox(@"locked");
  NSURL *system = [sandbox URLByAppendingPathComponent:@"system"];
  NSURL *category = MakeDirectory(system, [SystemTemplatePath() stringByDeletingLastPathComponent]);
  NSURL *template = MakeDirectory(category, @"Magic Move");
  assert(chmod(category.fileSystemRepresentation, 0555) == 0);

  KFInstallation *installation =
      Installation(nil, [sandbox URLByAppendingPathComponent:@"home"], system, NO);
  assert(installation.items.count == 1);
  assert(installation.items.firstObject.requiresAdministrator);
  assert(installation.requiresAdministrator);
  NSString *remove = [NSString stringWithFormat:@"/bin/rm -rf '%@'", template.path];
  assert([Command(installation) hasPrefix:remove]);
  assert(chmod(category.fileSystemRepresentation, 0755) == 0);
}

// An application whose own contents are not writable can be unlinked only
// after being emptied, which needs permission inside it. Looking at the parent
// alone promises a removal that then fails.
static void testApplicationOwningItsContentsNeedsAdministrator(void) {
  NSURL *sandbox = Sandbox(@"owned-contents");
  NSURL *bundle = MakeDirectory(sandbox, @"Applications/Keyframeless/MagicMove.app");
  NSURL *contents = MakeDirectory(bundle, @"Contents/MacOS");
  MakeFile(contents, @"MagicMove");
  assert(chmod(contents.fileSystemRepresentation, 0555) == 0);

  KFInstallation *installation = Installation(bundle, [sandbox URLByAppendingPathComponent:@"home"],
                                              [sandbox URLByAppendingPathComponent:@"system"], NO);
  assert(installation.items.firstObject.requiresAdministrator);
  assert(installation.requiresAdministrator);
  assert(chmod(contents.fileSystemRepresentation, 0755) == 0);
}

// Every path reaches the shell through single quotes, and a quote in the path
// must not end them: "Magic Move" already carries a space.
static void testQuotesPathsForTheShell(void) {
  NSURL *sandbox = Sandbox(@"quoting");
  NSURL *locked = MakeDirectory(sandbox, @"Dom's Disk/Applications/Keyframeless");
  NSURL *bundle = MakeDirectory(locked, @"MagicMove.app");

  KFInstallation *installation = Installation(bundle, [sandbox URLByAppendingPathComponent:@"home"],
                                              [sandbox URLByAppendingPathComponent:@"system"], NO);
  NSString *command = Command(installation);
  assert([command containsString:@"Dom'\\''s Disk"]);
  assert(![command containsString:@"Dom's Disk"]);
}

// The installed payload is writable by administrators, so the ordinary removal
// authenticates nothing and takes the shared Keyframeless folders with it once
// they are empty.
static void testRemovesEverythingItLists(void) {
  NSURL *sandbox = Sandbox(@"removal");
  NSURL *system = [sandbox URLByAppendingPathComponent:@"system"];
  NSURL *home = [sandbox URLByAppendingPathComponent:@"home"];
  NSURL *bundle = MakeDirectory(sandbox, @"Applications/Keyframeless/MagicMove.app");
  NSURL *systemTemplate = MakeDirectory(system, SystemTemplatePath());
  NSURL *userTemplate = MakeDirectory(home, TemplatePath(KFUserTemplateRoot));

  __block BOOL escalated = NO;
  [KFUninstaller setPrivilegedRunner:^BOOL(NSString *command, NSError **error) {
    (void)command;
    (void)error;
    escalated = YES;
    return YES;
  }];
  NSError *error = nil;
  // A receipt is present and still does not drag in an authorization prompt.
  assert([KFUninstaller removeInstallation:Installation(bundle, home, system, YES)
                          serviceDirectory:nil
                         removePreferences:NO
                                     error:&error]);
  [KFUninstaller setPrivilegedRunner:nil];
  assert(!escalated);
  assert(error == nil);
  assert(!Exists(bundle));
  assert(!Exists(systemTemplate));
  assert(!Exists(userTemplate));
  assert(!Exists(bundle.URLByDeletingLastPathComponent));
  assert(!Exists(systemTemplate.URLByDeletingLastPathComponent));
  // The effect category belongs to Final Cut Pro, not to us.
  assert(Exists(systemTemplate.URLByDeletingLastPathComponent.URLByDeletingLastPathComponent));
}

// The Keyframeless folders are shared with the other plugins, so they only go
// when this was the last thing in them.
static void testKeepsFoldersAnotherPluginStillUses(void) {
  NSURL *sandbox = Sandbox(@"shared");
  NSURL *system = [sandbox URLByAppendingPathComponent:@"system"];
  NSURL *home = [sandbox URLByAppendingPathComponent:@"home"];
  NSURL *bundle = MakeDirectory(sandbox, @"Applications/Keyframeless/MagicMove.app");
  NSURL *neighbour = MakeDirectory(sandbox, @"Applications/Keyframeless/Rounded.app");
  NSURL *systemTemplate = MakeDirectory(system, SystemTemplatePath());
  NSURL *neighbourTemplate = MakeDirectory(systemTemplate.URLByDeletingLastPathComponent, @"Rounded");

  assert([KFUninstaller removeInstallation:Installation(bundle, home, system, NO)
                          serviceDirectory:nil
                         removePreferences:NO
                                     error:NULL]);
  assert(!Exists(bundle));
  assert(Exists(neighbour));
  assert(Exists(neighbourTemplate));
}

// What the user cannot delete is handed to the privileged command instead of
// failing the uninstall, and what the user could delete is already gone by
// then, so the command only carries the rest, plus the receipt it may as well
// clear while it has the privileges.
static void testEscalatesOnlyForWhatItCannotRemove(void) {
  NSURL *sandbox = Sandbox(@"escalation");
  NSURL *systemRoot = [sandbox URLByAppendingPathComponent:@"system"];
  NSURL *home = [sandbox URLByAppendingPathComponent:@"home"];
  NSURL *bundle = MakeDirectory(sandbox, @"Applications/Keyframeless/MagicMove.app");
  NSURL *contents = MakeDirectory(bundle, @"Contents/MacOS");
  MakeFile(contents, @"MagicMove");
  NSURL *userTemplate = MakeDirectory(home, TemplatePath(KFUserTemplateRoot));
  assert(chmod(contents.fileSystemRepresentation, 0555) == 0);

  __block NSString *issued = nil;
  [KFUninstaller setPrivilegedRunner:^BOOL(NSString *command, NSError **error) {
    (void)error;
    issued = command;
    // Stand in for root: the ownership that refused the delete does not apply.
    chmod(contents.fileSystemRepresentation, 0755);
    return system([command UTF8String]) == 0;
  }];
  assert([KFUninstaller removeInstallation:Installation(bundle, home, systemRoot, YES)
                          serviceDirectory:nil
                         removePreferences:NO
                                     error:NULL]);
  [KFUninstaller setPrivilegedRunner:nil];
  assert([issued containsString:bundle.path]);
  assert(![issued containsString:userTemplate.path]);
  assert([issued containsString:@"pkgutil --forget"]);
  assert(!Exists(bundle));
  assert(!Exists(userTemplate));
  assert(!Exists(bundle.URLByDeletingLastPathComponent));
}

// An authorized command that did not actually remove everything is a failure,
// not a success: the window would otherwise report a removal that did not
// happen and quit.
static void testReportsPathsThatSurviveEscalation(void) {
  NSURL *sandbox = Sandbox(@"survivor");
  NSURL *bundle = MakeDirectory(sandbox, @"Applications/Keyframeless/MagicMove.app");
  NSURL *contents = MakeDirectory(bundle, @"Contents/MacOS");
  MakeFile(contents, @"MagicMove");
  assert(chmod(contents.fileSystemRepresentation, 0555) == 0);

  [KFUninstaller setPrivilegedRunner:^BOOL(NSString *command, NSError **error) {
    (void)command;
    (void)error;
    return YES;
  }];
  NSError *error = nil;
  BOOL removed = [KFUninstaller removeInstallation:Installation(bundle, [sandbox URLByAppendingPathComponent:@"home"],
                                                                [sandbox URLByAppendingPathComponent:@"system"], NO)
                                  serviceDirectory:nil
                                 removePreferences:NO
                                             error:&error];
  [KFUninstaller setPrivilegedRunner:nil];
  assert(!removed);
  assert(error.code == KFUninstallErrorRemovalFailed);
  assert([error.localizedDescription containsString:bundle.path]);
  assert(chmod(contents.fileSystemRepresentation, 0755) == 0);
}

int main(void) {
  @autoreleasepool {
    gRoot = [NSURL fileURLWithPath:[NSTemporaryDirectory()
                                       stringByAppendingPathComponent:NSUUID.UUID.UUIDString]];
    testFindsEveryInstalledPiece();
    testReportsOnlyWhatExists();
    testReceiptIsNotAnInstallation();
    testRefusesImplausibleBundles();
    testLockedDirectoriesNeedAdministrator();
    testApplicationOwningItsContentsNeedsAdministrator();
    testQuotesPathsForTheShell();
    testRemovesEverythingItLists();
    testKeepsFoldersAnotherPluginStillUses();
    testEscalatesOnlyForWhatItCannotRemove();
    testReportsPathsThatSurviveEscalation();
    [NSFileManager.defaultManager removeItemAtURL:gRoot error:NULL];
    printf("UninstallTests passed\n");
  }
  return 0;
}
