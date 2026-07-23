/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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
