/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "ICValueTextField+Scrub.h"
#import "ICValueFieldEditor.h"
#import "ICValueTextField_Private.h"
#import "InspectorTokens.h"

@implementation ICValueTextField {
  BOOL _icEditing;
  id _outsideClickMonitor;
}
- (NSMenu *)menuForEvent:(NSEvent *)event {
  BOOL context=event.type==NSEventTypeRightMouseDown ||
      (event.type==NSEventTypeLeftMouseDown && (event.modifierFlags & NSEventModifierFlagControl));
  if (context && self.contextMenuProvider) {
    NSMenu *menu=self.contextMenuProvider(); return menu;
  }
  return [super menuForEvent:event];
}

- (void)resetCursorRects {
  ICRegisterValueCursorRects(self,[self visibleValueRect],self.enabled);
}
- (void)invalidateValueCursorRects {
  [self.window invalidateCursorRectsForView:self];
  if (self.currentEditor) [self.window invalidateCursorRectsForView:self.currentEditor];
}
- (void)setObjectValue:(id)value {
  [super setObjectValue:value];
  [self invalidateValueCursorRects];
}
- (void)setDoubleValue:(double)value {
  [super setDoubleValue:value];
  [self invalidateValueCursorRects];
}
- (void)setStringValue:(NSString *)value {
  [super setStringValue:value];
  [self invalidateValueCursorRects];
}
- (void)textDidChange:(NSNotification *)notification {
  [super textDidChange:notification];
  [self invalidateValueCursorRects];
}
+ (Class)cellClass { return ICValueTextFieldCell.class; }

- (void)setEnabled:(BOOL)enabled {
  [super setEnabled:enabled];
  self.textColor=enabled ? ICInspectorTokens.valueColor : ICInspectorTokens.disabledTextColor;
  [self invalidateValueCursorRects];
}

+ (instancetype)valueField {
  ICValueTextField *field = [[self alloc] init];
  field.translatesAutoresizingMaskIntoConstraints = NO;
  field.font = ICInspectorTokens.valueFont;
  field.alignment = NSTextAlignmentRight;
  field.textColor = ICInspectorTokens.valueColor;
  field.backgroundColor = [NSColor clearColor];
  field.bordered = NO;
  field.bezeled = NO;
  field.drawsBackground = NO;
  field.focusRingType = NSFocusRingTypeNone;
  field.contentType = nil;
  field.automaticTextCompletionEnabled = NO;
  field.editable = YES;
  field.selectable = YES;
  field.usesSingleLineMode = YES;
  field.lineBreakMode = NSLineBreakByClipping;
  field.cell.wraps = NO;
  field.cell.scrollable = YES;
  [field.cell setSendsActionOnEndEditing:YES];
  return field;
}

- (BOOL)icEditing { return _icEditing; }
- (BOOL)acceptsFirstResponder { return self.userClickPending && self.isEnabled; }
- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }

- (NSRect)visibleValueRect {
  NSTextView *editor=[self.currentEditor isKindOfClass:NSTextView.class] ? (NSTextView *)self.currentEditor : nil;
  if (editor.layoutManager && editor.textContainer) {
    NSLayoutManager *layout=editor.layoutManager;
    [layout ensureLayoutForTextContainer:editor.textContainer];
    NSRange glyphs=[layout glyphRangeForTextContainer:editor.textContainer];
    NSRect rect=[layout boundingRectForGlyphRange:glyphs inTextContainer:editor.textContainer];
    rect=NSOffsetRect(rect,editor.textContainerOrigin.x,editor.textContainerOrigin.y);
    return NSIntersectionRect(self.bounds,[self convertRect:rect fromView:editor]);
  }
  NSRect rect=[self.cell titleRectForBounds:self.bounds];
  NSSize size=[self.stringValue sizeWithAttributes:@{NSFontAttributeName:self.font ?: ICInspectorTokens.valueFont}];
  CGFloat width=MIN(size.width,NSWidth(rect));
  if (self.alignment==NSTextAlignmentRight) rect.origin.x=NSMaxX(rect)-width;
  else if (self.alignment==NSTextAlignmentCenter) rect.origin.x+=(NSWidth(rect)-width)/2;
  rect.size.width=width;
  CGFloat height=MIN(size.height,NSHeight(rect));
  rect.origin.y+=(NSHeight(rect)-height)/2;
  rect.size.height=height;
  return NSIntersectionRect(self.bounds,rect);
}
- (BOOL)eventIsOverValue:(NSEvent *)event {
  return event.window==self.window &&
      NSPointInRect([self convertPoint:event.locationInWindow fromView:nil],[self visibleValueRect]);
}
- (void)blurForOutsideClick:(NSEvent *)event {
  if (![self eventIsOverValue:event]) [self.window makeFirstResponder:nil];
}

