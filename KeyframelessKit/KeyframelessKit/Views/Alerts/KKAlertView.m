/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKAlertView.h"
#import "KKFonts.h"
#import "KKHostInfo.h"
#import "KKTokens.h"
#import "KKViewHelpers.h" // KKTrackingAreaMatches
#import "NSColor+KKColors.h"
#import <AppKit/AppKit.h>
#import <AppKit/NSView.h>
#import <CoreFoundation/CFCGTypes.h>
#import <Foundation/Foundation.h>
#import <KeyframelessKit/KKLog.h>
#import <QuartzCore/CAMediaTimingFunction.h>
#import <objc/objc.h>

static const CGFloat KKAlertViewHeight = KKInspectorRowHeight * 2;

@implementation KKAlertView {
  NSTextField *_label;
  NSImageView *_iconView;
  NSView *_contentView;
  NSLayoutConstraint *_labelTrailing;
  NSUInteger _currentPage;
  NSTextField *_pageLabel;
  NSImageView *_renderedLabel;
  NSImageView *_renderedPageLabel;
  NSArray<NSImage *> *_renderedPageImages;
  NSView *_renderedClipView;
  NSLayoutConstraint *_renderedLabelLeading;
  NSTrackingArea *_trackingArea;
  BOOL _isScrolling;
}

- (instancetype)initWithText:(NSString *)text {
  return [self initWithText:text color:[NSColor accent]];
}

- (instancetype)initWithAttributedText:(NSAttributedString *)text {
  return [self initWithAttributedText:text color:[NSColor accent]];
}

- (instancetype)initWithAttributedText:(NSAttributedString *)text
                                 color:(NSColor *)color {
  self = [self initWithText:@"" color:color];
  if (self) {
    _label.attributedStringValue = text;
  }
  return self;
}

