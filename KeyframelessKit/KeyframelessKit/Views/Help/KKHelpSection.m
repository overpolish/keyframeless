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

@implementation KKHelpGuide

+ (instancetype)guideWithTitle:(NSString *)title
                      subtitle:(nullable NSString *)subtitle
                       onStart:(void (^)(void))onStart {
  KKHelpGuide *g = [[self alloc] init];
  g->_title = [title copy];
  g->_subtitle = [subtitle copy];
  g->_onStart = [onStart copy];
  return g;
}

+ (NSString *)_completedDefaultsKeyForIdentifier:(NSString *)identifier {
  return [@"KKHelpGuideCompleted." stringByAppendingString:identifier];
}

- (NSString *)_completedDefaultsKey {
  return [KKHelpGuide
      _completedDefaultsKeyForIdentifier:(self.identifier.length
                                              ? self.identifier
                                              : self.title)];
}

- (BOOL)hasBeenCompleted {
  return [NSUserDefaults.standardUserDefaults
      boolForKey:[self _completedDefaultsKey]];
}

- (void)markCompleted {
  [NSUserDefaults.standardUserDefaults setBool:YES
                                        forKey:[self _completedDefaultsKey]];
  [NSUserDefaults.standardUserDefaults synchronize];
}

+ (void)markIdentifierCompleted:(NSString *)identifier {
  if (identifier.length == 0)
    return;
  [NSUserDefaults.standardUserDefaults
      setBool:YES
       forKey:[self _completedDefaultsKeyForIdentifier:identifier]];
  [NSUserDefaults.standardUserDefaults synchronize];
}

+ (BOOL)isIdentifierCompleted:(NSString *)identifier {
  if (identifier.length == 0)
    return NO;
  return [NSUserDefaults.standardUserDefaults
      boolForKey:[self _completedDefaultsKeyForIdentifier:identifier]];
}

@end
