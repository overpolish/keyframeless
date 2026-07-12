/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "CanvasLayerRowViews.h"

#import <KeyframelessKit/KKFieldEditorSupport.h>
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
// The Edit-menu combos (Cmd-A/C/V/X) arrive as key equivalents in the
// ViewBridge popover; handle those. Do NOT [editor keyDown:]-forward anything
// else - in this child panel it bounces back out as another
// performKeyEquivalent and spins (the Esc-after-rename runaway that aborts the
// OSC render). Regular typing reaches the field editor via the normal key path
// (the panel is really key); Enter/Esc are handled in
// control:textView:doCommandBySelector:.
- (BOOL)performKeyEquivalent:(NSEvent *)event {
  if (KKHandleEditMenuKeyEquivalent(self.currentEditor, event))
    return YES;
  return [super performKeyEquivalent:event];
}
- (BOOL)becomeFirstResponder {
  BOOL ok = [super becomeFirstResponder];
  if (ok) {
    KKStyleFieldEditorAccent(self.currentEditor);
    __weak typeof(self) weak = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      KKStyleFieldEditorAccent(weak.currentEditor);
    });
  }
  return ok;
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
