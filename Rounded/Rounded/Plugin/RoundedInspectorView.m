/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "RoundedInspectorView.h"
#import <KeyframelessKit/KKPillToggleRowView.h>
#import <KeyframelessKit/KKTimelineLanesView.h>
#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>

static const CGFloat kInspectorHeight = 200.0;
static const CGFloat kLoopIconSize = 11.0;
static const CGFloat kConstantsIconSize = 10.0;

typedef NS_ENUM(NSInteger, RoundedTab) {
  RoundedTabBasic = 0,
  RoundedTabAdvanced = 1,
};

@interface _RoundedLoopButton : NSView
@property(nonatomic) BOOL on;
@property(nonatomic, copy, nullable) void (^onToggled)(BOOL isOn);
@end

@implementation _RoundedLoopButton

- (BOOL)isFlipped {
  return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
  NSImage *img = [[NSImage imageWithSystemSymbolName:@"repeat"
                            accessibilityDescription:nil]
      imageWithSymbolConfiguration:
          [NSImageSymbolConfiguration
              configurationWithPointSize:kLoopIconSize
                                  weight:NSFontWeightMedium]];
  NSColor *tint = _on ? [NSColor accentMatchingHost]
                      : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
  NSImage *tinted = [img copy];
  [tinted lockFocus];
  [tint set];
  NSRectFillUsingOperation(
      NSMakeRect(0, 0, tinted.size.width, tinted.size.height),
      NSCompositingOperationSourceAtop);
  [tinted unlockFocus];
  CGFloat x = NSMidX(self.bounds) - tinted.size.width / 2.0;
  CGFloat y = NSMidY(self.bounds) - tinted.size.height / 2.0;
  [tinted drawAtPoint:NSMakePoint(x, y)
             fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver
             fraction:1.0];
}

- (void)mouseDown:(NSEvent *)event {
  _on = !_on;
  [self setNeedsDisplay:YES];
  if (_onToggled)
    _onToggled(_on);
}

- (NSSize)intrinsicContentSize {
  NSImage *img = [[NSImage imageWithSystemSymbolName:@"repeat"
                            accessibilityDescription:nil]
      imageWithSymbolConfiguration:
          [NSImageSymbolConfiguration
              configurationWithPointSize:kLoopIconSize
                                  weight:NSFontWeightMedium]];
  return NSMakeSize(ceil(img.size.width) + 2.5, 18.0);
}

@end

@interface _RoundedConstantsButton : NSView
@property(nonatomic, copy, nullable) void (^onTapped)(void);
@end

@implementation _RoundedConstantsButton

- (BOOL)isFlipped {
  return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}

- (void)drawRect:(NSRect)dirtyRect {
  NSImage *img = [[NSImage imageWithSystemSymbolName:@"slider.horizontal.3"
                            accessibilityDescription:nil]
      imageWithSymbolConfiguration:
          [NSImageSymbolConfiguration
              configurationWithPointSize:kConstantsIconSize
                                  weight:NSFontWeightMedium]];
  NSColor *tint = [[NSColor inspectorLabel] colorWithAlphaComponent:0.45];
  NSImage *tinted = [img copy];
  [tinted lockFocus];
  [tint set];
  NSRectFillUsingOperation(
      NSMakeRect(0, 0, tinted.size.width, tinted.size.height),
      NSCompositingOperationSourceAtop);
  [tinted unlockFocus];

  static const CGFloat kPadX = 5.0, kGap = 3.0;
  CGFloat iconY = NSMidY(self.bounds) - tinted.size.height / 2.0;
  [tinted drawAtPoint:NSMakePoint(kPadX, iconY)
             fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver
             fraction:1.0];

  NSFont *font = [NSFont systemFontOfSize:KKFontSizeSM
                                   weight:NSFontWeightMedium];
  NSDictionary *attrs =
      @{NSFontAttributeName : font, NSForegroundColorAttributeName : tint};
  NSSize textSz = [@"Constants" sizeWithAttributes:attrs];
  CGFloat textX = kPadX + tinted.size.width + kGap;
  CGFloat textY = NSMidY(self.bounds) - textSz.height / 2.0;
  [@"Constants" drawAtPoint:NSMakePoint(textX, textY) withAttributes:attrs];
}

- (void)mouseDown:(NSEvent *)event {
  if (_onTapped)
    _onTapped();
}

