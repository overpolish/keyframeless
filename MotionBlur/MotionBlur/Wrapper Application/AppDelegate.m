/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "AppDelegate.h"
#import <KeyframelessKit/KeyframelessKit.h>

@interface AppDelegate ()

@property(weak) IBOutlet NSWindow *window;
@end

@implementation AppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)aNotification {
  [[KKUpdateChecker shared] checkWithCompletion:nil];
}

- (void)applicationWillTerminate:(NSNotification *)aNotification {
}

@end