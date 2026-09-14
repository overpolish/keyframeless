/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */
#import "ICPopUpButton.h"
#import "InspectorTokens.h"

// Drawing adapted from KKPopupSelectView. Decorations are drawn directly
// so they cannot intercept clicks on adjacent host controls.
@interface ICPopUpButtonCell : NSPopUpButtonCell
@end
@implementation ICPopUpButtonCell
- (void)synchronizeSelectionMarks {
  NSMenuItem *selected=self.selectedItem;
  for (NSMenuItem *item in self.menu.itemArray)
    item.state=item==selected ? NSControlStateValueOn : NSControlStateValueOff;
}
- (void)selectItem:(NSMenuItem *)item {
  [super selectItem:item];
  [self synchronizeSelectionMarks];
}
- (void)selectItemAtIndex:(NSInteger)index {
  [super selectItemAtIndex:index];
  [self synchronizeSelectionMarks];
}
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
  // The trigger ends at the suffix slot's trailing edge. Match the actual
  // text inset of the numeric cell rather than its outer field frame.
  CGFloat contentEnd=NSMaxX(frame)-ICInspectorSuffixWidth-ICInspectorValueSuffixGap-ICInspectorFieldTextInset;
  NSRect title=NSMakeRect(NSMinX(frame)+2,NSMidY(frame)-height/2,
      MAX(0,contentEnd-NSMinX(frame)-2),height);
  NSImage *selectedImage=self.selectedItem.image;
  if (selectedImage) {
    CGFloat imageWidth=MIN(28,MAX(0,NSWidth(title)-12));
    CGFloat textWidth=MIN([self.title sizeWithAttributes:attributes].width,MAX(0,NSWidth(title)-imageWidth-5));
    CGFloat imageX=NSMaxX(title)-textWidth-5-imageWidth;
    NSRect imageFrame=NSMakeRect(imageX,NSMidY(frame)-8,imageWidth,16);
    NSImage *displayImage=selectedImage;
    if (selectedImage.isTemplate) {
      displayImage=[NSImage imageWithSize:selectedImage.size flipped:NO drawingHandler:^BOOL(NSRect rect) {
        [selectedImage drawInRect:rect];
        [textColor setFill]; NSRectFillUsingOperation(rect,NSCompositingOperationSourceIn); return YES;
      }];
    }
    [displayImage drawInRect:imageFrame fromRect:NSZeroRect operation:NSCompositingOperationSourceOver
                   fraction:1 respectFlipped:YES hints:nil];
    title.origin.x=NSMaxX(title)-textWidth; title.size.width=textWidth;
  }
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
  CGFloat x=NSMaxX(frame)-ICInspectorSuffixWidth+ICInspectorFieldTextInset, y=NSMidY(frame);
  for (NSUInteger i=0;i<chevrons.count;i++) {
    NSImage *symbol=chevrons[i];
    NSImage *tinted=[NSImage imageWithSize:symbol.size flipped:NO drawingHandler:^BOOL(NSRect rect) {
      [symbol drawInRect:rect];
      [decorationColor setFill];
      NSRectFillUsingOperation(rect,NSCompositingOperationSourceIn);
      return YES;
    }];
    BOOL top=i==0;
    CGFloat originY=(top==view.isFlipped) ? y-6 : y;
    [tinted drawInRect:NSMakeRect(x,originY,8,6) fromRect:NSZeroRect
            operation:NSCompositingOperationSourceOver fraction:1 respectFlipped:YES hints:nil];
  }
}
@end

@interface ICPopUpButton ()
@property(nonatomic) NSUInteger interactionDepth;
@end
@implementation ICPopUpButton
- (NSMenu *)menuForEvent:(NSEvent *)event {
  BOOL context=event.type==NSEventTypeRightMouseDown ||
      (event.type==NSEventTypeLeftMouseDown && (event.modifierFlags & NSEventModifierFlagControl));
  if (context && self.contextMenuProvider) return self.contextMenuProvider();
  return [super menuForEvent:event];
}
- (BOOL)isInteracting { return self.interactionDepth>0; }
- (void)mouseDown:(NSEvent *)event {
  if ((event.modifierFlags & NSEventModifierFlagControl) && self.contextMenuProvider) {
    NSMenu *menu=self.contextMenuProvider();
    if (menu) [NSMenu popUpContextMenu:menu withEvent:event forView:self];
    return;
  }
  self.interactionDepth++;
  @try { [super mouseDown:event]; }
  @finally { self.interactionDepth--; }
}
- (void)performClick:(id)sender {
  self.interactionDepth++;
  @try { [super performClick:sender]; }
  @finally { self.interactionDepth--; }
}
+ (Class)cellClass { return ICPopUpButtonCell.class; }
- (instancetype)initWithFrame:(NSRect)frame pullsDown:(BOOL)pullsDown {
  if ((self=[super initWithFrame:frame pullsDown:pullsDown])) {
    self.bordered=NO;
    self.alignment=NSTextAlignmentRight;
    self.controlSize=NSControlSizeRegular;
    self.font=[NSFont menuFontOfSize:0];
    self.menu.font=[NSFont menuFontOfSize:0];
    ((NSPopUpButtonCell *)self.cell).arrowPosition=NSPopUpNoArrow;
    // Own the whole selection set; AppKit's automatic marking can leave a
    // previous item checked when host refreshes change selection during tracking.
    ((NSPopUpButtonCell *)self.cell).altersStateOfSelectedItem=NO;
  }
  return self;
}
@end