- (instancetype)initWithText:(NSString *)text color:(NSColor *)color {
  self = [super initWithFrame:NSMakeRect(0, 0, 0.0, KKAlertViewHeight)];

  if (self) {
    _text = [text copy];
    _color = color;

    // Container to enforce padding - needed to prevent hiding of the chevron
    // for publishing parameters
    self.autoresizingMask =
        NSViewWidthSizable | NSViewHeightSizable | NSViewMinYMargin;

    _contentView = [[NSView alloc] init];
    _contentView.translatesAutoresizingMaskIntoConstraints = NO;
    _contentView.wantsLayer = YES;
    _contentView.layer.backgroundColor =
        [[_color colorWithAlphaComponent:0.1] CGColor];
    _contentView.layer.cornerRadius = KKRadiusMD;
    _contentView.layer.masksToBounds = YES;
    [self addSubview:_contentView];

    _iconView = [[NSImageView alloc] init];
    _iconView.hidden = YES;
    _iconView.translatesAutoresizingMaskIntoConstraints = NO;
    _iconView.imageScaling = NSImageScaleProportionallyUpOrDown;
    _iconView.contentTintColor = _color;
    [_contentView addSubview:_iconView];

    _label = [NSTextField wrappingLabelWithString:_text];
    _label.translatesAutoresizingMaskIntoConstraints = NO;
    _label.selectable = NO;
    _label.textColor = _color;
    _label.backgroundColor = [NSColor clearColor];
    _label.font = [KKFonts inspectorLabelFont];
    _label.lineBreakMode = NSLineBreakByWordWrapping;
    _label.maximumNumberOfLines = 2;
    [_contentView addSubview:_label];

    _labelTrailing = [_label.trailingAnchor
        constraintEqualToAnchor:_contentView.trailingAnchor
                       constant:-KKSpacingMD];

    [NSLayoutConstraint activateConstraints:@[
      [_contentView.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [_contentView.leadingAnchor
          constraintEqualToAnchor:self.leadingAnchor
                         constant:KKInspectorHorizontalInset],
      [_contentView.trailingAnchor
          constraintEqualToAnchor:self.trailingAnchor
                         constant:-KKInspectorHorizontalInset],

      [_iconView.widthAnchor
          constraintEqualToConstant:[KKFonts inspectorIconSize]],
      [_iconView.heightAnchor
          constraintEqualToConstant:[KKFonts inspectorIconSize]],
      [_iconView.leadingAnchor
          constraintEqualToAnchor:_contentView.leadingAnchor
                         constant:KKSpacingMD * 1.5],
      [_iconView.topAnchor constraintEqualToAnchor:_contentView.topAnchor
                                          constant:KKSpacingMD + 1.0],

      [_label.topAnchor constraintEqualToAnchor:_contentView.topAnchor
                                       constant:KKSpacingMD],
      [_label.leadingAnchor constraintEqualToAnchor:_iconView.trailingAnchor
                                           constant:KKSpacingMD],
      [_label.bottomAnchor constraintEqualToAnchor:_contentView.bottomAnchor
                                          constant:-KKSpacingMD],
      _labelTrailing,
    ]];
  }

  return self;
}

- (void)setText:(NSString *)text {
  _text = [text copy];
  _label.stringValue = text;
  [self setFrameSize:NSMakeSize(self.frame.size.width, 0)];
}

- (void)setIcon:(NSImage *)icon {
  _icon = icon;
  _iconView.image = icon;
  _iconView.hidden = (icon == nil);
}

- (void)setAccessoryView:(NSView *)accessoryView {
  [_accessoryView removeFromSuperview];
  _accessoryView = accessoryView;
  if (!accessoryView) {
    _labelTrailing.active = NO;
    _labelTrailing = [_label.trailingAnchor
        constraintEqualToAnchor:_contentView.trailingAnchor
                       constant:-KKSpacingMD];
    _labelTrailing.active = YES;
    return;
  }
  accessoryView.translatesAutoresizingMaskIntoConstraints = NO;
  [_contentView addSubview:accessoryView];
  _labelTrailing.active = NO;
  _labelTrailing = [_label.trailingAnchor
      constraintLessThanOrEqualToAnchor:accessoryView.leadingAnchor
                               constant:-KKSpacingMD];
  _labelTrailing.active = YES;
  [NSLayoutConstraint activateConstraints:@[
    [accessoryView.trailingAnchor
        constraintEqualToAnchor:_contentView.trailingAnchor
                       constant:-KKSpacingSM],
    [accessoryView.centerYAnchor
        constraintEqualToAnchor:_contentView.centerYAnchor],
  ]];
}

- (void)setColor:(NSColor *)color {
  _color = color;
  _label.textColor = color;
  _iconView.contentTintColor = color;
}

- (void)setAttributedPages:(NSArray<NSAttributedString *> *)attributedPages {
  _attributedPages = [attributedPages copy];
  _currentPage = 0;

  NSMutableArray<NSImage *> *images = [NSMutableArray array];
  for (NSAttributedString *page in _attributedPages) {
    NSMutableAttributedString *colored = [page mutableCopy];
    NSFont *defaultFont = [KKFonts inspectorLabelFont];
    [colored enumerateAttributesInRange:NSMakeRange(0, colored.length)
                                options:0
                             usingBlock:^(NSDictionary *attrs, NSRange range,
                                          BOOL *stop) {
                               if (!attrs[NSForegroundColorAttributeName])
                                 [colored
                                     addAttribute:NSForegroundColorAttributeName
                                            value:_color
                                            range:range];
                               if (!attrs[NSFontAttributeName])
                                 [colored addAttribute:NSFontAttributeName
                                                 value:defaultFont
                                                 range:range];
                             }];
    NSSize size = [colored size];
    NSImage *img = [[NSImage alloc]
        initWithSize:NSMakeSize(ceil(size.width), ceil(size.height))];
    [img lockFocus];
    [colored drawAtPoint:NSZeroPoint];
    [img unlockFocus];
    [images addObject:img];
  }
  _renderedPageImages = images;

  if (!_renderedLabel) {
    _renderedClipView = [[NSView alloc] init];
    _renderedClipView.translatesAutoresizingMaskIntoConstraints = NO;
    _renderedClipView.wantsLayer = YES;
    _renderedClipView.layer.masksToBounds = YES;
    [_contentView addSubview:_renderedClipView];
    [NSLayoutConstraint activateConstraints:@[
      [_renderedClipView.leadingAnchor
          constraintEqualToAnchor:_label.leadingAnchor],
      [_renderedClipView.trailingAnchor
          constraintEqualToAnchor:_label.trailingAnchor],
      [_renderedClipView.topAnchor constraintEqualToAnchor:_label.topAnchor],
      [_renderedClipView.bottomAnchor
          constraintEqualToAnchor:_label.bottomAnchor],
    ]];

    _renderedLabel = [[NSImageView alloc] init];
    _renderedLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _renderedLabel.imageScaling = NSImageScaleNone;
    _renderedLabel.imageAlignment = NSImageAlignLeft;
    [_renderedClipView addSubview:_renderedLabel];
    _renderedLabelLeading = [_renderedLabel.leadingAnchor
        constraintEqualToAnchor:_renderedClipView.leadingAnchor];
    [NSLayoutConstraint activateConstraints:@[
      _renderedLabelLeading,
      [_renderedLabel.centerYAnchor
          constraintEqualToAnchor:_renderedClipView.centerYAnchor],
    ]];
    _label.alphaValue = 0;
    _label.maximumNumberOfLines = 1;
    [_label setContentHuggingPriority:1
                       forOrientation:NSLayoutConstraintOrientationHorizontal];
  }

  if (_attributedPages.count > 1) {
    [self _setupPageNavigation];
  }
  [self _showCurrentPage];
}

- (void)_setupPageNavigation {
  NSView *navView = [[NSView alloc] init];
  navView.translatesAutoresizingMaskIntoConstraints = NO;

  NSImageSymbolConfiguration *chevronCfg = [NSImageSymbolConfiguration
      configurationWithPointSize:8.0
                          weight:NSFontWeightMedium];
  NSImage *upChevron = [[NSImage imageWithSystemSymbolName:@"chevron.up"
                                  accessibilityDescription:@"Previous"]
      imageWithSymbolConfiguration:chevronCfg];
  NSImage *downChevron = [[NSImage imageWithSystemSymbolName:@"chevron.down"
                                    accessibilityDescription:@"Next"]
      imageWithSymbolConfiguration:chevronCfg];

  // Borderless hit-area buttons, each taking half the column height.
  NSButton *prevBtn = [NSButton buttonWithTitle:@""
                                         target:self
                                         action:@selector(_prevPage:)];
  prevBtn.bordered = NO;
  prevBtn.translatesAutoresizingMaskIntoConstraints = NO;

  NSButton *nextBtn = [NSButton buttonWithTitle:@""
                                         target:self
                                         action:@selector(_nextPage:)];
  nextBtn.bordered = NO;
  nextBtn.translatesAutoresizingMaskIntoConstraints = NO;

  // Chevron views as subviews of their buttons so clicks pass through.
  NSImageView *upView = [NSImageView imageViewWithImage:upChevron];
  upView.contentTintColor = _color;
  upView.translatesAutoresizingMaskIntoConstraints = NO;
  [prevBtn addSubview:upView];

  NSImageView *downView = [NSImageView imageViewWithImage:downChevron];
  downView.contentTintColor = _color;
  downView.translatesAutoresizingMaskIntoConstraints = NO;
  [nextBtn addSubview:downView];

  _pageLabel = [NSTextField labelWithString:@""];
  _pageLabel.font = [NSFont monospacedSystemFontOfSize:9.0
                                                weight:NSFontWeightRegular];
  _pageLabel.textColor = [NSColor clearColor];
  _pageLabel.alignment = NSTextAlignmentCenter;
  _pageLabel.translatesAutoresizingMaskIntoConstraints = NO;

  _renderedPageLabel = [[NSImageView alloc] init];
  _renderedPageLabel.translatesAutoresizingMaskIntoConstraints = NO;
  _renderedPageLabel.imageScaling = NSImageScaleNone;

  [navView addSubview:prevBtn];
  [navView addSubview:nextBtn];
  [navView addSubview:_pageLabel];
  [navView addSubview:_renderedPageLabel];

  // [1/2] [▲] - buttons fill top/bottom halves for hit area, chevron views
  //       [▼]   pinned to the inner edges so they sit close together.
  [NSLayoutConstraint activateConstraints:@[
    [navView.heightAnchor constraintEqualToConstant:KKInspectorRowHeight * 1.5],
    [_pageLabel.leadingAnchor constraintEqualToAnchor:navView.leadingAnchor],
    [_pageLabel.centerYAnchor constraintEqualToAnchor:navView.centerYAnchor],
    [prevBtn.leadingAnchor constraintEqualToAnchor:_pageLabel.trailingAnchor
                                          constant:KKSpacingSM],
    [prevBtn.topAnchor constraintEqualToAnchor:navView.topAnchor],
    [prevBtn.bottomAnchor constraintEqualToAnchor:navView.centerYAnchor],
    [prevBtn.widthAnchor constraintEqualToConstant:KKSpacingXL],
    [prevBtn.trailingAnchor constraintEqualToAnchor:navView.trailingAnchor],
    [nextBtn.leadingAnchor constraintEqualToAnchor:prevBtn.leadingAnchor],
    [nextBtn.topAnchor constraintEqualToAnchor:navView.centerYAnchor],
    [nextBtn.bottomAnchor constraintEqualToAnchor:navView.bottomAnchor],
    [nextBtn.trailingAnchor constraintEqualToAnchor:navView.trailingAnchor],
    [upView.centerXAnchor constraintEqualToAnchor:prevBtn.centerXAnchor],
    [upView.bottomAnchor constraintEqualToAnchor:prevBtn.bottomAnchor
                                        constant:-KKSpacingXS],
    [downView.centerXAnchor constraintEqualToAnchor:nextBtn.centerXAnchor],
    [downView.topAnchor constraintEqualToAnchor:nextBtn.topAnchor
                                       constant:KKSpacingXS],
    [_renderedPageLabel.leadingAnchor
        constraintEqualToAnchor:_pageLabel.leadingAnchor],
    [_renderedPageLabel.centerYAnchor
        constraintEqualToAnchor:_pageLabel.centerYAnchor],
  ]];

  self.accessoryView = navView;
}

- (void)_showCurrentPage {
  [self _stopScroll];
  if (_currentPage < _renderedPageImages.count) {
    _renderedLabel.image = _renderedPageImages[_currentPage];
  }
  if (_currentPage < _attributedPages.count) {
    _label.attributedStringValue = _attributedPages[_currentPage];
  }
  if (_pageLabel) {
    NSString *text = [NSString
        stringWithFormat:@"%lu/%lu", (unsigned long)(_currentPage + 1),
                         (unsigned long)_attributedPages.count];
    _pageLabel.stringValue = text;

    if (_renderedPageLabel) {
      NSFont *font = [NSFont monospacedSystemFontOfSize:9.0
                                                 weight:NSFontWeightRegular];
      NSDictionary *attrs = @{
        NSFontAttributeName : font,
        NSForegroundColorAttributeName : _color,
      };
      NSSize size = [text sizeWithAttributes:attrs];
      NSImage *img = [[NSImage alloc]
          initWithSize:NSMakeSize(ceil(size.width), ceil(size.height))];
      [img lockFocus];
      [text drawAtPoint:NSZeroPoint withAttributes:attrs];
      [img unlockFocus];
      _renderedPageLabel.image = img;
    }
  }
}

- (void)_prevPage:(id)sender {
  if (_attributedPages.count == 0)
    return;
  _currentPage =
      (_currentPage == 0) ? _attributedPages.count - 1 : _currentPage - 1;
  [self _showCurrentPage];
}

- (void)_nextPage:(id)sender {
  if (_attributedPages.count == 0)
    return;
  _currentPage = (_currentPage + 1) % _attributedPages.count;
  [self _showCurrentPage];
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_renderedLabel && KKTrackingAreaMatches(_trackingArea, self.bounds))
    return;
  if (_trackingArea)
    [self removeTrackingArea:_trackingArea];
  if (_renderedLabel) {
    _trackingArea =
        [[NSTrackingArea alloc] initWithRect:self.bounds
                                     options:NSTrackingMouseEnteredAndExited |
                                             NSTrackingActiveInActiveApp
                                       owner:self
                                    userInfo:nil];
    [self addTrackingArea:_trackingArea];
  }
}

