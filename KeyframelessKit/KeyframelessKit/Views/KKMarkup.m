/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKMarkup.h"
#import "../Style/NSColor+KKColors.h"
#import "KKKbd.h"

@implementation KKMarkup

+ (NSAttributedString *)attributedStringFromMarkup:(NSString *)markup {
  NSMutableAttributedString *result = [[NSMutableAttributedString alloc] init];
  NSScanner *scanner = [NSScanner scannerWithString:markup];
  scanner.charactersToBeSkipped = nil;

  while (!scanner.isAtEnd) {
    NSString *text = nil;
    if ([scanner scanUpToString:@"<" intoString:&text]) {
      [result appendAttributedString:[[NSAttributedString alloc]
                                         initWithString:text]];
    }

    if (scanner.isAtEnd)
      break;

    if ([scanner scanString:@"<kbd>" intoString:nil]) {
      NSString *key = nil;
      [scanner scanUpToString:@"</kbd>" intoString:&key];
      [scanner scanString:@"</kbd>" intoString:nil];
      if (key) {
        [result appendAttributedString:[KKKbd attributedStringWithKey:key]];
      }
    } else if ([scanner scanString:@"<accent>" intoString:nil]) {
      NSString *body = nil;
      [scanner scanUpToString:@"</accent>" intoString:&body];
      [scanner scanString:@"</accent>" intoString:nil];
      if (body) {
        [result appendAttributedString:[self _coloredBold:body
                                                    color:[NSColor accent]]];
      }
    } else if ([scanner scanString:@"<warn>" intoString:nil]) {
      NSString *body = nil;
      [scanner scanUpToString:@"</warn>" intoString:&body];
      [scanner scanString:@"</warn>" intoString:nil];
      if (body) {
        [result appendAttributedString:[self _coloredBold:body
                                                    color:[NSColor warning]]];
      }
    } else if ([scanner scanString:@"<symbol " intoString:nil]) {
      NSString *content = nil;
      [scanner scanUpToString:@"/>" intoString:&content];
      [scanner scanString:@"/>" intoString:nil];
      if (content) {
        [result appendAttributedString:[self _parseSymbol:content]];
      }
    } else {
      // Literal '<' that isn't a known tag
      [scanner scanString:@"<" intoString:nil];
      [result appendAttributedString:[[NSAttributedString alloc]
                                         initWithString:@"<"]];
    }
  }

  return result;
}

+ (NSAttributedString *)_coloredBold:(NSString *)body color:(NSColor *)color {
  NSFont *font = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]
                                   weight:NSFontWeightSemibold];
  return
      [[NSAttributedString alloc] initWithString:body
                                      attributes:@{
                                        NSForegroundColorAttributeName : color,
                                        NSFontAttributeName : font,
                                      }];
}

+ (NSAttributedString *)_parseSymbol:(NSString *)content {
  NSArray<NSString *> *parts = [content
      componentsSeparatedByCharactersInSet:[NSCharacterSet
                                               whitespaceCharacterSet]];

  NSString *name = parts.firstObject;
  NSColor *color = [NSColor inspectorLabel];

  for (NSString *part in parts) {
    if ([part hasPrefix:@"color="]) {
      NSString *colorName = [part substringFromIndex:6];
      if ([colorName isEqualToString:@"white"]) {
        color = [NSColor whiteColor];
      } else if ([colorName isEqualToString:@"accent"]) {
        color = [NSColor accent];
      } else if ([colorName isEqualToString:@"warning"]) {
        color = [NSColor warning];
      }
    }
  }

  return [self _inlineSymbol:name color:color];
}

+ (NSAttributedString *)_inlineSymbol:(NSString *)name color:(NSColor *)color {
  NSFont *labelFont = [NSFont systemFontOfSize:[NSFont smallSystemFontSize]
                                        weight:NSFontWeightLight];
  NSImage *img = [NSImage imageWithSystemSymbolName:name
                           accessibilityDescription:nil];
  NSImageSymbolConfiguration *cfg = [NSImageSymbolConfiguration
      configurationWithPointSize:labelFont.pointSize - 2.0
                          weight:NSFontWeightRegular];
  img = [img imageWithSymbolConfiguration:cfg];

  NSSize size = img.size;
  NSImage *tinted =
      [NSImage imageWithSize:size
                     flipped:NO
              drawingHandler:^BOOL(NSRect rect) {
                [img drawInRect:rect
                       fromRect:NSZeroRect
                      operation:NSCompositingOperationSourceOver
                       fraction:1.0];
                [color set];
                NSRectFillUsingOperation(rect, NSCompositingOperationSourceIn);
                return YES;
              }];

  NSTextAttachment *att = [[NSTextAttachment alloc] init];
  att.image = tinted;
  CGFloat yOff = floor((labelFont.capHeight - size.height) / 2.0) + 0.5;
  att.bounds = NSMakeRect(0, yOff, size.width, size.height);

  return [NSAttributedString attributedStringWithAttachment:att];
}

@end
