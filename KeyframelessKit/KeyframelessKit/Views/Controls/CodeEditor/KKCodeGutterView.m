/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKCodeGutterView.h"
#import "KKGLSLSyntax.h"

@implementation KKCodeGutterView

- (BOOL)isFlipped {
  return YES; // y grows downward, matching the text view
}

- (void)drawRect:(NSRect)dirtyRect {
  [KKCodeBG() setFill];
  NSRectFill(self.bounds);
  [KKCodeBorder() setFill];
  NSRectFill(
      NSMakeRect(NSMaxX(self.bounds) - 1.0, 0, 1.0, NSHeight(self.bounds)));

  NSTextView *tv = self.textView;
  if (!tv)
    return;
  NSLayoutManager *lm = tv.layoutManager;
  NSTextContainer *tc = tv.textContainer;
  NSString *s = tv.string;
  CGFloat insetH = tv.textContainerInset.height;
  NSRect visible = tv.visibleRect;
  NSDictionary *attrs = @{
    NSFontAttributeName :
        [NSFont monospacedDigitSystemFontOfSize:8.5 weight:NSFontWeightRegular],
    NSForegroundColorAttributeName : KKCodeComment(),
  };

  if (s.length == 0) {
    [@"1" drawAtPoint:NSMakePoint(NSWidth(self.bounds) - 12.0,
                                  insetH - NSMinY(visible) + 0.5)
        withAttributes:attrs];
    return;
  }

  NSRange glyphRange = [lm glyphRangeForBoundingRect:visible
                                     inTextContainer:tc];
  NSRange charRange = [lm characterRangeForGlyphRange:glyphRange
                                     actualGlyphRange:NULL];
  NSUInteger lineNo = 1;
  for (NSUInteger i = 0; i < charRange.location; i++)
    if ([s characterAtIndex:i] == '\n')
      lineNo++;

  NSUInteger glyphIdx = glyphRange.location;
  while (glyphIdx < NSMaxRange(glyphRange)) {
    NSUInteger charIdx = [lm characterIndexForGlyphAtIndex:glyphIdx];
    NSRange lineRange = [s lineRangeForRange:NSMakeRange(charIdx, 0)];
    NSRange lineGlyphs = [lm glyphRangeForCharacterRange:lineRange
                                    actualCharacterRange:NULL];
    NSRect frag = [lm lineFragmentRectForGlyphAtIndex:lineGlyphs.location
                                       effectiveRange:NULL];
    CGFloat rowY = NSMinY(frag) + insetH - NSMinY(visible);
    BOOL isError = ((NSInteger)lineNo == self.errorLine);
    if (isError) {
      [[KKCodeError() colorWithAlphaComponent:0.16] setFill];
      NSRectFill(NSMakeRect(0, rowY, NSWidth(self.bounds), NSHeight(frag)));
    }
    NSDictionary *a = isError ? @{
      NSFontAttributeName : attrs[NSFontAttributeName],
      NSForegroundColorAttributeName : KKCodeError(),
    }
                              : attrs;
    NSString *num = @(lineNo).stringValue;
    NSSize sz = [num sizeWithAttributes:a];
    [num drawAtPoint:NSMakePoint(NSWidth(self.bounds) - sz.width - 5.0,
                                 rowY + 0.5)
        withAttributes:a];
    lineNo++;
    if (lineGlyphs.length == 0)
      break;
    glyphIdx = NSMaxRange(lineGlyphs);
  }
}
@end
