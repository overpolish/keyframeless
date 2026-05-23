/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLogoBannerView.h"
#import "../Style/KKFonts.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import "../Update/KKUpdateChecker.h"
#import <AppKit/AppKit.h>

static const CGFloat KKLogoSize = 28.0;
static const CGFloat KKHelpButtonSize = 18.0;

@implementation KKLogoBannerView {
  NSButton *_helpButton;
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

    if ([KKUpdateChecker shared].updateAvailable) {
      NSImage *dlIcon =
          [NSImage imageWithSystemSymbolName:@"arrow.down.circle.fill"
                    accessibilityDescription:@"Download"];

      NSButton *button = [NSButton buttonWithTitle:@" New Version"
                                             image:dlIcon
                                            target:self
                                            action:@selector(openDownloadURL:)];
      button.translatesAutoresizingMaskIntoConstraints = NO;
      button.bezelStyle = NSBezelStyleRecessed;
      button.bordered = NO;
      button.imagePosition = NSImageLeft;
      button.font =
          [NSFont systemFontOfSize:[KKFonts inspectorLabelFont].pointSize
                            weight:NSFontWeightMedium];
      button.contentTintColor = [NSColor accent];
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

- (void)setOnHelpTap:(void (^)(void))onHelpTap {
  _onHelpTap = [onHelpTap copy];

  if (_onHelpTap && !_helpButton) {
    NSImage *icon = [NSImage imageWithSystemSymbolName:@"questionmark.circle"
                              accessibilityDescription:@"Help"];
    _helpButton = [NSButton buttonWithImage:icon
                                     target:self
                                     action:@selector(_helpClicked:)];
    _helpButton.bezelStyle = NSBezelStyleAccessoryBarAction;
    _helpButton.bordered = NO;
    _helpButton.contentTintColor = [NSColor inspectorLabel];
    _helpButton.toolTip = @"Open help";
    _helpButton.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_helpButton];
    [NSLayoutConstraint activateConstraints:@[
      [_helpButton.leadingAnchor
          constraintEqualToAnchor:self.leadingAnchor
                         constant:KKInspectorHorizontalInset],
      [_helpButton.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_helpButton.widthAnchor constraintEqualToConstant:KKHelpButtonSize],
      [_helpButton.heightAnchor constraintEqualToConstant:KKHelpButtonSize],
    ]];
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
  NSURL *url = [KKUpdateChecker shared].downloadURL;
  if (url) {
    [[NSWorkspace sharedWorkspace] openURL:url];
  }
}

@end
