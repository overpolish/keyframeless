/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "ICValueFieldEditor.h"
#import "ICValueTextField_Private.h"
#import "InspectorTokens.h"

void ICStyleFieldEditorAccent(NSText *editor) {
  if (![editor isKindOfClass:[NSTextView class]]) return;
  NSTextView *textView = (NSTextView *)editor;
  NSColor *accent = ICInspectorTokens.accentMatchingHost;
  textView.insertionPointColor = accent;
  textView.selectedTextAttributes = @{
    NSBackgroundColorAttributeName : ICInspectorTokens.selectionColor,
    NSForegroundColorAttributeName : ICInspectorTokens.valueColor,
  };
}

BOOL ICHandleEditMenuKeyEquivalent(NSText *editor, NSEvent *event) {
  if (!editor || (event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask) != NSEventModifierFlagCommand)
    return NO;
  NSString *key = event.charactersIgnoringModifiers.lowercaseString;
  if ([key isEqualToString:@"a"]) { [editor selectAll:nil]; return YES; }
  if ([key isEqualToString:@"c"]) { [(id)editor copy:nil]; return YES; }
  if ([key isEqualToString:@"v"]) { [(id)editor paste:nil]; return YES; }
  if ([key isEqualToString:@"x"]) { [(id)editor cut:nil]; return YES; }
  return NO;
}

void ICRegisterValueCursorRects(NSView *view, NSRect text, BOOL enabled) {
  NSRect bounds=view.bounds;
  text=NSIntersectionRect(bounds,text);
  if (!enabled || NSIsEmptyRect(text)) {
    [view addCursorRect:bounds cursor:NSCursor.arrowCursor];
    return;
  }
  // Disjoint rectangles keep AppKit's text cursor out of the surrounding space.
  NSRect blanks[]={
    NSMakeRect(NSMinX(bounds),NSMinY(bounds),NSWidth(bounds),NSMinY(text)-NSMinY(bounds)),
    NSMakeRect(NSMinX(bounds),NSMaxY(text),NSWidth(bounds),NSMaxY(bounds)-NSMaxY(text)),
    NSMakeRect(NSMinX(bounds),NSMinY(text),NSMinX(text)-NSMinX(bounds),NSHeight(text)),
    NSMakeRect(NSMaxX(text),NSMinY(text),NSMaxX(bounds)-NSMaxX(text),NSHeight(text))
  };
  for (NSUInteger i=0;i<4;i++) if (!NSIsEmptyRect(blanks[i]))
    [view addCursorRect:blanks[i] cursor:NSCursor.arrowCursor];
  [view addCursorRect:text cursor:NSCursor.IBeamCursor];
}

@implementation ICValueFieldEditor
- (void)mouseDown:(NSEvent *)event {
  ICValueTextField *field=self.valueField;
  if ((event.modifierFlags & NSEventModifierFlagControl) && field.contextMenuProvider) {
    [field.window makeFirstResponder:nil];
    [field mouseDown:event];
    return;
  }
  // Editor clicks must also work without the app-local event monitor.
  if (field && ![field eventIsOverValue:event]) {
    [field blurForOutsideClick:event];
    return;
  }
  [super mouseDown:event];
}
- (void)rightMouseDown:(NSEvent *)event {
  ICValueTextField *field=self.valueField;
  if (field.contextMenuProvider) {
    [field.window makeFirstResponder:nil];
    [field rightMouseDown:event];
    return;
  }
  [super rightMouseDown:event];
}
- (NSRange)rangeForUserCompletion { return NSMakeRange(NSNotFound,0); }
- (void)configureNumericInput {
  self.contentType=nil;
  self.automaticTextCompletionEnabled=NO;
  self.automaticSpellingCorrectionEnabled=NO;
  self.continuousSpellCheckingEnabled=NO;
  self.grammarCheckingEnabled=NO;
  self.automaticTextReplacementEnabled=NO;
  self.automaticQuoteSubstitutionEnabled=NO;
  self.automaticDashSubstitutionEnabled=NO;
  self.automaticDataDetectionEnabled=NO;
  self.automaticLinkDetectionEnabled=NO;
  if (@available(macOS 14.0,*)) self.inlinePredictionType=NSTextInputTraitTypeNo;
  if (@available(macOS 15.0,*)) {
    self.mathExpressionCompletionType=NSTextInputTraitTypeNo;
    self.writingToolsBehavior=NSWritingToolsBehaviorNone;
  }
}
- (void)resetCursorRects {
  ICValueTextField *field=self.valueField;
  NSRect text=field ? [self convertRect:[field visibleValueRect] fromView:field] : NSZeroRect;
  ICRegisterValueCursorRects(self,text,field.enabled);
}
- (NSMenu *)menuForEvent:(NSEvent *)event {
  ICValueTextField *field=self.valueField;
  if (field.contextMenuProvider) {
    [self.window makeFirstResponder:nil];
    return [field menuForEvent:event];
  }
  return [super menuForEvent:event];
}
@end

// AppKit substitutes its own disabled text colour. Draw using our explicit
// token while retaining the disabled state for editing and hit testing.
@implementation ICValueTextFieldCell
- (NSTextView *)fieldEditorForView:(NSView *)view {
  if (![view isKindOfClass:ICValueTextField.class]) return [super fieldEditorForView:view];
  if (!self.valueEditor) {
    self.valueEditor=[[ICValueFieldEditor alloc] initWithFrame:NSZeroRect];
    self.valueEditor.fieldEditor=YES;
  }
  [self.valueEditor configureNumericInput];
  self.valueEditor.valueField=(ICValueTextField *)view;
  return self.valueEditor;
}
- (void)drawInteriorWithFrame:(NSRect)frame inView:(NSView *)view {
  BOOL enabled=self.enabled;
  if (!enabled) self.enabled=YES;
  @try { [super drawInteriorWithFrame:frame inView:view]; }
  @finally { if (!enabled) self.enabled=NO; }
}
@end
