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

// AppKit substitutes its own disabled text colour. Draw using our explicit
// token while retaining the disabled state for editing and hit testing.
@interface ICValueTextFieldCell : NSTextFieldCell
@end
@implementation ICValueTextFieldCell
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

+ (Class)cellClass { return ICValueTextFieldCell.class; }

- (void)setEnabled:(BOOL)enabled {
  [super setEnabled:enabled];
  self.textColor=enabled ? ICInspectorTokens.valueColor : ICInspectorTokens.disabledTextColor;
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

- (void)mouseDown:(NSEvent *)event {
  if (!self.isEnabled) return;
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
    if (!field || !field.currentEditor) return event;
    NSRect rect = [field convertRect:field.bounds toView:nil];
    if (!(event.window == field.window && NSPointInRect(event.locationInWindow, rect)))
      [field.window makeFirstResponder:nil];
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
