/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerListView.h"
#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>

// Flipped document view so rows lay out top-to-bottom when they're added.
@interface _KKCanvasLayerDocView : NSView
@end
@implementation _KKCanvasLayerDocView
- (BOOL)isFlipped {
  return YES;
}
@end

@implementation CanvasLayerListView

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    [self _build];
  }
  return self;
}

- (void)_build {
  // Match the popover's content inset.
  const CGFloat pad = KKPaddingMD;

  NSTextField *title = [NSTextField labelWithString:@"Layers"];
  title.font = [NSFont systemFontOfSize:13 weight:NSFontWeightSemibold];
  title.textColor = NSColor.secondaryLabelColor;
  title.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:title];

  // Recessed well that holds the rows (and the empty state for now).
  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:NSZeroRect];
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  scroll.hasVerticalScroller = YES;
  scroll.hasHorizontalScroller = NO;
  scroll.autohidesScrollers = YES;
  scroll.drawsBackground = YES;
  scroll.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.2];
  scroll.borderType = NSNoBorder;
  scroll.wantsLayer = YES;
  scroll.layer.cornerRadius = KKRadiusMD;
  scroll.layer.masksToBounds = YES;
  [self addSubview:scroll];

  _KKCanvasLayerDocView *doc =
      [[_KKCanvasLayerDocView alloc] initWithFrame:NSZeroRect];
  doc.translatesAutoresizingMaskIntoConstraints = NO;
  scroll.documentView = doc;

  // Empty state, centered over the well.
  NSImageView *icon = [NSImageView
      imageViewWithImage:[NSImage
                             imageWithSystemSymbolName:@"square.3.layers.3d.slash"
                              accessibilityDescription:nil]];
  icon.contentTintColor =
      [[NSColor inspectorLabel] colorWithAlphaComponent:0.45];
  [icon.widthAnchor constraintEqualToConstant:KKIconSizeSM].active = YES;
  [icon.heightAnchor constraintEqualToConstant:KKIconSizeSM].active = YES;

  NSTextField *empty = [NSTextField labelWithString:@"No shapes"];
  empty.font = [NSFont systemFontOfSize:KKFontSizeSM weight:NSFontWeightMedium];
  empty.textColor = [[NSColor inspectorLabel] colorWithAlphaComponent:0.45];

  NSStackView *emptyStack = [NSStackView stackViewWithViews:@[ icon, empty ]];
  emptyStack.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  emptyStack.spacing = KKSpacingSM;
  emptyStack.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:emptyStack];

  NSClipView *clip = scroll.contentView;
  [NSLayoutConstraint activateConstraints:@[
    [title.topAnchor constraintEqualToAnchor:self.topAnchor constant:pad],
    [title.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                        constant:pad],

    [scroll.topAnchor constraintEqualToAnchor:title.bottomAnchor
                                     constant:KKSpacingSM],
    [scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                         constant:pad],
    [scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                          constant:-pad],
    [scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor
                                        constant:-pad],

    // No rows yet: the doc fills the clip so nothing scrolls.
    [doc.leadingAnchor constraintEqualToAnchor:clip.leadingAnchor],
    [doc.trailingAnchor constraintEqualToAnchor:clip.trailingAnchor],
    [doc.topAnchor constraintEqualToAnchor:clip.topAnchor],
    [doc.bottomAnchor constraintEqualToAnchor:clip.bottomAnchor],

    [emptyStack.centerXAnchor constraintEqualToAnchor:scroll.centerXAnchor],
    [emptyStack.centerYAnchor constraintEqualToAnchor:scroll.centerYAnchor],
  ]];
}

@end