- (void)mouseDown:(NSEvent *)event {
  if ((event.modifierFlags & NSEventModifierFlagControl) && self.contextMenuProvider) {
    NSMenu *menu=self.contextMenuProvider();
    if (menu) [NSMenu popUpContextMenu:menu withEvent:event forView:self];
    return;
  }
  if (!self.isEnabled) return;
  if (![self eventIsOverValue:event]) {
    [self.window makeFirstResponder:nil];
    return;
  }
  if (self.currentEditor || self.scrubDisabled || !self.isEditable) {
    [self beginClickEditing:event];
    return;
  }
  [self trackScrubFromMouseDown:event];
}

- (void)beginClickEditing:(NSEvent *)event {
  self.userClickPending = YES;
  self.inMouseDown = YES;
  [super mouseDown:event];
  self.inMouseDown = NO;
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
  NSText *editor = self.currentEditor;
  if (editor && event.keyCode == 53) {
    [self.window makeFirstResponder:nil]; return YES;
  }
  if (ICHandleEditMenuKeyEquivalent(editor, event)) return YES;
  if (editor) { [editor keyDown:event]; return YES; }
  return [super performKeyEquivalent:event];
}

- (BOOL)becomeFirstResponder {
  BOOL result = [super becomeFirstResponder];
  if (!result) return NO;
  _icEditing = YES;
  [self installOutsideClickMonitor];
  [self styleFieldEditor];
  __weak typeof(self) weakSelf = self;
  dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf styleFieldEditor]; });
  return YES;
}

- (void)styleFieldEditor { ICStyleFieldEditorAccent(self.currentEditor); }
- (void)installOutsideClickMonitor {
  if (_outsideClickMonitor) return;
  __weak typeof(self) weakSelf = self;
  _outsideClickMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:(NSEventMaskLeftMouseDown | NSEventMaskRightMouseDown) handler:^NSEvent *(NSEvent *event) {
    ICValueTextField *field = weakSelf;
    // This monitor exists only while focused. currentEditor can be nil during
    // host event routing, so it must not gate the outside-click check.
    [field blurForOutsideClick:event];
    return event;
  }];
}
- (void)removeOutsideClickMonitor {
  if (_outsideClickMonitor) { [NSEvent removeMonitor:_outsideClickMonitor]; _outsideClickMonitor = nil; }
}
- (void)dealloc { [self removeOutsideClickMonitor]; }

- (void)textDidBeginEditing:(NSNotification *)notification {
  [super textDidBeginEditing:notification];
  _icEditing = YES;
  [self installOutsideClickMonitor];
}
- (void)textDidEndEditing:(NSNotification *)notification {
  [super textDidEndEditing:notification];
  if (!self.inMouseDown) [self removeOutsideClickMonitor];
  self.userClickPending = NO;
  _icEditing = NO;
  if (!self.inMouseDown && !self.icNavigatingAway) [self.window makeFirstResponder:nil];
}
- (void)focusForKeyboardNavigation {
  self.userClickPending = YES;
  if ([self.window makeFirstResponder:self]) [self selectText:nil];
}
@end
