/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKHelpView.h"
#import "KKFonts.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"
#import "KKHelpSection+Markdown.h"
#import "KKHelpSection.h"
#import "KKHelpView+Guides.h"
#import "KKHelpViewSubviews.h"
#import "KKHelpView_Private.h"
#import "KKLocalized.h"
#import "KKPaddedScrollView.h"

const CGFloat KKHelpPagePadding = 24.0;
const CGFloat KKHelpSectionGap = 24.0;
const CGFloat KKHelpAfterTitleGap = 10.0;
const CGFloat KKHelpKeyColumnMin = 170.0;

@implementation KKHelpView

- (instancetype)initWithSections:(NSArray<KKHelpSection *> *)sections {
  return [self initWithSections:sections guides:nil];
}

- (instancetype)initWithSections:(NSArray<KKHelpSection *> *)sections
                          guides:(nullable NSArray<KKHelpGuide *> *)guides {
  self = [super initWithFrame:NSMakeRect(0, 0, 480, 520)];
  if (!self)
    return nil;
  self.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
  _guides = [guides copy];

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

  if (guides.count > 0) {
    NSView *guidesBlock = [self _guidesBlockForGuides:guides];
    [page addArrangedSubview:guidesBlock];
    [guidesBlock.widthAnchor constraintEqualToAnchor:page.widthAnchor].active =
        YES;
  }

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
    [stack addArrangedSubview:
               [self _subheading:KKLoc(@"Shortcuts",
                                       @"Help: shortcuts section title.")]];
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

  [toc addArrangedSubview:
           [self _subheading:KKLoc(@"On this page",
                                   @"Help: table-of-contents heading.")]];

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
    // Leading indent markers encode nesting depth (a `  - ` sub-bullet in the
    // markdown). Strip them and indent the row by one step per level.
    NSUInteger depth = 0;
    while (depth < tip.length &&
           [tip.string characterAtIndex:depth] == 0x0002)
      depth++;
    NSAttributedString *bodyTip =
        depth > 0 ? [tip attributedSubstringFromRange:NSMakeRange(
                                                          depth,
                                                          tip.length - depth)]
                  : tip;

    NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeFirstBaseline;
    row.spacing = 8.0;
    row.edgeInsets = NSEdgeInsetsMake(0, depth * 18.0, 0, 0);

    NSTextField *bullet =
        [NSTextField labelWithString:(depth > 0 ? @"◦" : @"•")];
    bullet.font = [NSFont systemFontOfSize:13.0];
    bullet.textColor =
        depth > 0 ? [NSColor secondaryLabelColor] : [NSColor inspectorLabel];
    [row addArrangedSubview:bullet];

    NSTextField *body = [NSTextField labelWithAttributedString:bodyTip];
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

- (void)viewDidMoveToSuperview {
  [super viewDidMoveToSuperview];
  if (!self.superview)
    [self _teardownGuideRefresh];
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
