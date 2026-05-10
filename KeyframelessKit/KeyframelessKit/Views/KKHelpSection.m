/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKHelpSection.h"
#import "KKMarkup.h"

@implementation KKHelpShortcut

+ (instancetype)shortcutWithKeysMarkup:(NSString *)keysMarkup
                            descMarkup:(NSString *)descMarkup {
  KKHelpShortcut *s = [[self alloc] init];
  s->_keys = [KKMarkup attributedStringFromMarkup:keysMarkup];
  s->_desc = [KKMarkup attributedStringFromMarkup:descMarkup];
  return s;
}

@end

@implementation KKHelpSection

+ (instancetype)sectionWithTitle:(NSString *)title
                       tipMarkup:(NSArray<NSString *> *)tipMarkup
                       shortcuts:(NSArray<KKHelpShortcut *> *)shortcuts {
  KKHelpSection *s = [[self alloc] init];
  s->_title = [title copy];
  NSMutableArray<NSAttributedString *> *tips =
      [NSMutableArray arrayWithCapacity:tipMarkup.count];
  for (NSString *m in tipMarkup)
    [tips addObject:[KKMarkup attributedStringFromMarkup:m]];
  s->_tips = [tips copy];
  s->_shortcuts = [shortcuts copy] ?: @[];
  return s;
}

@end
