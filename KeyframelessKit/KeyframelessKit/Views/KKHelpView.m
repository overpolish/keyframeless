/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKHelpView.h"
#import "../Style/KKFonts.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import "KKHelpSection.h"

@interface KKFlippedClipView : NSClipView
@end

@implementation KKFlippedClipView
- (BOOL)isFlipped {
  return YES;
}
@end

@interface KKHelpShortcutsGrid : NSGridView
@end

@implementation KKHelpShortcutsGrid

- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];
  if (self.numberOfRows < 2)
    return;

  NSColor *line = [[NSColor inspectorLabel] colorWithAlphaComponent:0.10];
  [line setStroke];
  NSBezierPath *path = [NSBezierPath bezierPath];
  path.lineWidth = 1.0;

  for (NSInteger r = 0; r < self.numberOfRows - 1; r++) {
    NSView *aCell = [self cellAtColumnIndex:0 rowIndex:r].contentView;
    NSView *bCell = [self cellAtColumnIndex:0 rowIndex:r + 1].contentView;
    if (!aCell || !bCell)
      continue;
    CGFloat yBottomA = NSMinY(aCell.frame);
    CGFloat yTopB = NSMaxY(bCell.frame);
    CGFloat y = (yBottomA + yTopB) * 0.5;
    [path moveToPoint:NSMakePoint(0, y)];
    [path lineToPoint:NSMakePoint(self.bounds.size.width, y)];
  }
  [path stroke];
}

@end

@interface KKHelpBackgroundView : NSView
@end

@implementation KKHelpBackgroundView

- (BOOL)isFlipped {
  return NO;
}

- (void)drawRect:(NSRect)dirtyRect {
  [[NSColor inspectorBackground] setFill];
  NSRectFill(self.bounds);

  NSBundle *bundle = [NSBundle bundleForClass:[KKHelpBackgroundView class]];
  NSImage *logo = [[NSImage alloc]
      initByReferencingFile:[bundle pathForResource:@"keyframeless-logo"
                                             ofType:@"png"]];
  if (!logo)
    return;

  CGFloat side = MIN(self.bounds.size.width, self.bounds.size.height) * 0.9;
  NSGraphicsContext *gc = [NSGraphicsContext currentContext];
  [gc saveGraphicsState];

  NSAffineTransform *t = [NSAffineTransform transform];
  // Tuck the logo into the bottom-right corner with a slice peeking past
  // the right edge.
  [t translateXBy:self.bounds.size.width - side * 0.75 yBy:-side * 0.25];
  [t rotateByDegrees:-18.0];
  [t concat];

  NSRect target = NSMakeRect(0, 0, side, side);
  [logo drawInRect:target
          fromRect:NSZeroRect
         operation:NSCompositingOperationSourceOver
          fraction:0.06];

  [gc restoreGraphicsState];
}

@end

static const CGFloat KKHelpPagePadding = 24.0;
static const CGFloat KKHelpSectionGap = 24.0;
static const CGFloat KKHelpAfterTitleGap = 10.0;
static const CGFloat KKHelpKeyColumnMin = 170.0;

@implementation KKHelpView

- (instancetype)initWithSections:(NSArray<KKHelpSection *> *)sections {
  self = [super initWithFrame:NSMakeRect(0, 0, 480, 520)];
  if (!self)
    return nil;
  self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

  KKHelpBackgroundView *bg =
      [[KKHelpBackgroundView alloc] initWithFrame:self.bounds];
  bg.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  [self addSubview:bg];

  NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:self.bounds];
  scroll.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  scroll.hasVerticalScroller = YES;
  scroll.hasHorizontalScroller = NO;
  scroll.drawsBackground = NO;
  scroll.borderType = NSNoBorder;
  scroll.automaticallyAdjustsContentInsets = NO;
  scroll.contentInsets = NSEdgeInsetsMake(KKHelpPagePadding, KKHelpPagePadding,
                                          KKHelpPagePadding, KKHelpPagePadding);
  KKFlippedClipView *clip = [[KKFlippedClipView alloc] init];
  clip.drawsBackground = NO;
  scroll.contentView = clip;
  [self addSubview:scroll];

  NSStackView *page = [[NSStackView alloc] initWithFrame:NSZeroRect];
  page.orientation = NSUserInterfaceLayoutOrientationVertical;
  page.alignment = NSLayoutAttributeLeading;
  page.spacing = KKHelpSectionGap;
  page.translatesAutoresizingMaskIntoConstraints = NO;

  for (KKHelpSection *section in sections)
    [page addArrangedSubview:[self _viewForSection:section]];

  scroll.documentView = page;
  // Pin width so the document view tracks the scroll view (vertical scroll
  // only). Otherwise NSStackView default-sizes to its content.
  [NSLayoutConstraint activateConstraints:@[
    [page.leadingAnchor
        constraintEqualToAnchor:scroll.contentView.leadingAnchor],
    [page.trailingAnchor
        constraintEqualToAnchor:scroll.contentView.trailingAnchor],
    [page.topAnchor constraintEqualToAnchor:scroll.contentView.topAnchor],
    [page.widthAnchor constraintEqualToAnchor:scroll.contentView.widthAnchor],
  ]];

  return self;
}

