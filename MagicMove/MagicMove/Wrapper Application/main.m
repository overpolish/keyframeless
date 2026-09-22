/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import <Cocoa/Cocoa.h>

#import "AppDelegate.h"

// The interface is built in code, so there is no main nib to load and the
// delegate has to be installed before the run loop starts.
int main(void) {
  @autoreleasepool {
    NSApplication *application = NSApplication.sharedApplication;
    // NSApplication holds its delegate weakly.
    static AppDelegate *delegate;
    delegate = [[AppDelegate alloc] init];
    application.delegate = delegate;
    [application setActivationPolicy:NSApplicationActivationPolicyRegular];
    [application run];
  }
  return 0;
}
