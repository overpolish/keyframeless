/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKHelpView.h"
#import "KKFonts.h"
#import "KKHelpSection+Markdown.h"
#import "KKHelpSection.h"
#import "KKHelpView+Guides.h"
#import "KKHelpViewSubviews.h"
#import "KKHelpView_Private.h"
#import "KKLocalized.h"
#import "KKPaddedScrollView.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"

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
  return [self initWithSections:sections
                         guides:guides
                    headerTitle:nil
                     headerIcon:nil];
}

- (instancetype)initWithSections:(NSArray<KKHelpSection *> *)sections
                          guides:(nullable NSArray<KKHelpGuide *> *)guides
                     headerTitle:(nullable NSString *)headerTitle
                      headerIcon:(nullable NSImage *)headerIcon {
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

  // The plugin-name title bar sits at the very top, so it's clear which
  // plugin this help window belongs to. The matching section (if any) gives
  // up its inline heading - the title now lives here - and its body becomes
  // the intro block below.
  KKHelpSection *headerSection = nil;
  NSView *stickyHeader = nil;
  if (headerTitle.length > 0) {
    for (KKHelpSection *section in sections) {
      if ([section.title isEqualToString:headerTitle]) {
        headerSection = section;
        break;
      }
    }
    // Built here but pinned outside the scroll (below) so it stays put while
    // the content scrolls under it.
    stickyHeader = [self _headerBarWithTitle:headerTitle icon:headerIcon];
  }

  if (guides.count > 0) {
    NSView *guidesBlock = [self _guidesBlockForGuides:guides];
    [page addArrangedSubview:guidesBlock];
    [guidesBlock.widthAnchor constraintEqualToAnchor:page.widthAnchor].active =
        YES;
  }

  // The header section's body (its tips/shortcuts) becomes a titleless intro
  // block, above the table of contents.
  if (headerSection) {
    NSView *intro = [self _bodyViewForSection:headerSection];
    if (intro) {
      [page addArrangedSubview:intro];
      [intro.widthAnchor constraintEqualToAnchor:page.widthAnchor].active = YES;
    }
  }

  // Everything except the header section renders below, each with its own
  // heading and divider. No contents table: once the plugin's own overview is
  // hoisted into the header and intro, the remaining sections are the shared
  // timing/on-screen-control docs, and the window reads cleanly top to bottom.
  NSMutableArray<KKHelpSection *> *bodySections = [sections mutableCopy];
  if (headerSection)
    [bodySections removeObject:headerSection];

  for (KKHelpSection *section in bodySections) {
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
    NSView *sv = [self _viewForSection:section];
    [page addArrangedSubview:sv];
    [sv.widthAnchor constraintEqualToAnchor:page.widthAnchor].active = YES;
  }

  scroll.translatesAutoresizingMaskIntoConstraints = NO;
  [self addSubview:scroll];

  // The title bar stays pinned to the top of the view, in front of the scroll,
  // so it's always visible as the content scrolls under it. Its leading/
  // trailing match the scrolled content's inset (the scroll insets its content
  // by KKHelpPagePadding internally), and that same internal top padding gives
  // the gap down to the first row.
  NSLayoutYAxisAnchor *scrollTop = self.topAnchor;
  if (stickyHeader) {
    stickyHeader.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:stickyHeader];
    [NSLayoutConstraint activateConstraints:@[
      [stickyHeader.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                                 constant:KKHelpPagePadding],
      [stickyHeader.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                                  constant:-KKHelpPagePadding],
      [stickyHeader.topAnchor constraintEqualToAnchor:self.topAnchor
                                             constant:KKHelpPagePadding],
    ]];
    scrollTop = stickyHeader.bottomAnchor;
  }

  [NSLayoutConstraint activateConstraints:@[
    [scroll.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
    [scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
    [scroll.topAnchor constraintEqualToAnchor:scrollTop],
    [scroll.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
  ]];

  return self;
}

- (NSView *)_headerBarWithTitle:(NSString *)titleText
                           icon:(nullable NSImage *)icon {
  NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
  row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
  row.alignment = NSLayoutAttributeCenterY;
  row.spacing = 10.0;

  if (icon) {
    NSImageView *iconView = [NSImageView imageViewWithImage:icon];
    iconView.symbolConfiguration = [NSImageSymbolConfiguration
        configurationWithPointSize:24.0
                            weight:NSFontWeightBold];
    iconView.contentTintColor = [NSColor inspectorLabel];
    [row addArrangedSubview:iconView];
  }

  NSTextField *title = [NSTextField labelWithString:titleText];
  title.font = [NSFont systemFontOfSize:24.0 weight:NSFontWeightBold];
  title.textColor = [NSColor inspectorLabel];
  [row addArrangedSubview:title];

  return row;
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

  [self _appendBodyOfSection:section toStack:stack];
  return stack;
}

- (nullable NSView *)_bodyViewForSection:(KKHelpSection *)section {
  if (section.tips.count == 0 && section.shortcuts.count == 0)
    return nil;

  NSStackView *stack = [[NSStackView alloc] initWithFrame:NSZeroRect];
  stack.orientation = NSUserInterfaceLayoutOrientationVertical;
  stack.alignment = NSLayoutAttributeLeading;
  stack.spacing = KKHelpAfterTitleGap;

  [self _appendBodyOfSection:section toStack:stack];
  return stack;
}

- (void)_appendBodyOfSection:(KKHelpSection *)section
                     toStack:(NSStackView *)stack {
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
    while (depth < tip.length && [tip.string characterAtIndex:depth] == 0x0002)
      depth++;
    NSAttributedString *bodyTip =
        depth > 0
            ? [tip attributedSubstringFromRange:NSMakeRange(depth,
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
  // A vertical list of two-column rows rather than an NSGridView: the grid
  // never gave its wrapping cells a defined width, so multi-line rows kept
  // single-line height and bled across the separators. Here the key column is
  // a fixed width and the description fills the rest and wraps, so each row's
  // height tracks its tallest cell - the same pattern the bullet list uses.
  NSStackView *list = [[NSStackView alloc] initWithFrame:NSZeroRect];
  list.orientation = NSUserInterfaceLayoutOrientationVertical;
  list.alignment = NSLayoutAttributeLeading;
  list.spacing = 8.0;

  BOOL first = YES;
  for (KKHelpShortcut *sc in shortcuts) {
    if (!first) {
      NSView *divider = [[NSView alloc] init];
      divider.wantsLayer = YES;
      divider.layer.backgroundColor =
          [[[NSColor inspectorLabel] colorWithAlphaComponent:0.10] CGColor];
      divider.translatesAutoresizingMaskIntoConstraints = NO;
      [divider.heightAnchor constraintEqualToConstant:1.0].active = YES;
      [list addArrangedSubview:divider];
      [divider.widthAnchor constraintEqualToAnchor:list.widthAnchor].active =
          YES;
    }
    first = NO;

    NSStackView *row = [[NSStackView alloc] initWithFrame:NSZeroRect];
    row.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    row.alignment = NSLayoutAttributeFirstBaseline;
    row.spacing = 14.0;

    // Some chords are full phrases ("⌥ + click a Position handle") wider than
    // the fixed key column; wrap them within it (right-aligned) instead of
    // overflowing.
    NSTextField *keys = [NSTextField labelWithAttributedString:sc.keys];
    keys.alignment = NSTextAlignmentRight;
    keys.lineBreakMode = NSLineBreakByWordWrapping;
    keys.maximumNumberOfLines = 0;
    keys.translatesAutoresizingMaskIntoConstraints = NO;
    [keys.widthAnchor constraintEqualToConstant:KKHelpKeyColumnMin].active =
        YES;
    [row addArrangedSubview:keys];

    NSTextField *desc = [NSTextField labelWithAttributedString:sc.desc];
    desc.lineBreakMode = NSLineBreakByWordWrapping;
    desc.maximumNumberOfLines = 0;
    desc.textColor = [NSColor inspectorLabel];
    [desc setContentCompressionResistancePriority:NSLayoutPriorityDefaultLow
                                   forOrientation:
                                       NSLayoutConstraintOrientationHorizontal];
    [desc setContentHuggingPriority:NSLayoutPriorityDefaultLow
                     forOrientation:NSLayoutConstraintOrientationHorizontal];
    [row addArrangedSubview:desc];

    [list addArrangedSubview:row];
    [row.widthAnchor constraintEqualToAnchor:list.widthAnchor].active = YES;
  }
  return list;
}

@end