- (void)mouseEntered:(NSEvent *)event {
  if (_isScrolling || !_renderedLabel.image)
    return;
  CGFloat overflow =
      _renderedLabel.image.size.width - _renderedClipView.frame.size.width;
  if (overflow <= 0)
    return;
  _isScrolling = YES;
  [self _scrollToEnd:overflow];
}

- (void)mouseExited:(NSEvent *)event {
  [self _stopScroll];
}

- (void)_scrollToEnd:(CGFloat)overflow {
  if (!self->_isScrolling)
    return;
  [NSAnimationContext
      runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = overflow / 30.0;
        ctx.timingFunction = [CAMediaTimingFunction
            functionWithName:kCAMediaTimingFunctionLinear];
        self->_renderedLabelLeading.animator.constant = -overflow;
      }
      completionHandler:^{
        if (!self->_isScrolling)
          return;
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
              if (!self->_isScrolling)
                return;
              [self _scrollToStart:overflow];
            });
      }];
}

- (void)_scrollToStart:(CGFloat)overflow {
  if (!self->_isScrolling)
    return;
  [NSAnimationContext
      runAnimationGroup:^(NSAnimationContext *ctx) {
        ctx.duration = overflow / 30.0;
        ctx.timingFunction = [CAMediaTimingFunction
            functionWithName:kCAMediaTimingFunctionLinear];
        self->_renderedLabelLeading.animator.constant = 0;
      }
      completionHandler:^{
        if (!self->_isScrolling)
          return;
        dispatch_after(
            dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.0 * NSEC_PER_SEC)),
            dispatch_get_main_queue(), ^{
              if (!self->_isScrolling)
                return;
              [self _scrollToEnd:overflow];
            });
      }];
}

- (void)_stopScroll {
  _isScrolling = NO;
  _renderedLabelLeading.constant = 0;
}

@end
