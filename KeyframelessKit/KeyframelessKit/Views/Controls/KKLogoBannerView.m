/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLogoBannerView.h"
#import "KKFonts.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"
#import "KKUpdateChecker.h"
#import "KKLocalized.h"
#import <AppKit/AppKit.h>

static const CGFloat KKLogoSize = 28.0;
static const CGFloat KKHelpButtonSize = 18.0;

#if DEBUG
// Flip to YES + rebuild to force the update banner in FCP (env vars don't reach
// an FCP-hosted plugin, so this is a compile-time switch).
static const BOOL kKKForceUpdateBanner = NO;
#endif

@implementation KKLogoBannerView {
  NSButton *_helpButton;
  NSButton *_changelogButton;
  NSButton *_feedbackButton;
  NSView *_leadingAccessory;
  NSStackView *_leftStack;
}

- (NSRect)effectHeaderScreenRect {
  if (!self.window)
    return NSZeroRect;
  NSRect scr = [self.window convertRectToScreen:[self convertRect:self.bounds
                                                           toView:nil]];
  if (NSIsEmptyRect(scr))
    return NSZeroRect;
  // Header sits directly above the banner (same width); approximate it as a
  // one-row strip just above the banner's top edge. Screen coords are y-up,
  // so "above" is +y from NSMaxY.
  static const CGFloat kGap = 2.0;
  return NSMakeRect(NSMinX(scr), NSMaxY(scr) + kGap, NSWidth(scr),
                    KKInspectorRowHeight);
}

