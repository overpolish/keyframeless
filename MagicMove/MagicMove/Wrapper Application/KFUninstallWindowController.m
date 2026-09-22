/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KFUninstallWindowController.h"

#import "KFInstallation.h"
#import "KFUninstaller.h"

static const CGFloat KFContentWidth = 340;

static NSTextField *KFLabel(NSString *text, NSFont *font, NSColor *color) {
  NSTextField *label = [NSTextField labelWithString:text];
  label.font = font;
  label.textColor = color;
  label.lineBreakMode = NSLineBreakByWordWrapping;
  label.preferredMaxLayoutWidth = KFContentWidth;
  return label;
}

@interface KFUninstallWindowController ()
@property(nonatomic) KFInstallation *installation;
@property(nonatomic) NSButton *keepPreferences;
@property(nonatomic) NSButton *uninstall;
@end

@implementation KFUninstallWindowController

- (instancetype)init {
  NSWindow *window = [[NSWindow alloc]
      initWithContentRect:NSMakeRect(0, 0, KFContentWidth, 200)
                styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable |
                          NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskFullSizeContentView
                  backing:NSBackingStoreBuffered
                    defer:NO];
  // The window is one short panel, so the title bar carries nothing: the
  // content runs the full height behind it and only the close button shows.
  window.titlebarAppearsTransparent = YES;
  window.titleVisibility = NSWindowTitleHidden;
  self = [super initWithWindow:window];
  if (self) {
    [self reload];
    window.title = self.installation.productName;
    [self build];
  }
  return self;
}

- (void)reload {
  NSBundle *bundle = NSBundle.mainBundle;
  NSString *package = [KFInstallation packageIdentifierForBundle:bundle];
  self.installation =
      [KFInstallation installationForBundle:bundle.bundleURL
                                   metadata:bundle.infoDictionary[KFInstallMetadataKey]
                                       home:[NSURL fileURLWithPath:NSHomeDirectory()]
                                 systemRoot:[NSURL fileURLWithPath:@"/"]
                                    package:package
                             receiptPresent:package && [KFInstallation receiptPresentForPackage:package]];
}

- (void)build {
  NSImageView *icon = [NSImageView imageViewWithImage:NSApp.applicationIconImage];
  [icon.widthAnchor constraintEqualToConstant:64].active = YES;
  [icon.heightAnchor constraintEqualToConstant:64].active = YES;

  // With nothing installed there is nothing to explain, so the subtitle says
  // so instead of carrying a version that applies to no files.
  NSString *version = NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"";
  NSString *subtitle =
      self.installation.isInstalled ? [NSString stringWithFormat:@"Version %@", version] : @"Not installed";
  NSStackView *titles = [NSStackView stackViewWithViews:@[
    KFLabel(self.installation.productName, [NSFont systemFontOfSize:20 weight:NSFontWeightSemibold],
            NSColor.labelColor),
    KFLabel(subtitle, [NSFont systemFontOfSize:11], NSColor.secondaryLabelColor),
  ]];
  titles.orientation = NSUserInterfaceLayoutOrientationVertical;
  titles.alignment = NSLayoutAttributeLeading;
  titles.spacing = 2;

  NSStackView *header = [NSStackView stackViewWithViews:@[ icon, titles ]];
  header.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  header.alignment = NSLayoutAttributeCenterY;
  header.spacing = 14;

  self.keepPreferences = [NSButton checkboxWithTitle:@"Keep saved defaults" target:nil action:nil];
  self.keepPreferences.hidden = !self.installation.isInstalled;

  self.uninstall = [NSButton buttonWithTitle:@"Uninstall..." target:self action:@selector(confirmUninstall:)];
  self.uninstall.keyEquivalent = @"\r";
  self.uninstall.enabled = self.installation.isInstalled;
  // The checkbox qualifies the button, so they share a row: option on the
  // left, action on the right.
  NSView *spacer = [[NSView alloc] initWithFrame:NSZeroRect];
  [spacer setContentHuggingPriority:NSLayoutPriorityDefaultLow - 1
                     forOrientation:NSLayoutConstraintOrientationHorizontal];
  NSStackView *actions = [NSStackView stackViewWithViews:@[ self.keepPreferences, spacer, self.uninstall ]];
  actions.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  actions.alignment = NSLayoutAttributeCenterY;

  NSStackView *content = [NSStackView stackViewWithViews:@[ header, actions ]];
  content.orientation = NSUserInterfaceLayoutOrientationVertical;
  content.alignment = NSLayoutAttributeLeading;
  content.spacing = 18;
  // Extra room at the top: the content now runs under the title bar, where
  // the window buttons sit.
  content.edgeInsets = NSEdgeInsetsMake(44, 24, 20, 24);
  [content.widthAnchor constraintEqualToConstant:KFContentWidth].active = YES;
  [actions.widthAnchor constraintEqualToAnchor:content.widthAnchor constant:-48].active = YES;

  self.window.contentView = content;
  [self.window setContentSize:content.fittingSize];
  [self.window center];
}

