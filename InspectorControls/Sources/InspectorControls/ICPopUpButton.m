/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */
#import "ICPopUpButton.h"
#import "InspectorTokens.h"

// Adapted from legacy KKPopupSelectView: retain native menu behavior, replace
// the bezel/arrow presentation. Direct drawing keeps decorations out of hit testing.
@interface ICPopUpButtonCell : NSPopUpButtonCell
@end
@implementation ICPopUpButtonCell
- (void)drawWithFrame:(NSRect)frame inView:(NSView *)view {
  NSColor *textColor=self.enabled ? ICInspectorTokens.valueColor : ICInspectorTokens.disabledTextColor;
  NSColor *decorationColor=self.enabled ? ICInspectorTokens.decorationColor : ICInspectorTokens.disabledTextColor;
  NSMutableParagraphStyle *paragraph=[NSMutableParagraphStyle new];
  paragraph.alignment=NSTextAlignmentRight;
  paragraph.lineBreakMode=NSLineBreakByTruncatingTail;
  // Keep the compact inspector readout independent of native menu typography.
  NSDictionary *attributes=@{NSFontAttributeName:[NSFont systemFontOfSize:11],
      NSForegroundColorAttributeName:textColor, NSParagraphStyleAttributeName:paragraph};
  CGFloat height=[@"Ag" sizeWithAttributes:attributes].height;
  NSRect title=NSMakeRect(NSMinX(frame)+2,NSMidY(frame)-height/2,
      MAX(0,NSWidth(frame)-22),height);
  [self.title drawInRect:title withAttributes:attributes];
  static NSArray<NSImage *> *chevrons;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSImageSymbolConfiguration *configuration=[NSImageSymbolConfiguration
        configurationWithPointSize:11 weight:NSFontWeightSemibold];
    chevrons=@[
      [[NSImage imageWithSystemSymbolName:@"chevron.up" accessibilityDescription:nil]
          imageWithSymbolConfiguration:configuration],
      [[NSImage imageWithSystemSymbolName:@"chevron.down" accessibilityDescription:nil]
          imageWithSymbolConfiguration:configuration]];
  });
  CGFloat x=NSMaxX(frame)-14, y=NSMidY(frame);
  for (NSUInteger i=0;i<chevrons.count;i++) {
    NSImage *symbol=chevrons[i];
    NSImage *tinted=[NSImage imageWithSize:symbol.size flipped:NO drawingHandler:^BOOL(NSRect rect) {
      [symbol drawInRect:rect];
      [decorationColor setFill];
      NSRectFillUsingOperation(rect,NSCompositingOperationSourceIn);
      return YES;
    }];
    // Match the legacy 8 x 6 pt stacked symbol canvases in either coordinate system.
    BOOL top=i==0;
    CGFloat originY=(top==view.isFlipped) ? y-6 : y;
    [tinted drawInRect:NSMakeRect(x,originY,8,6) fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
  }
}
@end

@implementation ICPopUpButton
+ (Class)cellClass { return ICPopUpButtonCell.class; }
- (instancetype)initWithFrame:(NSRect)frame pullsDown:(BOOL)pullsDown {
  if ((self=[super initWithFrame:frame pullsDown:pullsDown])) {
    self.bordered=NO;
    self.alignment=NSTextAlignmentRight;
    self.controlSize=NSControlSizeRegular;
    self.font=[NSFont menuFontOfSize:0];
    self.menu.font=[NSFont menuFontOfSize:0];
    ((NSPopUpButtonCell *)self.cell).arrowPosition=NSPopUpNoArrow;
  }
  return self;
}
@end
