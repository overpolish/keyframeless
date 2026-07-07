/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKMarkup.h"
#import "KKKbd.h"
#import "NSColor+KKColors.h"

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
    } else if ([self _scanColoredTagInto:result scanner:scanner]) {
      // handled a <accent>/<warn>/<red>/<blue> text run
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

// Named colors shared by the colored text tags (`<accent>`, `<warn>`, `<red>`,
// `<blue>`) and `<symbol color=…>`. nil for an unknown name so callers keep
// their own default.
+ (nullable NSColor *)_colorNamed:(NSString *)name {
  if ([name isEqualToString:@"accent"])
    return [NSColor accent];
  if ([name isEqualToString:@"warn"] || [name isEqualToString:@"warning"])
    return [NSColor warning];
  if ([name isEqualToString:@"red"])
    return [NSColor onionPrevTint];
  if ([name isEqualToString:@"blue"])
    return [NSColor onionNextTint];
  if ([name isEqualToString:@"white"])
    return [NSColor whiteColor];
  return nil;
}

// Tag names that wrap a bold colored text run (`<name>body</name>`). The tag
// name is also the color name via `_colorNamed:`.
+ (NSArray<NSString *> *)_coloredTagNames {
  return @[ @"accent", @"warn", @"red", @"blue" ];
}

// If the scanner is at a colored text tag, consume `<name>body</name>`, append
// the colored run, and return YES. Otherwise leaves the scanner untouched and
// returns NO.
+ (BOOL)_scanColoredTagInto:(NSMutableAttributedString *)result
                    scanner:(NSScanner *)scanner {
  for (NSString *name in [self _coloredTagNames]) {
    NSString *open = [NSString stringWithFormat:@"<%@>", name];
    if (![scanner scanString:open intoString:nil])
      continue;
    NSString *close = [NSString stringWithFormat:@"</%@>", name];
    NSString *body = nil;
    [scanner scanUpToString:close intoString:&body];
    [scanner scanString:close intoString:nil];
    if (body)
      [result
          appendAttributedString:[self _coloredBold:body
                                              color:[self _colorNamed:name]]];
    return YES;
  }
  return NO;
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
      NSColor *named = [self _colorNamed:[part substringFromIndex:6]];
      if (named)
        color = named;
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
