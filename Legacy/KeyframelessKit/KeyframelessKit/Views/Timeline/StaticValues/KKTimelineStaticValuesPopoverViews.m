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
                 displayLabel:(NSString *)displayLabel
                      message:(NSString *)message
                       gutter:(BOOL)gutter {
  self = [super initWithFrame:NSMakeRect(0, 0, kCanvasPopoverW, kFloatRowH)];
  if (!self)
    return nil;
  // Localize (also strips the `␟<layerID>` tag on multi-owner timelines) so the
  // excluded row reads "Scale", not "Scale␟<uuid>", like the editable rows. Use
  // the display label when the plugin gave the lane a separate one (e.g. a
  // shader uniform's "Center"), else fall back to the identity.
  NSTextField *title = _KKMakeCaption(
      KKLocalizedParamName(displayLabel.length ? displayLabel : label));
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
  // Host-supplied hierarchical summary (KKHierarchicalLaneSummary) or the "All"
  // sentinel - this is the modern path. drawRect clips it at the chevron.
  if (_summaryOverride.length)
    return _summaryOverride;
  if (_selectedLabels.count == 0 && _layerTitles.count == 0)
    return KKLoc(@"Add properties…", @"Button: add animatable properties.");
  // Fallback when no summary was supplied: the legacy truncated label list.
  if (_layerTitles.count)
    return [self _truncatedJoin:_layerTitles localize:NO];
  return [self _truncatedJoin:_selectedLabels localize:YES];
}

- (void)drawRect:(NSRect)dirty {
  NSString *text = [self _summaryText];
  BOOL hasSelection = _selectedLabels.count > 0 || _layerTitles.count > 0;
  NSColor *textColor =
      hasSelection ? [NSColor inspectorLabel]
                   : [[NSColor inspectorLabel] colorWithAlphaComponent:0.35];
  // Tail-truncate so a long hierarchical summary (Canvas: layer > group > … |
  // …) clips at the chevron instead of overflowing the field.
  NSMutableParagraphStyle *para = [[NSMutableParagraphStyle alloc] init];
  para.lineBreakMode = NSLineBreakByTruncatingTail;
  // Right-aligned still truncates its TAIL, so a long summary keeps its start
  // and loses its end either way - only the resting edge changes.
  para.alignment = _rightAligned ? NSTextAlignmentRight : NSTextAlignmentLeft;
  NSDictionary *attrs = @{
    NSFontAttributeName : [NSFont systemFontOfSize:KKFontSizeSM
                                            weight:NSFontWeightRegular],
    NSForegroundColorAttributeName : textColor,
    NSParagraphStyleAttributeName : para,
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
  CGFloat textW = MAX(0.0, chevX - 6.0); // stop short of the chevron
  [text drawInRect:NSMakeRect(0, NSMidY(self.bounds) - textSz.height / 2.0,
                              textW, textSz.height)
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
