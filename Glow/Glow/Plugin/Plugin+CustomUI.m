/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "Constants.h"
#import "Plugin_Private.h"
#import <objc/message.h>

@implementation GlowPlugin (CustomUI)

- (NSView *)createViewForParameterID:(UInt32)parameterID NS_RETURNS_RETAINED {
  if (parameterID == kParamInfoUsage) {
    NSAttributedString *text = [KKMarkup
        attributedStringFromMarkup:
            @"Use on an Adjustment Clip <kbd>⌥ A</kbd> or a Compound Clip "
            @"<kbd>⌥ G</kbd>"];
    KKAlertView *alert = [[KKAlertView alloc] initWithAttributedText:text];
    alert.icon = [NSImage imageWithSystemSymbolName:@"info.circle"
                           accessibilityDescription:nil];
    return alert;
  }
  struct objc_super sup = {self, [KKPlugin class]};
  return ((NSView * (*)(struct objc_super *, SEL, UInt32)) objc_msgSendSuper)(
      &sup, @selector(createViewForParameterID:), parameterID);
}

@end
