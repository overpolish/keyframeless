/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "ICValueTextField.h"
#import "InspectorTokens.h"
#import <CoreGraphics/CoreGraphics.h>

static const CGFloat kICScrubStartThreshold = 3.0;
static const CGFloat kICScrubPointsPerStep = 4.0;
static const double kICScrubCoarseMultiplier = 10.0;
static const double kICScrubFineMultiplier = 0.1;

NSInteger ICScrubWholeStepsForTravel(CGFloat travel) {
  return (NSInteger)(travel / kICScrubPointsPerStep);
}

static NSCursor *ICBlankCursor(void) {
  static NSCursor *blank;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    blank = [[NSCursor alloc] initWithImage:image hotSpot:NSZeroPoint];
  });
  return blank;
}

static void ICStyleFieldEditorAccent(NSText *editor) {
  if (![editor isKindOfClass:[NSTextView class]]) return;
  NSTextView *textView = (NSTextView *)editor;
  NSColor *accent = ICInspectorTokens.accentMatchingHost;
  textView.insertionPointColor = accent;
  textView.selectedTextAttributes = @{
    NSBackgroundColorAttributeName : ICInspectorTokens.selectionColor,
    NSForegroundColorAttributeName : ICInspectorTokens.valueColor,
  };
}

static BOOL ICHandleEditMenuKeyEquivalent(NSText *editor, NSEvent *event) {
  if (!editor || (event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask) != NSEventModifierFlagCommand)
    return NO;
  NSString *key = event.charactersIgnoringModifiers.lowercaseString;
  if ([key isEqualToString:@"a"]) { [editor selectAll:nil]; return YES; }
  if ([key isEqualToString:@"c"]) { [(id)editor copy:nil]; return YES; }
  if ([key isEqualToString:@"v"]) { [(id)editor paste:nil]; return YES; }
  if ([key isEqualToString:@"x"]) { [(id)editor cut:nil]; return YES; }
  return NO;
}

@interface ICValueTextField (CursorGeometry)
- (NSRect)visibleValueRect;
- (BOOL)eventIsOverValue:(NSEvent *)event;
- (void)blurForOutsideClick:(NSEvent *)event;
@end

