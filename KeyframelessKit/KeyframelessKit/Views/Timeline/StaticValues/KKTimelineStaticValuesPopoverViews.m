/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKLocalized.h"
#import "KKTimelineLanesView_Private.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"

@implementation _KKMiniViewerScrollView
- (NSResponder *)_recursiveResponderThatWantsForwardedScrollEventsForAxis:
                     (NSEventGestureAxis)axis
                                                         intendedForSwipe:
                                                             (BOOL)forSwipe {
  return nil;
}
@end

@implementation _KKExcludedRow
- (BOOL)isFlipped {
  return YES;
}
- (NSSize)intrinsicContentSize {
  return NSMakeSize(NSViewNoIntrinsicMetric, kFloatRowH);
}
- (instancetype)initWithLabel:(NSString *)label
                      message:(NSString *)message
                       gutter:(BOOL)gutter {
  self = [super initWithFrame:NSMakeRect(0, 0, kCanvasPopoverW, kFloatRowH)];
  if (!self)
    return nil;
  NSTextField *title = _KKMakeCaption(label);
  NSTextField *msg = _KKMakeCaption(message);
  msg.textColor = [[NSColor inspectorLabel] colorWithAlphaComponent:0.4];

  if (gutter) {
    // Advanced: a leading "+" in the same gutter as the editable row's "−", so
    // adding/removing a keypose swaps the glyph in place with no row jump. The
    // muted message hugs the trailing edge.
    NSButton *add = _KKGutterGlyphButton(@"plus", self, @selector(_tap:),
                                         [NSColor accentMatchingHost]);
    for (NSView *v in @[ add, title, msg ])
      [self addSubview:v];
    [NSLayoutConstraint activateConstraints:@[
      [add.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                        constant:KKPaddingMD],
      [add.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [add.widthAnchor constraintEqualToConstant:15.0],
      [add.heightAnchor constraintEqualToConstant:15.0],
      [title.leadingAnchor constraintEqualToAnchor:add.trailingAnchor
                                          constant:KKPaddingSM],
      [title.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [msg.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                         constant:-KKPaddingLG],
      [msg.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
      [msg.leadingAnchor
          constraintGreaterThanOrEqualToAnchor:title.trailingAnchor
                                      constant:KKPaddingSM],
    ]];
    return self;
  }

  NSButton *btn = [NSButton
      buttonWithTitle:KKLoc(@"Animate", @"Button: make property animatable.")
               target:self
               action:@selector(_tap:)];
  btn.bordered = NO;
  btn.bezelStyle = NSBezelStyleInline;
  btn.controlSize = NSControlSizeSmall;
  NSFont *btnFont = [NSFont systemFontOfSize:KKFontSizeSM
                                      weight:NSFontWeightMedium];
  btn.font = btnFont;
  btn.attributedTitle = [[NSAttributedString alloc]
      initWithString:KKLoc(@"Animate", @"Button: make property animatable.")
          attributes:@{
            NSForegroundColorAttributeName : [NSColor accentMatchingHost],
            NSFontAttributeName : btnFont
          }];
  btn.translatesAutoresizingMaskIntoConstraints = NO;
  for (NSView *v in @[ title, msg, btn ])
    [self addSubview:v];
  [NSLayoutConstraint activateConstraints:@[
    [title.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                        constant:KKPaddingLG],
    [title.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [btn.trailingAnchor constraintEqualToAnchor:self.trailingAnchor
                                       constant:-KKPaddingLG],
    [btn.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [msg.trailingAnchor constraintEqualToAnchor:btn.leadingAnchor
                                       constant:-KKPaddingMD],
    [msg.centerYAnchor constraintEqualToAnchor:self.centerYAnchor],
    [msg.leadingAnchor constraintGreaterThanOrEqualToAnchor:title.trailingAnchor
                                                   constant:KKPaddingSM],
  ]];
  return self;
}
- (void)_tap:(id)sender {
  if (_onAnimate)
    _onAnimate();
}
@end

@implementation _KKDropdownTrigger

- (BOOL)isFlipped {
  return YES;
}
- (BOOL)acceptsFirstMouse:(NSEvent *)e {
  return YES;
}

- (NSString *)_truncatedJoin:(NSArray<NSString *> *)items localize:(BOOL)loc {
  NSMutableString *s = [NSMutableString string];
  NSInteger shown = MIN((NSInteger)items.count, kMaxSummaryLabels);
  for (NSInteger i = 0; i < shown; i++) {
    if (i > 0)
      [s appendString:@", "];
    // Layer names (loc==NO) are user-typed and can be long, so clamp each to 15
    // chars; localized param labels stay as-is.
    [s appendString:loc ? KKLocalizedParamName(items[i])
                        : KKTruncatedLayerName(items[i])];
  }
  NSInteger overflow = (NSInteger)items.count - kMaxSummaryLabels;
  if (overflow > 0)
    [s appendFormat:@" +%ld", (long)overflow];
  return s;
}

- (NSString *)_summaryText {
  // Multi-owner (Canvas): list every animated layer's name with the same +N
  // truncation, e.g. "layer 1, layer 2 +1".
  if (_layerTitles.count)
    return [self _truncatedJoin:_layerTitles localize:NO];
  if (_selectedLabels.count == 0)
    return KKLoc(@"Add properties…", @"Button: add animatable properties.");
  return [self _truncatedJoin:_selectedLabels localize:YES];
}

- (void)drawRect:(NSRect)dirty {
  NSString *text = [self _summaryText];
  BOOL hasSelection = _selectedLabels.count > 0 || _layerTitles.count > 0;
  NSColor *textColor =
      hasSelection ? [NSColor inspectorLabel]
                   : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
  NSDictionary *attrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:KKFontSizeSM
                                            weight:NSFontWeightRegular],
    NSForegroundColorAttributeName : textColor,
  };

  NSImage *chevRaw = [[NSImage imageWithSystemSymbolName:@"chevron.down"
                                accessibilityDescription:nil]
      imageWithSymbolConfiguration:
          [NSImageSymbolConfiguration
              configurationWithPointSize:KKFontSizeSM - 2.0
                                  weight:NSFontWeightMedium]];
  NSImage *chev = [chevRaw copy];
  [chev lockFocus];
  [[[NSColor inspectorLabel] colorWithAlphaComponent:0.4] set];
  NSRectFillUsingOperation(NSMakeRect(0, 0, chev.size.width, chev.size.height),
                           NSCompositingOperationSourceAtop);
  [chev unlockFocus];
  CGFloat chevW = chev.size.width, chevH = chev.size.height;
  CGFloat chevX = NSMaxX(self.bounds) - chevW;
  CGFloat chevY = NSMidY(self.bounds) - chevH / 2.0;
  [chev drawInRect:NSMakeRect(chevX, chevY, chevW, chevH)
            fromRect:NSZeroRect
           operation:NSCompositingOperationSourceOver
            fraction:1.0
      respectFlipped:YES
               hints:nil];

  NSSize textSz = [text sizeWithAttributes:attrs];
  [text drawAtPoint:NSMakePoint(0, NSMidY(self.bounds) - textSz.height / 2.0)
      withAttributes:attrs];
}

- (void)mouseDown:(NSEvent *)e {
  if (_onTapped)
    _onTapped();
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize(NSViewNoIntrinsicMetric, NSViewNoIntrinsicMetric);
}

@end
