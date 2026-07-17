/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "ShaderBadgeView.h"

#import <KeyframelessKit/KeyframelessKit.h>
#import <QuartzCore/QuartzCore.h> // kCAMediaTimingFunctionEaseOut

// InfoBadge's geometry, by eye (see the header).
static const CGFloat kBadgeHPad = KKPaddingSM + 1.0;
static const CGFloat kBadgeVPad = KKSpacingXS;
static const CGFloat kBadgeGap = 3.0;
static const CGFloat kBadgeSymbolPt = 8.0;
static const CGFloat kBadgeFontPt = 9.0;
// Long enough to read as a reveal rather than a snap, short enough not to make
// a pointer sweeping the grid feel syrupy.
static const NSTimeInterval kBadgeExpandDuration = 0.14;

@implementation _ShaderBadge {
  NSImageView *_icon;
  NSTextField *_label;
  CGFloat _fullWidth;    // what it wants with the label untruncated
  CGFloat _compactWidth; // what it settles for
  BOOL _expanded;
}

- (instancetype)initWithSymbol:(NSString *)symbol
                          text:(NSString *)text
                         color:(NSColor *)color
                          fill:(NSColor *)fill
                      maxWidth:(CGFloat)maxWidth {
  self = [super initWithFrame:NSZeroRect];
  if (!self)
    return nil;

  CGFloat iconW = 0.0, iconH = 0.0;
  if (symbol.length) {
    NSImage *img = [NSImage imageWithSystemSymbolName:symbol
                             accessibilityDescription:text];
    img = [img imageWithSymbolConfiguration:
                   [NSImageSymbolConfiguration
                       configurationWithPointSize:kBadgeSymbolPt
                                           weight:NSFontWeightMedium]];
    if (img) {
      _icon = [NSImageView imageViewWithImage:img];
      _icon.contentTintColor = color;
      iconW = NSWidth(_icon.frame);
      iconH = NSHeight(_icon.frame);
      [self addSubview:_icon];
    }
  }

  CGFloat labelW = 0.0, labelH = 0.0;
  if (text.length) {
    _label = [NSTextField labelWithString:text];
    _label.font = [NSFont systemFontOfSize:kBadgeFontPt
                                    weight:NSFontWeightMedium];
    _label.textColor = color;
    // The field truncates to whatever width we give it - which is the whole
    // point: clamping the CAPSULE alone just clipped the text mid-glyph against
    // the rounded mask, with no ellipsis to say it had been cut.
    _label.lineBreakMode = NSLineBreakByTruncatingTail;
    _label.cell.truncatesLastVisibleLine = YES;
    [_label sizeToFit];
    labelW = NSWidth(_label.frame);
    labelH = NSHeight(_label.frame);
    [self addSubview:_label];
  }

  CGFloat gap = (_icon && _label) ? kBadgeGap : 0.0;
  CGFloat chromeW = kBadgeHPad * 2.0 + iconW + gap;
  CGFloat h = round(MAX(iconH, labelH) + kBadgeVPad * 2.0);
  _fullWidth = round(chromeW + labelW);
  _compactWidth =
      maxWidth > 0.0 ? MIN(_fullWidth, round(maxWidth)) : _fullWidth;
  _truncated = _compactWidth < _fullWidth;

  self.frame = NSMakeRect(0, 0, _compactWidth, h);
  // Frames are set explicitly here and again on every expand, so autoresizing
  // would only fight them.
  self.autoresizesSubviews = NO;

  // Vertically centred rather than baseline-aligned: the glyph and the label
  // have unrelated metrics, and a badge this small reads as lopsided the moment
  // they disagree.
  CGFloat x = kBadgeHPad;
  if (_icon) {
    _icon.frame = NSMakeRect(x, round((h - iconH) / 2.0), iconW, iconH);
    x += iconW + gap;
  }
  if (_label)
    _label.frame = NSMakeRect(x, round((h - labelH) / 2.0),
                              _compactWidth - x - kBadgeHPad, labelH);

  self.wantsLayer = YES;
  self.layer.backgroundColor = fill.CGColor;
  self.layer.cornerRadius = h / 2.0;
  self.layer.masksToBounds = YES;
  return self;
}

- (void)setExpanded:(BOOL)expanded animated:(BOOL)animated {
  if (!_truncated || expanded == _expanded)
    return;
  _expanded = expanded;
  CGFloat targetW = expanded ? _fullWidth : _compactWidth;
  // Right edge pinned: this badge lives at the right end of the name row, so it
  // has room to the LEFT (over the shader's name) and none to the right.
  CGFloat rightX = NSMaxX(self.frame);
  NSRect target = self.frame;
  target.size.width = targetW;
  target.origin.x = rightX - targetW;

  NSRect labelTarget = _label.frame;
  labelTarget.size.width = targetW - NSMinX(_label.frame) - kBadgeHPad;

  if (!animated) {
    self.frame = target;
    _label.frame = labelTarget;
    return;
  }
  [NSAnimationContext runAnimationGroup:^(NSAnimationContext *ctx) {
    ctx.duration = kBadgeExpandDuration;
    ctx.timingFunction =
        [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseOut];
    // Both explicitly: `autoresizesSubviews` is off, and an animator-driven
    // frame change wouldn't lay the label out per step anyway.
    self.animator.frame = target;
    self->_label.animator.frame = labelTarget;
  }];
}

- (NSView *)hitTest:(NSPoint)point {
  return nil; // decoration: never intercept the card's click
}

@end