// Removing a registered plug-in while a host holds it leaves the host talking
// to a bundle that is no longer there, so name the ones that are open.
- (NSString *)runningHosts {
  NSMutableArray<NSString *> *names = [NSMutableArray array];
  for (NSRunningApplication *application in NSWorkspace.sharedWorkspace.runningApplications) {
    if ([application.bundleIdentifier isEqualToString:@"com.apple.FinalCut"])
      [names addObject:@"Final Cut Pro"];
    else if ([application.bundleIdentifier isEqualToString:@"com.apple.motionapp"])
      [names addObject:@"Motion"];
  }
  return [names componentsJoinedByString:@" and "];
}

- (void)confirmUninstall:(id)sender {
  NSMutableString *detail =
      [NSMutableString stringWithString:@"This removes the plug-in and its Final Cut Pro template from this Mac."];
  NSString *hosts = [self runningHosts];
  if (hosts.length)
    [detail appendFormat:@" Quit %@ first so the plug-in is released.", hosts];
  if (self.installation.requiresAdministrator)
    [detail appendString:@" You will be asked for an administrator password."];

  NSAlert *alert = [[NSAlert alloc] init];
  alert.messageText = [NSString stringWithFormat:@"Remove %@?", self.installation.productName];
  alert.informativeText = detail;
  [alert addButtonWithTitle:@"Uninstall"];
  [alert addButtonWithTitle:@"Cancel"];
  alert.buttons.firstObject.hasDestructiveAction = YES;
  if ([alert runModal] != NSAlertFirstButtonReturn)
    return;
  [self performUninstall];
}

- (void)performUninstall {
  NSURL *services = [NSBundle.mainBundle.bundleURL URLByAppendingPathComponent:@"Contents/PlugIns"];
  NSError *error = nil;
  BOOL removed = [KFUninstaller removeInstallation:self.installation
                                  serviceDirectory:services
                                 removePreferences:self.keepPreferences.state != NSControlStateValueOn
                                             error:&error];
  if (!removed && error.code == KFUninstallErrorCancelled)
    return;

  NSAlert *alert = [[NSAlert alloc] init];
  if (removed) {
    alert.messageText = [NSString stringWithFormat:@"%@ has been removed.", self.installation.productName];
    alert.informativeText = @"Restart Final Cut Pro or Motion if either is open.";
  } else {
    alert.alertStyle = NSAlertStyleCritical;
    alert.messageText = [NSString stringWithFormat:@"%@ could not be removed.", self.installation.productName];
    alert.informativeText = error.localizedDescription ?: @"";
  }
  [alert runModal];
  if (removed) {
    [NSApp terminate:self];
    return;
  }
  // A partial removal changed what is left, and trying again from the old plan
  // would repeat work that has already succeeded.
  [self reload];
  [self build];
}

@end
