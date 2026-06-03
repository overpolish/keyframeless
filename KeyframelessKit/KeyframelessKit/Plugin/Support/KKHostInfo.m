/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKHostInfo.h"

#import "KKLog.h"

@implementation KKHostInfo

+ (BOOL)isRunningInFinalCut {
  return [[self shared].hostID isEqualToString:@"com.apple.FinalCut"];
}

+ (BOOL)isRunningInWorkflowExtension {
  return [self shared].isWorkflowExtension;
}

+ (instancetype)shared {
  static KKHostInfo *instance = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    instance = [[KKHostInfo alloc] init];
  });
  return instance;
}

// Fits the host viewer/canvas to its window via System Events. Both paths are
// locale-proof: the host menu titles localize, so we navigate by structural
// position (the menu order is identical across UI languages) instead of by
// title.
//
// FCP: Window is the second-to-last menu bar item (Help is last); within it
// "Go To" is menu item 13 and "Viewer" is item 5 of that submenu. Zoom to Fit
// is then triggered via its keyboard shortcut (Shift+Z, also
// locale-independent). Captured from FCP 11; re-capture the indices if a
// future FCP reorders the Window menu.
//
// Motion: View is the third-to-last menu bar item (Window, Help follow);
// within it "Zoom Level" is menu item 3 and "Fit in Window" is item 10 of
// that submenu. Re-capture if a future Motion reorders the View menu.
+ (void)zoomHostViewerToFit {
  BOOL fcp = [self isRunningInFinalCut];
  NSString *src =
      fcp ? @"tell application \"System Events\"\n"
             "  tell process \"Final Cut Pro\"\n"
             "    set winItem to menu bar item ((count of menu bar items of "
             "menu bar 1) - 1) of menu bar 1\n"
             "    tell menu 1 of winItem\n"
             "      tell menu item 13\n"
             "        tell menu 1\n"
             "          click menu item 5\n"
             "        end tell\n"
             "      end tell\n"
             "    end tell\n"
             "    delay 0.1\n"
             "    set frontmost to true\n"
             "    keystroke \"z\" using {shift down}\n"
             "  end tell\n"
             "end tell"
          : @"tell application \"System Events\"\n"
             "  tell process \"Motion\"\n"
             "    set viewItem to menu bar item ((count of menu bar items of "
             "menu bar 1) - 2) of menu bar 1\n"
             "    tell menu 1 of viewItem\n"
             "      tell menu item 3\n"
             "        tell menu 1\n"
             "          click menu item 10\n"
             "        end tell\n"
             "      end tell\n"
             "    end tell\n"
             "  end tell\n"
             "end tell";
  NSAppleScript *script = [[NSAppleScript alloc] initWithSource:src];
  NSDictionary *err = nil;
  [script executeAndReturnError:&err];
  if (err)
    KKLogWarn(@"[KKHostInfo] zoom-to-fit AppleScript error (%@): %@",
              fcp ? @"FCP" : @"Motion", err);
}

@end