- (NSSize)intrinsicContentSize {
  NSImage *img = [[NSImage imageWithSystemSymbolName:@"slider.horizontal.3"
                            accessibilityDescription:nil]
      imageWithSymbolConfiguration:
          [NSImageSymbolConfiguration
              configurationWithPointSize:kConstantsIconSize
                                  weight:NSFontWeightMedium]];
  NSFont *font = [NSFont systemFontOfSize:KKFontSizeSM
                                   weight:NSFontWeightMedium];
  CGFloat textW = ceil(
      [@"Constants" sizeWithAttributes:@{NSFontAttributeName : font}].width);
  static const CGFloat kPadX = 5.0, kGap = 3.0;
  return NSMakeSize(kPadX + ceil(img.size.width) + kGap + textW + kPadX, 18.0);
}

@end

@implementation RoundedInspectorView {
  id<PROAPIAccessing> _apiManager;
  RoundedTab _selectedTab;
  KKPillToggleRowView *_tabBar;
  _RoundedLoopButton *_loopButton;
  _RoundedConstantsButton *_constantsButton;
  NSView *_contentView;
  KKTimelineLanesView *_basicView;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                       loopEnabled:(BOOL)loopEnabled
                         activeTab:(NSInteger)activeTab
                    availableLanes:(NSArray<KKLane *> *)availableLanes
                          timeline:(KKTimeline *)timeline {
  self = [super initWithFrame:NSMakeRect(0, 0, 0, kInspectorHeight)];
  if (self) {
    _apiManager = apiManager;
    _selectedTab = (RoundedTab)activeTab;
    self.autoresizingMask =
        NSViewWidthSizable | NSViewHeightSizable | NSViewMinYMargin;

    NSView *box = [[NSView alloc] init];
    box.translatesAutoresizingMaskIntoConstraints = NO;
    box.wantsLayer = YES;
    box.layer.backgroundColor = [NSColor colorWithWhite:0.0 alpha:0.08].CGColor;
    box.layer.borderColor = NSColor.separatorColor.CGColor;
    box.layer.borderWidth = 1.0;
    box.layer.cornerRadius = 8.0;
    [self addSubview:box];

    NSArray<NSImage *> *tabIcons = @[
      [NSImage imageWithSystemSymbolName:@"sparkles"
                accessibilityDescription:nil],
      [NSImage imageWithSystemSymbolName:@"timeline.selection"
                accessibilityDescription:nil],
    ];
    _tabBar =
        [[KKPillToggleRowView alloc] initWithLabels:@[ @"Basic", @"Advanced" ]
                                              icons:tabIcons];
    _tabBar.translatesAutoresizingMaskIntoConstraints = NO;
    _tabBar.radioMode = YES;
    _tabBar.grouped = YES;
    [_tabBar setState:(_selectedTab == RoundedTabBasic)
              atIndex:RoundedTabBasic];
    [_tabBar setState:(_selectedTab == RoundedTabAdvanced)
              atIndex:RoundedTabAdvanced];
    [self addSubview:_tabBar];

    _constantsButton = [[_RoundedConstantsButton alloc] init];
    _constantsButton.translatesAutoresizingMaskIntoConstraints = NO;
    _constantsButton.hidden = (timeline.lanes.count >= availableLanes.count);
    [self addSubview:_constantsButton];

    __weak typeof(self) weak = self;

    _tabBar.onToggled = ^(NSInteger index, BOOL isOn) {
      if (!isOn)
        return;
      __strong typeof(weak) strong = weak;
      if (!strong)
        return;
      [strong _selectTab:(RoundedTab)index];
    };

    NSView *headerRow = [[NSView alloc] init];
    headerRow.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:headerRow];

    _loopButton = [[_RoundedLoopButton alloc] init];
    _loopButton.translatesAutoresizingMaskIntoConstraints = NO;
    _loopButton.on = loopEnabled;
    [headerRow addSubview:_loopButton];

    _loopButton.onToggled = ^(BOOL isOn) {
      __strong typeof(weak) strong = weak;
      if (!strong)
        return;
      if (strong.onLoopToggled)
        strong.onLoopToggled(isOn);
    };

    _contentView = [[NSView alloc] init];
    _contentView.translatesAutoresizingMaskIntoConstraints = NO;
    [box addSubview:_contentView];

    _basicView =
        [[KKTimelineLanesView alloc] initWithAvailableLanes:availableLanes
                                                   timeline:timeline];
    _basicView.translatesAutoresizingMaskIntoConstraints = NO;
    [_contentView addSubview:_basicView];

    // Capture weakBasic and weakConstants AFTER _basicView is assigned.
    __weak _RoundedConstantsButton *weakConstants = _constantsButton;
    __weak KKTimelineLanesView *weakBasic = _basicView;

    _constantsButton.onTapped = ^{
      __strong KKTimelineLanesView *basic = weakBasic;
      __strong _RoundedConstantsButton *btn = weakConstants;
      if (basic && btn)
        [basic showStaticValuesPopoverFromView:btn];
    };

    _basicView.onTimelineMutated = ^(KKTimeline *updated) {
      __strong typeof(weak) strong = weak;
      __strong KKTimelineLanesView *basic = weakBasic;
      __strong _RoundedConstantsButton *btn = weakConstants;
      if (!strong)
        return;
      if (basic && btn)
        btn.hidden = !basic.hasUnoptedLanes;
      if (strong.onTimelineMutated)
        strong.onTimelineMutated(updated);
    };

    CGFloat h = KKInspectorHorizontalInset;
    [NSLayoutConstraint activateConstraints:@[
      [_tabBar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                            constant:h],
      [_tabBar.topAnchor constraintEqualToAnchor:self.topAnchor
                                        constant:KKPaddingMD],

      [_constantsButton.trailingAnchor
          constraintEqualToAnchor:self.trailingAnchor
                         constant:-h],
      [_constantsButton.centerYAnchor
          constraintEqualToAnchor:_tabBar.centerYAnchor],

      [box.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:h],
      [box.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                         constant:-h],
      [box.topAnchor constraintEqualToAnchor:_tabBar.bottomAnchor
                                    constant:KKPaddingMD],
      [box.bottomAnchor constraintEqualToAnchor:self.bottomAnchor
                                       constant:-KKPaddingLG],

      [headerRow.leadingAnchor constraintEqualToAnchor:box.leadingAnchor],
      [headerRow.trailingAnchor constraintEqualToAnchor:box.trailingAnchor],
      [headerRow.topAnchor constraintEqualToAnchor:box.topAnchor],
      [headerRow.heightAnchor constraintEqualToConstant:28.0],

      [_loopButton.leadingAnchor constraintEqualToAnchor:headerRow.leadingAnchor
                                                constant:KKPaddingMD],
      [_loopButton.centerYAnchor
          constraintEqualToAnchor:headerRow.centerYAnchor],

      [_contentView.leadingAnchor constraintEqualToAnchor:box.leadingAnchor],
      [_contentView.trailingAnchor constraintEqualToAnchor:box.trailingAnchor],
      [_contentView.topAnchor constraintEqualToAnchor:headerRow.bottomAnchor],
      [_contentView.bottomAnchor constraintEqualToAnchor:box.bottomAnchor],

      [_basicView.leadingAnchor
          constraintEqualToAnchor:_contentView.leadingAnchor],
      [_basicView.trailingAnchor
          constraintEqualToAnchor:_contentView.trailingAnchor],
      [_basicView.topAnchor constraintEqualToAnchor:_contentView.topAnchor],
      [_basicView.bottomAnchor
          constraintEqualToAnchor:_contentView.bottomAnchor],
    ]];
  }
  return self;
}

- (void)setLoopEnabled:(BOOL)enabled {
  _loopButton.on = enabled;
  [_loopButton setNeedsDisplay:YES];
}

- (void)applyTimeline:(KKTimeline *)timeline {
  [_basicView applyTimeline:timeline];
  _constantsButton.hidden = !_basicView.hasUnoptedLanes;
}

- (void)_selectTab:(RoundedTab)tab {
  _selectedTab = tab;
  [_tabBar setState:(tab == RoundedTabBasic) atIndex:RoundedTabBasic];
  [_tabBar setState:(tab == RoundedTabAdvanced) atIndex:RoundedTabAdvanced];
  if (_onTabChanged)
    _onTabChanged(tab);
}

- (void)setActiveTab:(NSInteger)tab {
  _selectedTab = (RoundedTab)tab;
  [_tabBar setState:(tab == RoundedTabBasic) atIndex:RoundedTabBasic];
  [_tabBar setState:(tab == RoundedTabAdvanced) atIndex:RoundedTabAdvanced];
}

- (CGSize)intrinsicContentSize {
  return NSMakeSize(NSViewNoIntrinsicMetric, kInspectorHeight);
}

@end
