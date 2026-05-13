/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "RoundedInspectorView.h"
#import <KeyframelessKit/KKPillToggleRowView.h>
#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>

static const CGFloat kInspectorHeight = 200.0;
static const CGFloat kLoopIconSize = 11.0;

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

@implementation RoundedInspectorView {
  id<PROAPIAccessing> _apiManager;
  RoundedTab _selectedTab;
  KKPillToggleRowView *_tabBar;
  _RoundedLoopButton *_loopButton;
  NSView *_contentView;
}

- (instancetype)initWithAPIManager:(id<PROAPIAccessing>)apiManager
                       loopEnabled:(BOOL)loopEnabled
                         activeTab:(NSInteger)activeTab {
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

    __weak typeof(self) weak = self;
    _tabBar.onToggled = ^(NSInteger index, BOOL isOn) {
      if (!isOn)
        return;
      __strong typeof(weak) strong = weak;
      if (!strong)
        return;
      [strong _selectTab:(RoundedTab)index];
    };

    _loopButton = [[_RoundedLoopButton alloc] init];
    _loopButton.translatesAutoresizingMaskIntoConstraints = NO;
    _loopButton.on = loopEnabled;
    [box addSubview:_loopButton];

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

    CGFloat h = KKInspectorHorizontalInset;
    [NSLayoutConstraint activateConstraints:@[
      [_tabBar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                            constant:h],
      [_tabBar.topAnchor constraintEqualToAnchor:self.topAnchor
                                        constant:KKPaddingMD],

      [box.leadingAnchor constraintEqualToAnchor:self.leadingAnchor constant:h],
      [box.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                         constant:-h],
      [box.topAnchor constraintEqualToAnchor:_tabBar.bottomAnchor
                                    constant:KKPaddingMD],
      [box.bottomAnchor constraintEqualToAnchor:self.bottomAnchor
                                       constant:-KKPaddingLG],

      [_loopButton.leadingAnchor constraintEqualToAnchor:box.leadingAnchor
                                                constant:KKPaddingMD],
      [_loopButton.topAnchor constraintEqualToAnchor:box.topAnchor
                                            constant:KKPaddingMD],

      [_contentView.leadingAnchor constraintEqualToAnchor:box.leadingAnchor],
      [_contentView.trailingAnchor constraintEqualToAnchor:box.trailingAnchor],
      [_contentView.topAnchor constraintEqualToAnchor:box.topAnchor],
      [_contentView.bottomAnchor constraintEqualToAnchor:box.bottomAnchor],
    ]];
  }
  return self;
}

- (void)setLoopEnabled:(BOOL)enabled {
  _loopButton.on = enabled;
  [_loopButton setNeedsDisplay:YES];
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