static void ICRegisterValueCursorRects(NSView *view, NSRect text, BOOL enabled) {
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

@interface ICValueFieldEditor : NSTextView
@property(nonatomic,weak) ICValueTextField *valueField;
@end
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
@interface ICValueTextFieldCell : NSTextFieldCell
@property(nonatomic,strong) ICValueFieldEditor *valueEditor;
@end
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

@interface ICValueTextField ()
@property(nonatomic) BOOL icNavigatingAway;
@end

@implementation ICValueTextField {
  BOOL _userClickPending;
  BOOL _icEditing;
  BOOL _icScrubbing;
  BOOL _inMouseDown;
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
- (BOOL)icScrubbing { return _icScrubbing; }
- (BOOL)acceptsFirstResponder { return _userClickPending && self.isEnabled; }
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
  _userClickPending = YES;
  _inMouseDown = YES;
  [super mouseDown:event];
  _inMouseDown = NO;
}

- (void)scrubBy:(double)delta {
  double old=self.doubleValue, value=old+delta;
  if([self.formatter isKindOfClass:NSNumberFormatter.class]) {
    NSNumberFormatter *formatter=(NSNumberFormatter *)self.formatter;
    if(formatter.minimum) value=fmax(value,formatter.minimum.doubleValue);
    if(formatter.maximum) value=fmin(value,formatter.maximum.doubleValue);
  }
  // Formatter bounds normally validate typed text; programmatic drag values
  // need the same bounds before dispatch, without rejecting/beeping at an edge.
  if(!isfinite(value) || value==old) return;
  self.doubleValue=value;
  [self sendAction:self.action to:self.target];
}

- (void)trackScrubFromMouseDown:(NSEvent *)event {
  double step = self.scrubStep > 0 ? self.scrubStep : 1.0;
  CGFloat residual = 0, startTravel = 0;
  BOOL scrubbing = NO;
  NSPoint anchor = NSEvent.mouseLocation;
  CGFloat screenHeight = NSScreen.screens.count ? NSHeight(NSScreen.screens.firstObject.frame) : 0;
  CGPoint anchorCG = CGPointMake(anchor.x, screenHeight - anchor.y);
  NSEventMask mask = NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp;
  @try {
    while (YES) {
      NSEvent *event = [self.window nextEventMatchingMask:mask];
      if (!event || event.type == NSEventTypeLeftMouseUp) break;
      CGFloat delta = event.deltaX - event.deltaY;
      if (!scrubbing) {
        startTravel += delta;
        if (fabs(startTravel) < kICScrubStartThreshold) continue;
        scrubbing = YES;
        _icScrubbing = YES;
        CGAssociateMouseAndMouseCursorPosition(false);
        if (self.onScrubBegin) self.onScrubBegin();
      }
      [ICBlankCursor() set];
      double multiplier = 1.0;
      if (event.modifierFlags & NSEventModifierFlagShift) multiplier *= kICScrubCoarseMultiplier;
      if (event.modifierFlags & NSEventModifierFlagOption) multiplier *= kICScrubFineMultiplier;
      residual += delta;
      NSInteger steps = ICScrubWholeStepsForTravel(residual);
      if (steps) {
        residual -= (CGFloat)steps * kICScrubPointsPerStep;
        [self scrubBy:(double)steps * step * multiplier];
      }
      if (screenHeight > 0) CGWarpMouseCursorPosition(anchorCG);
    }
  } @finally {
    if (scrubbing) {
      if (screenHeight > 0) CGWarpMouseCursorPosition(anchorCG);
      CGAssociateMouseAndMouseCursorPosition(true);
      [[NSCursor arrowCursor] set];
      @try {
        if (self.onScrubEnd) self.onScrubEnd();
      } @finally {
        _icScrubbing = NO;
      }
    }
  }
  if (!scrubbing) {
    _userClickPending = YES;
    _inMouseDown = YES;
    if ([self.window makeFirstResponder:self]) [self selectText:nil];
    _inMouseDown = NO;
  }
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
  if (!_inMouseDown) [self removeOutsideClickMonitor];
  _userClickPending = NO;
  _icEditing = NO;
  if (!_inMouseDown && !self.icNavigatingAway) [self.window makeFirstResponder:nil];
}
- (void)focusForKeyboardNavigation {
  _userClickPending = YES;
  if ([self.window makeFirstResponder:self]) [self selectText:nil];
}
@end

BOOL ICValueFieldHandleReturnCommand(NSWindow *window, SEL commandSelector) {
  if (commandSelector == @selector(insertNewline:) || commandSelector == @selector(cancelOperation:)) {
    [window makeFirstResponder:nil];
    return YES;
  }
  return NO;
}

static void ICCollectValueFields(NSView *view, NSMutableArray<ICValueTextField *> *fields) {
  for (NSView *subview in view.subviews) {
    if ([subview isKindOfClass:[ICValueTextField class]] && ((ICValueTextField *)subview).isEditable && ((ICValueTextField *)subview).isEnabled && !subview.isHiddenOrHasHiddenAncestor)
      [fields addObject:(ICValueTextField *)subview];
    ICCollectValueFields(subview, fields);
  }
}

BOOL ICValueFieldHandleTabCommand(NSTextField *field, SEL commandSelector) {
  BOOL forward = commandSelector == @selector(insertTab:);
  BOOL backward = commandSelector == @selector(insertBacktab:);
  if (!forward && !backward) return NO;
  if (![field isKindOfClass:[ICValueTextField class]]) return NO;
  NSView *root = field.window.contentView;
  if (!root) return YES;
  NSMutableArray<ICValueTextField *> *fields = [NSMutableArray array];
  ICCollectValueFields(root, fields);
  if (fields.count < 2) return YES;
  [fields sortUsingComparator:^NSComparisonResult(ICValueTextField *a, ICValueTextField *b) {
    NSRect ra = [a convertRect:a.bounds toView:nil], rb = [b convertRect:b.bounds toView:nil];
    if (fabs(NSMaxY(ra) - NSMaxY(rb)) > 1.0) return NSMaxY(ra) > NSMaxY(rb) ? NSOrderedAscending : NSOrderedDescending;
    return NSMinX(ra) <= NSMinX(rb) ? NSOrderedAscending : NSOrderedDescending;
  }];
  NSInteger index = [fields indexOfObject:(ICValueTextField *)field];
  if (index == NSNotFound) return YES;
  NSInteger count = (NSInteger)fields.count;
  NSInteger next = forward ? (index + 1) % count : (index - 1 + count) % count;
  ICValueTextField *current = (ICValueTextField *)field;
  current.icNavigatingAway = YES;
  [fields[next] focusForKeyboardNavigation];
  current.icNavigatingAway = NO;
  return YES;
}
