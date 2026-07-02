/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerRowViews.h"

#import <KeyframelessKit/KKTokens.h>
#import <KeyframelessKit/NSColor+KKColors.h>

@implementation CanvasLayerGlyphView
- (NSView *)hitTest:(NSPoint)point {
  return nil;
}
@end

@implementation CanvasLayerNameLabel
- (NSView *)hitTest:(NSPoint)point {
  return nil;
}
@end

@implementation CanvasLayerPassthroughView
- (NSView *)hitTest:(NSPoint)point {
  return nil;
}
@end

@implementation CanvasLayerFirstMouseButton
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}
@end

@implementation CanvasLayerRenameField
- (BOOL)acceptsFirstResponder {
  return YES;
}
// In a ViewBridge popover key events arrive as key equivalents to the window,
// not normal keyDown to the field editor - forward them (matches
// KKValueTextField), incl. the Cmd-A/C/V/X the missing Edit menu would handle.
- (BOOL)performKeyEquivalent:(NSEvent *)event {
  NSText *editor = self.currentEditor;
  if (editor) {
    NSEventModifierFlags m =
        event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
    if (m == NSEventModifierFlagCommand) {
      NSString *key = event.charactersIgnoringModifiers.lowercaseString;
      if ([key isEqualToString:@"a"]) {
        [editor selectAll:nil];
        return YES;
      }
      if ([key isEqualToString:@"c"]) {
        [(id)editor copy:nil];
        return YES;
      }
      if ([key isEqualToString:@"v"]) {
        [(id)editor paste:nil];
        return YES;
      }
      if ([key isEqualToString:@"x"]) {
        [(id)editor cut:nil];
        return YES;
      }
    }
    [editor keyDown:event];
    return YES;
  }
  return [super performKeyEquivalent:event];
}
- (BOOL)becomeFirstResponder {
  BOOL ok = [super becomeFirstResponder];
  if (ok) {
    [self _styleEditor];
    __weak typeof(self) weak = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      [weak _styleEditor];
    });
  }
  return ok;
}
// Accent caret + selection, matching KKValueTextField.
- (void)_styleEditor {
  NSText *ed = self.currentEditor;
  if (![ed isKindOfClass:[NSTextView class]])
    return;
  NSTextView *editor = (NSTextView *)ed;
  NSColor *accent = [NSColor accentMatchingHost];
  editor.insertionPointColor = accent;
  editor.selectedTextAttributes = @{
    NSBackgroundColorAttributeName : [accent colorWithAlphaComponent:0.3],
    NSForegroundColorAttributeName : NSColor.labelColor,
  };
}
@end

NSSet<NSString *> *CanvasLayerImageExtensions(void) {
  static NSSet *exts;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    exts = [NSSet setWithObjects:@"png", @"jpg", @"jpeg", @"webp", @"heic",
                                 @"tiff", @"tif", @"gif", @"bmp", nil];
  });
  return exts;
}

NSButton *CanvasLayerIconButton(NSString *symbol,
                                NSImageSymbolConfiguration *cfg, id target,
                                SEL action, NSUInteger tag, NSColor *tint) {
  NSImage *img = [[NSImage imageWithSystemSymbolName:symbol
                            accessibilityDescription:nil]
      imageWithSymbolConfiguration:cfg];
  NSButton *b = [CanvasLayerFirstMouseButton buttonWithImage:img
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
