/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "AppDelegate.h"

#import "KFInstallation.h"
#import "KFUninstallWindowController.h"

@interface AppDelegate ()
@property(nonatomic) KFUninstallWindowController *controller;
@end

@implementation AppDelegate

// The application exists so PlugInKit can register the effect; its only user
// interface is the installation window, so the menu carries nothing else.
- (void)buildMenu {
  NSDictionary *install = NSBundle.mainBundle.infoDictionary[KFInstallMetadataKey];
  NSString *product = install[KFProductNameKey] ?: NSBundle.mainBundle.infoDictionary[@"CFBundleName"];

  NSMenu *applicationMenu = [[NSMenu alloc] init];
  [applicationMenu addItemWithTitle:[NSString stringWithFormat:@"About %@", product]
                             action:@selector(orderFrontStandardAboutPanel:)
                      keyEquivalent:@""];
  [applicationMenu addItem:NSMenuItem.separatorItem];
  [applicationMenu addItemWithTitle:[NSString stringWithFormat:@"Hide %@", product]
                             action:@selector(hide:)
                      keyEquivalent:@"h"];
  [applicationMenu addItemWithTitle:[NSString stringWithFormat:@"Quit %@", product]
                             action:@selector(terminate:)
                      keyEquivalent:@"q"];

  NSMenuItem *applicationItem = [[NSMenuItem alloc] init];
  applicationItem.submenu = applicationMenu;
  NSMenu *mainMenu = [[NSMenu alloc] init];
  [mainMenu addItem:applicationItem];
  NSApp.mainMenu = mainMenu;
}

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
  [self buildMenu];
  self.controller = [[KFUninstallWindowController alloc] init];
  [self.controller showWindow:self];
  [NSApp activate];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)application {
  return YES;
}

@end
