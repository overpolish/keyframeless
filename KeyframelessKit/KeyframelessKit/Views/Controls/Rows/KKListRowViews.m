/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKListRowViews.h"

#import "KKTokens.h"

@implementation KKListGlyphView
- (NSView *)hitTest:(NSPoint)point {
  return nil;
}
@end

@implementation KKListNameLabel
- (NSView *)hitTest:(NSPoint)point {
  return nil;
}
@end

@implementation KKListPassthroughView
- (NSView *)hitTest:(NSPoint)point {
  return nil;
}
@end

@implementation KKListFirstMouseButton
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}
@end

NSButton *KKListIconButton(NSString *symbol, NSImageSymbolConfiguration *cfg,
                           id target, SEL action, NSUInteger tag,
                           NSColor *tint) {
  NSImage *img = [[NSImage imageWithSystemSymbolName:symbol
                            accessibilityDescription:nil]
      imageWithSymbolConfiguration:cfg];
  NSButton *b = [KKListFirstMouseButton buttonWithImage:img
                                                 target:target
                                                 action:action];
  b.bezelStyle = NSBezelStyleInline;
  b.bordered = NO;
  b.imagePosition = NSImageOnly;
  b.tag = (NSInteger)tag;
  b.contentTintColor = tint;
  [b.widthAnchor constraintEqualToConstant:KKIconSizeSM].active = YES;
  [b.heightAnchor constraintEqualToConstant:KKIconSizeSM].active = YES;
  return b;
}