- (instancetype)init {
  self = [super initWithFrame:NSMakeRect(0, 0, 0, KKInspectorRowHeight * 2)];
  if (self) {
    self.autoresizingMask =
        NSViewWidthSizable | NSViewHeightSizable | NSViewMinYMargin;

    NSBundle *frameworkBundle =
        [NSBundle bundleForClass:[KKLogoBannerView class]];
    NSImage *logo = [[NSImage alloc]
        initByReferencingFile:[frameworkBundle
                                  pathForResource:@"keyframeless-logo"
                                           ofType:@"png"]];

    NSImageView *logoView = [[NSImageView alloc] init];
    logoView.translatesAutoresizingMaskIntoConstraints = NO;
    logoView.imageScaling = NSImageScaleProportionallyUpOrDown;
    logoView.image = logo;
    [self addSubview:logoView];

    [NSLayoutConstraint activateConstraints:@[
      [logoView.centerXAnchor constraintEqualToAnchor:self.centerXAnchor],
      [logoView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [logoView.widthAnchor constraintEqualToConstant:KKLogoSize],
      [logoView.heightAnchor constraintEqualToConstant:KKLogoSize],
    ]];

    // Left controls: [help (optional)] [changelog] [feedback], in a leading
    // stack.
    _leftStack = [[NSStackView alloc] init];
    _leftStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    _leftStack.spacing = KKSpacingMD;
    _leftStack.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_leftStack];
    [NSLayoutConstraint activateConstraints:@[
      [_leftStack.leadingAnchor
          constraintEqualToAnchor:self.leadingAnchor
                         constant:KKInspectorHorizontalInset],
      [_leftStack.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    ]];

    if ([KKUpdateChecker shared].notesURL) {
      NSImage *icon = [NSImage
          imageWithSystemSymbolName:
              @"clock.arrow.trianglehead.counterclockwise.rotate.90"
           accessibilityDescription:
               KKLoc(@"What's New", @"Changelog button accessibility label")];
      _changelogButton = [NSButton buttonWithImage:icon
                                            target:self
                                            action:@selector(openNotesURL:)];
      _changelogButton.bezelStyle = NSBezelStyleAccessoryBarAction;
      _changelogButton.bordered = NO;
      _changelogButton.contentTintColor = [NSColor inspectorLabel];
      _changelogButton.toolTip =
          KKLoc(@"What's New", @"Changelog button tooltip");
      _changelogButton.translatesAutoresizingMaskIntoConstraints = NO;
      [NSLayoutConstraint activateConstraints:@[
        [_changelogButton.widthAnchor
            constraintEqualToConstant:KKHelpButtonSize],
        [_changelogButton.heightAnchor
            constraintEqualToConstant:KKHelpButtonSize],
      ]];
      [_leftStack addArrangedSubview:_changelogButton];
    }

    if ([KKUpdateChecker shared].feedbackURL) {
      NSImage *icon = [NSImage
          imageWithSystemSymbolName:@"exclamationmark.bubble"
           accessibilityDescription:
               KKLoc(@"Send feedback", @"Feedback button accessibility label")];
      _feedbackButton = [NSButton buttonWithImage:icon
                                           target:self
                                           action:@selector(openFeedbackURL:)];
      _feedbackButton.bezelStyle = NSBezelStyleAccessoryBarAction;
      _feedbackButton.bordered = NO;
      _feedbackButton.contentTintColor = [NSColor inspectorLabel];
      _feedbackButton.toolTip =
          KKLoc(@"Send feedback", @"Feedback button tooltip");
      _feedbackButton.translatesAutoresizingMaskIntoConstraints = NO;
      [NSLayoutConstraint activateConstraints:@[
        [_feedbackButton.widthAnchor
            constraintEqualToConstant:KKHelpButtonSize],
        [_feedbackButton.heightAnchor
            constraintEqualToConstant:KKHelpButtonSize],
      ]];
      [_leftStack addArrangedSubview:_feedbackButton];
    }

    BOOL updateAvailable = [KKUpdateChecker shared].updateAvailable;
    NSString *version = [KKUpdateChecker shared].availableVersion;
#if DEBUG
    if (kKKForceUpdateBanner) {
      updateAvailable = YES;
      version = version ?: @"9.9.9";
    }
#endif
    if (updateAvailable) {
      NSString *title =
          version
              ? [NSString
                    stringWithFormat:KKLoc(
                                         @"v%@ available",
                                         @"Update banner: version X available"),
                                     version]
              : KKLoc(@"Update available", @"Update banner, no version");
      NSButton *button = [NSButton buttonWithTitle:title
                                            target:self
                                            action:@selector(openDownloadURL:)];
      button.translatesAutoresizingMaskIntoConstraints = NO;
      button.bezelStyle = NSBezelStyleRecessed;
      button.bordered = NO;
      button.font =
          [NSFont systemFontOfSize:[KKFonts inspectorLabelFont].pointSize
                            weight:NSFontWeightMedium];
      button.contentTintColor = [NSColor accent];
      button.toolTip = [NSString
          stringWithFormat:KKLoc(@"You have %@",
                                 @"Update banner tooltip: installed version"),
                           [KKUpdateChecker shared].currentVersion];
      [self addSubview:button];

      [NSLayoutConstraint activateConstraints:@[
        [button.trailingAnchor
            constraintEqualToAnchor:self.trailingAnchor
                           constant:-KKInspectorHorizontalInset],
        [button.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      ]];
    }
  }
  return self;
}

- (void)setLeadingAccessoryView:(NSView *)view {
  if (_leadingAccessory == view)
    return;
  if (_leadingAccessory)
    [_leftStack removeArrangedSubview:_leadingAccessory];
  _leadingAccessory = view;
  if (view) {
    view.translatesAutoresizingMaskIntoConstraints = NO;
    [_leftStack insertArrangedSubview:view atIndex:0];
  }
}

- (void)setOnHelpTap:(void (^)(void))onHelpTap {
  _onHelpTap = [onHelpTap copy];

  if (_onHelpTap && !_helpButton) {
    NSImage *icon = [NSImage
        imageWithSystemSymbolName:@"questionmark.circle"
         accessibilityDescription:KKLoc(@"Help",
                                        @"Help button accessibility label")];
    _helpButton = [NSButton buttonWithImage:icon
                                     target:self
                                     action:@selector(_helpClicked:)];
    _helpButton.bezelStyle = NSBezelStyleAccessoryBarAction;
    _helpButton.bordered = NO;
    _helpButton.contentTintColor = [NSColor inspectorLabel];
    _helpButton.toolTip = KKLoc(@"Open help", @"Help button tooltip");
    _helpButton.translatesAutoresizingMaskIntoConstraints = NO;
    [NSLayoutConstraint activateConstraints:@[
      [_helpButton.widthAnchor constraintEqualToConstant:KKHelpButtonSize],
      [_helpButton.heightAnchor constraintEqualToConstant:KKHelpButtonSize],
    ]];
    NSInteger helpIndex = _leadingAccessory ? 1 : 0;
    [_leftStack insertArrangedSubview:_helpButton atIndex:helpIndex];
  } else if (!_onHelpTap && _helpButton) {
    [_helpButton removeFromSuperview];
    _helpButton = nil;
  }
}

- (void)_helpClicked:(id)sender {
  if (_onHelpTap)
    _onHelpTap();
}

- (void)openDownloadURL:(id)sender {
  KKUpdateChecker *checker = [KKUpdateChecker shared];
  NSURL *url = checker.downloadURL ?: checker.notesURL;
  if (url) {
    [[NSWorkspace sharedWorkspace] openURL:url];
  }
}

- (void)openNotesURL:(id)sender {
  NSURL *url = [KKUpdateChecker shared].notesURL;
  if (url) {
    [[NSWorkspace sharedWorkspace] openURL:url];
  }
}

- (void)openFeedbackURL:(id)sender {
  NSURL *url = [KKUpdateChecker shared].feedbackURL;
  if (url) {
    [[NSWorkspace sharedWorkspace] openURL:url];
  }
}

@end
