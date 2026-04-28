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

/// Borderless link button used in the help-page table of contents.
/// Holds weak refs to its target section view and the scroll view, so a
/// click can scroll that section's title to the top of the visible
/// area. Confluence-style "On this page" jumplist.
@interface KKHelpTOCLink : NSButton
@property(weak) NSView *anchorView;
/// Document view of the surrounding scroll view (the page stack). Used
/// as the coordinate space for the scroll target and as the receiver of
/// `scrollPoint:`, which walks up to the nearest clip view automatically.
@property(weak) NSView *documentHost;
@end

@implementation KKHelpTOCLink
- (void)mouseDown:(NSEvent *)event {
  NSView *doc = self.documentHost;
  NSView *anchor = self.anchorView;
  NSScrollView *sv = doc.enclosingScrollView;
  NSClipView *clip = sv.contentView;
  if (!doc || !anchor || !sv || !clip)
    return;
  // Compute the anchor's top edge in clip-view coordinates (the clip is
  // flipped, so smaller y = visually higher), then translate to a new
  // bounds origin. Doing it via the clip rather than `scrollPoint:`
  // sidesteps the doc-flipped vs. clip-flipped mismatch (page stack is
  // non-flipped, so NSMinY of a section frame in doc coords is the
  // section's *bottom*, which is why scrollPoint was landing wrong).
  NSRect inClip = [clip convertRect:anchor.bounds fromView:anchor];
  CGFloat newY =
      clip.bounds.origin.y + NSMinY(inClip) - KKHelpPagePadding * 0.5;
  if (newY < 0)
    newY = 0;
  [clip setBoundsOrigin:NSMakePoint(clip.bounds.origin.x, newY)];
  [sv reflectScrolledClipView:clip];
}
- (void)resetCursorRects {
  [self addCursorRect:self.bounds cursor:[NSCursor pointingHandCursor]];
}
@end

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

  KKPaddedScrollView *scroll =
      [[KKPaddedScrollView alloc] initWithDocumentView:page
                                               padding:KKHelpPagePadding];

  // Two-pass build: first materialise each section view (so we have a
  // stable anchor to scroll to), then build the TOC linking to those
  // anchors. TOC sits at the top of the page, separated from the first
  // section by the same divider style used between sections.
  NSMutableArray<NSView *> *sectionViews =
      [NSMutableArray arrayWithCapacity:sections.count];
  for (KKHelpSection *section in sections) {
    [sectionViews addObject:[self _viewForSection:section]];
  }

  if (sections.count > 1) {
    NSView *toc = [self _tocViewForSections:sections
                                    anchors:sectionViews
                               documentHost:page];
    [page addArrangedSubview:toc];
    [toc.widthAnchor constraintEqualToAnchor:page.widthAnchor].active = YES;
  }

  for (NSUInteger i = 0; i < sectionViews.count; i++) {
    if (page.arrangedSubviews.count > 0) {
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
    NSView *sv = sectionViews[i];
    [page addArrangedSubview:sv];
    [sv.widthAnchor constraintEqualToAnchor:page.widthAnchor].active = YES;
  }

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

- (NSView *)_tocViewForSections:(NSArray<KKHelpSection *> *)sections
                        anchors:(NSArray<NSView *> *)anchors
                   documentHost:(NSView *)documentHost {
  NSStackView *toc = [[NSStackView alloc] initWithFrame:NSZeroRect];
  toc.orientation = NSUserInterfaceLayoutOrientationVertical;
  toc.alignment = NSLayoutAttributeLeading;
  toc.spacing = KKHelpAfterTitleGap;

  [toc addArrangedSubview:[self _subheading:@"On this page"]];

  NSStackView *links = [[NSStackView alloc] initWithFrame:NSZeroRect];
  links.orientation = NSUserInterfaceLayoutOrientationVertical;
  links.alignment = NSLayoutAttributeLeading;
  links.spacing = 6.0;
  // Indent the link block from the left edge so the TOC reads as a
  // sub-list under "On this page", not a sibling header.
  links.edgeInsets = NSEdgeInsetsMake(0, 12.0, 0, 0);

  NSColor *linkColor = [NSColor accentMatchingHost];
  NSFont *linkFont = [NSFont systemFontOfSize:13.0 weight:NSFontWeightSemibold];
  for (NSUInteger i = 0; i < sections.count; i++) {
    NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeCenterY;
    row.spacing = 8.0;

    // Always reserve a fixed-width slot so titles line up vertically
    // even when a section happens to lack an icon. 18pt matches the
    // section-header icon size used in `_viewForSection:`.
    NSImageView *iconView =
        sections[i].icon ? [NSImageView imageViewWithImage:sections[i].icon]
                         : [[NSImageView alloc] init];
    iconView.symbolConfiguration = [NSImageSymbolConfiguration
        configurationWithPointSize:13.0
                            weight:NSFontWeightSemibold];
    iconView.contentTintColor = linkColor;
    iconView.imageScaling = NSImageScaleProportionallyDown;
    iconView.translatesAutoresizingMaskIntoConstraints = NO;
    [iconView.widthAnchor constraintEqualToConstant:18.0].active = YES;
    [iconView.heightAnchor constraintEqualToConstant:18.0].active = YES;
    [row addArrangedSubview:iconView];

    NSAttributedString *title = [[NSAttributedString alloc]
        initWithString:sections[i].title
            attributes:@{
              NSFontAttributeName : linkFont,
              NSForegroundColorAttributeName : linkColor,
            }];

    KKHelpTOCLink *link = [[KKHelpTOCLink alloc] init];
    link.bordered = NO;
    link.bezelStyle = NSBezelStyleInline;
    [link setButtonType:NSButtonTypeMomentaryChange];
    link.attributedTitle = title;
    link.contentTintColor = linkColor;
    link.alignment = NSTextAlignmentLeft;
    link.anchorView = anchors[i];
    link.documentHost = documentHost;
    [row addArrangedSubview:link];

    [links addArrangedSubview:row];
  }

  [toc addArrangedSubview:links];
  [links.widthAnchor constraintEqualToAnchor:toc.widthAnchor].active = YES;
  return toc;
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
