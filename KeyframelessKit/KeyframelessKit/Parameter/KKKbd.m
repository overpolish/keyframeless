/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKKbd.h"
#import "../KKTokens.h"
#import "../NSColor+KKColors.h"

static const CGFloat KKKbdHorizontalPadding = 3.0;
static const CGFloat KKKbdVerticalPadding = 0.5;
static const CGFloat KKKbdFontSize = 9.0;

@implementation KKKbd

+ (NSFont *)kbdFont {
  static NSFont *font = nil;
  static dispatch_once_t onceToken;
  dispatch_once(&onceToken, ^{
    font = [NSFont monospacedSystemFontOfSize:KKKbdFontSize
                                       weight:NSFontWeightRegular];
  });
  return font;
}

+ (NSAttributedString *)attributedStringWithKey:(NSString *)key {
  return [self attributedStringWithKey:key color:[NSColor inspectorLabel]];
}

+ (NSAttributedString *)attributedStringWithKey:(NSString *)key
                                          color:(NSColor *)color {
  NSFont *font = [self kbdFont];

  NSDictionary *textAttrs = @{
    NSFontAttributeName : font,
    NSForegroundColorAttributeName : color,
  };

  NSSize textSize = [key sizeWithAttributes:textAttrs];

  CGFloat width =
      ceil(textSize.width) + KKKbdHorizontalPadding * 2 + KKBorderWidthXS * 2;
  CGFloat height =
      ceil(textSize.height) + KKKbdVerticalPadding * 2 + KKBorderWidthXS * 2;
  NSSize imageSize = NSMakeSize(width, height);

  NSColor *bgColor = [color colorWithAlphaComponent:0.1];
  NSColor *borderColor = [color colorWithAlphaComponent:0.25];

  NSImage *image = [NSImage
       imageWithSize:imageSize
             flipped:NO
      drawingHandler:^BOOL(NSRect rect) {
        NSRect inset =
            NSInsetRect(rect, KKBorderWidthXS * 0.5, KKBorderWidthXS * 0.5);
        NSBezierPath *path =
            [NSBezierPath bezierPathWithRoundedRect:inset
                                            xRadius:KKRadiusSM
                                            yRadius:KKRadiusSM];

        [bgColor set];
        [path fill];

        path.lineWidth = KKBorderWidthXS;
        [borderColor set];
        [path stroke];

        NSPoint textOrigin =
            NSMakePoint(KKKbdHorizontalPadding + KKBorderWidthXS,
                        KKKbdVerticalPadding + KKBorderWidthXS);
        [key drawAtPoint:textOrigin withAttributes:textAttrs];

        return YES;
      }];

  NSTextAttachment *attachment = [[NSTextAttachment alloc] init];
  attachment.image = image;

  // Align badge vertically: center on the cap-height of the surrounding text
  NSFont *labelFont = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]
                                        weight:NSFontWeightLight];
  CGFloat yOffset = floor((labelFont.capHeight - height) / 2.0);
  attachment.bounds = NSMakeRect(0, yOffset, width, height);

  return [NSAttributedString attributedStringWithAttachment:attachment];
}

@end