- (NSView *)_viewForSection:(KKHelpSection *)section {
  NSStackView *stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = KKHelpAfterTitleGap;

  NSTextField *title = [NSTextField labelWithString:section.title];
  title.font = [NSFont systemFontOfSize:18.0 weight:NSFontWeightSemibold];
  title.textColor = [NSColor inspectorLabel];
  [stack addArrangedSubview:title];

  if (section.tips.count > 0)
    [stack addArrangedSubview:[self _bulletListForTips:section.tips]];

  if (section.shortcuts.count > 0) {
    [stack addArrangedSubview:[self _subheading:@"Shortcuts"]];
    [stack addArrangedSubview:[self _gridForShortcuts:section.shortcuts]];
  }

  return stack;
}

- (NSView *)_subheading:(NSString *)text {
  NSTextField *label = [NSTextField labelWithString:text];
  label.font = [NSFont systemFontOfSize:14.0 weight:NSFontWeightSemibold];
  label.textColor = [[NSColor inspectorLabel] colorWithAlphaComponent:0.55];
  return label;
}

- (NSView *)_bulletListForTips:(NSArray<NSAttributedString *> *)tips {
  NSStackView *list = [[NSStackView alloc] initWithFrame:NSZeroRect];
  list.orientation = NSUserInterfaceLayoutOrientationVertical;
  list.alignment = NSLayoutAttributeLeading;
  list.spacing = 6.0;

  for (NSAttributedString *tip in tips) {
    NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeFirstBaseline;
    row.spacing = 8.0;

    NSTextField *bullet = [NSTextField labelWithString:@"•"];
    bullet.font = [NSFont systemFontOfSize:13.0];
    bullet.textColor = [NSColor inspectorLabel];
    [row addArrangedSubview:bullet];

    NSTextField *body = [NSTextField labelWithAttributedString:tip];
    body.lineBreakMode = NSLineBreakByWordWrapping;
    body.maximumNumberOfLines = 0;
    body.preferredMaxLayoutWidth = 380.0;
    body.textColor = [NSColor inspectorLabel];
    [body setContentHuggingPriority:NSLayoutPriorityDefaultLow
                     forOrientation:NSLayoutConstraintOrientationHorizontal];
    [row addArrangedSubview:body];

    [list addArrangedSubview:row];
  }
  return list;
}

- (NSView *)_gridForShortcuts:(NSArray<KKHelpShortcut *> *)shortcuts {
  KKHelpShortcutsGrid *grid =
      [[KKHelpShortcutsGrid alloc] initWithFrame:NSZeroRect];
  grid.translatesAutoresizingMaskIntoConstraints = NO;
  grid.rowSpacing = 8.0;
  grid.columnSpacing = 14.0;

  for (KKHelpShortcut *sc in shortcuts) {
    NSTextField *keys = [NSTextField labelWithAttributedString:sc.keys];
    NSTextField *desc = [NSTextField labelWithAttributedString:sc.desc];
    desc.lineBreakMode = NSLineBreakByWordWrapping;
    desc.maximumNumberOfLines = 0;
    desc.preferredMaxLayoutWidth = 320.0;
    desc.textColor = [NSColor inspectorLabel];
    [grid addRowWithViews:@[ keys, desc ]];
  }
  if (grid.numberOfColumns >= 1) {
    NSGridColumn *keyCol = [grid columnAtIndex:0];
    keyCol.xPlacement = NSGridCellPlacementTrailing;
    keyCol.width = KKHelpKeyColumnMin;
  }
  return grid;
}

@end
