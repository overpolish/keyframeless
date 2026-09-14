/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKHelpSection+Markdown.h"
#import "KKLocalized.h"

NSString *const KKHelpTipIndentMarker = @"\002";

@implementation KKHelpSection (Markdown)

+ (NSString *)_bodyFromKnowledgeMarkdown:(NSString *)raw {
  NSString *s = raw;
  if ([s hasPrefix:@"---\n"]) {
    NSRange after = NSMakeRange(4, s.length - 4);
    NSRange term = [s rangeOfString:@"\n---" options:0 range:after];
    if (term.location != NSNotFound) {
      NSUInteger start = term.location + term.length;
      NSRange nl = [s rangeOfString:@"\n"
                            options:0
                              range:NSMakeRange(start, s.length - start)];
      if (nl.location != NSNotFound)
        start = nl.location + 1;
      s = [s substringFromIndex:start];
    }
  }
  return
      [s stringByTrimmingCharactersInSet:[NSCharacterSet
                                             whitespaceAndNewlineCharacterSet]];
}

+ (void)_replacePattern:(NSString *)pattern
               template:(NSString *)tmpl
                     in:(NSMutableString *)s {
  NSRegularExpression *re =
      [NSRegularExpression regularExpressionWithPattern:pattern
                                                options:0
                                                  error:nil];
  [re replaceMatchesInString:s
                     options:0
                       range:NSMakeRange(0, s.length)
                withTemplate:tmpl];
}

+ (NSString *)_inlineMarkupFromMarkdown:(NSString *)text {
  NSMutableString *s = [text mutableCopy];
  [self _replacePattern:@"\\*\\*(.+?)\\*\\*"
               template:@"<accent>$1</accent>"
                     in:s];
  [self _replacePattern:@"`([^`]+?)`" template:@"<kbd>$1</kbd>" in:s];
  return [s copy];
}

// Leading-space count of a line (markdown indentation).
+ (NSUInteger)_indentOf:(NSString *)line {
  NSUInteger n = 0;
  while (n < line.length && [line characterAtIndex:n] == ' ')
    n++;
  return n;
}

+ (NSArray<NSString *> *)tipMarkupFromKnowledgeMarkdown:(NSString *)markdown {
  NSString *body = [self _bodyFromKnowledgeMarkdown:markdown];
  if (body.length == 0)
    return @[];
  NSArray<NSString *> *lines = [body componentsSeparatedByString:@"\n"];
  NSCharacterSet *ws = [NSCharacterSet whitespaceCharacterSet];
  NSMutableArray<NSString *> *tips = [NSMutableArray array];
  NSUInteger i = 0, n = lines.count;
  // A leading `# Title` H1 is the doc's title, not a section boundary - skip it
  // so a doc that opens with one still renders its intro region (some docs lead
  // with bullets and no title, some with an H1 + blurb; both should work). Only
  // the H1 immediately at the top is a title; a later `#` is a real section.
  {
    NSUInteger j = i;
    while (j < n && [lines[j] stringByTrimmingCharactersInSet:ws].length == 0)
      j++;
    if (j < n) {
      NSString *first = [lines[j] stringByTrimmingCharactersInSet:ws];
      if ([first hasPrefix:@"# "])
        i = j + 1;
    }
  }
  while (i < n) {
    NSString *line = lines[i];
    NSString *trimmed = [line stringByTrimmingCharactersInSet:ws];
    if (trimmed.length == 0) {
      i++;
      continue;
    }
    // Stop at the first heading OR fenced code block: help renders only the
    // topic's intro region (a short blurb + key bullets), keeping it a
    // skimmable quick reference. The long-form `## ...` sections and code
    // examples stay AI-only. Timeline docs have no headings, so they render in
    // full.
    if ([trimmed hasPrefix:@"#"] || [trimmed hasPrefix:@"```"])
      break;
    // A bullet (at any indent) starts its own tip; its indentation (2 spaces
    // per level) becomes the tip's nesting depth. A non-bullet paragraph is a
    // depth-0 tip. Wrapped continuation lines fold into the current tip.
    BOOL isBullet = [trimmed hasPrefix:@"- "];
    NSUInteger depth = isBullet ? ([self _indentOf:line] / 2) : 0;
    NSMutableString *tip =
        [(isBullet ? [trimmed substringFromIndex:2] : trimmed) mutableCopy];
    i++;
    while (i < n) {
      NSString *t = [lines[i] stringByTrimmingCharactersInSet:ws];
      if (t.length == 0)
        break;
      if ([t hasPrefix:@"- "] || [t hasPrefix:@"#"] || [t hasPrefix:@"```"])
        break;
      [tip appendString:@" "];
      [tip appendString:t];
      i++;
    }
    NSMutableString *prefix = [NSMutableString string];
    for (NSUInteger d = 0; d < depth; d++)
      [prefix appendString:KKHelpTipIndentMarker];
    [tips addObject:[prefix stringByAppendingString:
                                [self _inlineMarkupFromMarkdown:tip]]];
  }
  return tips;
}

+ (NSArray<NSString *> *)
    tipMarkupFromKnowledgeTopic:(NSString *)topicID
                       inBundle:(NSBundle *)bundle
                   subdirectory:(NSString *)subdir
                      localizer:(NSString * (^)(NSString *))localizer {
  NSURL *url = [bundle URLForResource:topicID
                        withExtension:@"md"
                         subdirectory:subdir];
  // Plugin bundles flatten their Resources, so the AIKnowledge subdirectory is
  // gone at runtime - fall back to a flat lookup, mirroring the AI doc loader.
  if (!url && subdir.length > 0)
    url = [bundle URLForResource:topicID withExtension:@"md" subdirectory:nil];
  NSString *raw = url ? [NSString stringWithContentsOfURL:url
                                                 encoding:NSUTF8StringEncoding
                                                    error:nil]
                      : nil;
  if (raw.length == 0)
    return @[];
  NSArray<NSString *> *tips = [self tipMarkupFromKnowledgeMarkdown:raw];
  if (!localizer)
    return tips;
  NSMutableArray<NSString *> *out =
      [NSMutableArray arrayWithCapacity:tips.count];
  for (NSString *tip in tips) {
    // Localize the bare tip; keep any leading indent markers out of the
    // catalog key, then re-apply them to the translation.
    NSUInteger d = 0;
    while (d < tip.length && [tip characterAtIndex:d] == 0x0002)
      d++;
    NSString *prefix = [tip substringToIndex:d];
    NSString *bare = [tip substringFromIndex:d];
    [out addObject:[prefix stringByAppendingString:localizer(bare)]];
  }
  return out;
}

+ (NSArray<NSString *> *)localizedTipMarkupFromKnowledgeTopic:
    (NSString *)topicID {
  return
      [self tipMarkupFromKnowledgeTopic:topicID
                               inBundle:[NSBundle bundleForClass:[self class]]
                           subdirectory:nil
                              localizer:^NSString *(NSString *tip) {
                                return KKLoc(tip, @"Help tip rendered from a "
                                                  @"timeline knowledge doc.");
                              }];
}

@end
