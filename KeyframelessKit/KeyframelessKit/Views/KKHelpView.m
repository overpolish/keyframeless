/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKHelpView.h"
#import "../Style/KKFonts.h"
#import "../Style/KKTokens.h"
#import "../Style/NSColor+KKColors.h"
#import "KKHelpSection.h"
#import "KKPaddedScrollView.h"

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

  NSStackView *page = [[NSStackView alloc] initWithFrame:NSZeroRect];
  page.orientation = NSUserInterfaceLayoutOrientationVertical;
  page.alignment = NSLayoutAttributeLeading;
  page.spacing = KKHelpSectionGap;

  for (NSUInteger i = 0; i < sections.count; i++) {
    if (i > 0) {
      NSView *divider = [[NSView alloc] init];
      divider.wantsLayer = YES;
      divider.layer.backgroundColor =
          [[[NSColor inspectorLabel] colorWithAlphaComponent:0.10] CGColor];
      divider.translatesAutoresizingMaskIntoConstraints = NO;
      [divider.heightAnchor constraintEqualToConstant:1.0].active = YES;
      [page addArrangedSubview:divider];
      [divider.widthAnchor constraintEqualToAnchor:page.widthAnchor].active =
          YES;
    }
    NSView *sv = [self _viewForSection:sections[i]];
    [page addArrangedSubview:sv];
    [sv.widthAnchor constraintEqualToAnchor:page.widthAnchor].active = YES;
  }

  KKPaddedScrollView *scroll =
      [[KKPaddedScrollView alloc] initWithDocumentView:page
                                               padding:KKHelpPagePadding];
  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:scroll];
  [NSLayoutConstraint activateConstraints:@[
    [scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [scroll.topAnchor constraintEqualToAnchor:self.topAnchor],
    [scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
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

  if (section.icon) {
    NSStackView *titleRow = [[NSStackView alloc] initWithFrame:NSZeroRect];
    titleRow.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    titleRow.alignment = NSLayoutAttributeCenterY;
    titleRow.spacing = 8.0;
    NSImageView *iconView = [NSImageView imageViewWithImage:section.icon];
    iconView.symbolConfiguration = [NSImageSymbolConfiguration
        configurationWithPointSize:18.0
                            weight:NSFontWeightSemibold];
    iconView.contentTintColor = [NSColor inspectorLabel];
    [titleRow addArrangedSubview:iconView];
    [titleRow addArrangedSubview:title];
    [stack addArrangedSubview:titleRow];
  } else {
    [stack addArrangedSubview:title];
  }

  if (section.tips.count > 0) {
    NSView *bullets = [self _bulletListForTips:section.tips];
    [stack addArrangedSubview:bullets];
    [bullets.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active =
        YES;
  }

  if (section.shortcuts.count > 0) {
    [stack addArrangedSubview:[self _subheading:@"Shortcuts"]];
    NSView *grid = [self _gridForShortcuts:section.shortcuts];
    [stack addArrangedSubview:grid];
    [grid.widthAnchor constraintEqualToAnchor:stack.widthAnchor].active = YES;
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
    if ([tip.string isEqualToString:@"---"]) {
      NSView *line = [[NSView alloc] init];
      line.wantsLayer = YES;
      line.layer.backgroundColor =
          [[[NSColor inspectorLabel] colorWithAlphaComponent:0.10] CGColor];
      line.translatesAutoresizingMaskIntoConstraints = NO;
      [line.heightAnchor constraintEqualToConstant:1.0].active = YES;
      [list addArrangedSubview:line];
      continue;
    }
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
    body.textColor = [NSColor inspectorLabel];
    [body setContentHuggingPriority:NSLayoutPriorityDefaultLow
                     forOrientation:NSLayoutConstraintOrientationHorizontal];
    [body setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                   forOrientation:
                                       NSLayoutConstraintOrientationHorizontal];
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
    desc.textColor = [NSColor inspectorLabel];
    [desc setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                   forOrientation:
                                       NSLayoutConstraintOrientationHorizontal];
    [desc setContentHuggingPriority:NSLayoutPriorityDefaultLow
                     forOrientation:NSLayoutConstraintOrientationHorizontal];
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
