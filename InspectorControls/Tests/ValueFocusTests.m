/* SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 */
#import "InspectorControls.h"
#import <assert.h>
@interface ICValueTextField (FocusTests)
- (NSRect)visibleValueRect;
- (void)trackScrubFromMouseDown:(NSEvent *)event;
- (void)blurForOutsideClick:(NSEvent *)event;
@end
@interface FocusField : ICValueTextField
@property NSUInteger scrubStarts;
@property(nonatomic, strong) NSMutableArray<NSDictionary *> *cursorRects;
- (void)startEditingWithClick:(NSEvent *)event;
@end
@implementation FocusField
- (void)addCursorRect:(NSRect)rect cursor:(NSCursor *)cursor {
  if (!self.cursorRects)
    self.cursorRects = [NSMutableArray new];
  [self.cursorRects
      addObject:@{@"rect" : [NSValue valueWithRect:rect], @"cursor" : cursor}];
  [super addCursorRect:rect cursor:cursor];
}
- (void)startEditingWithClick:(NSEvent *)event {
  NSEvent *up = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp
                                   location:event.locationInWindow
                              modifierFlags:0
                                  timestamp:0
                               windowNumber:event.windowNumber
                                    context:nil
                                eventNumber:2
                                 clickCount:1
                                   pressure:0];
  [NSApp postEvent:up atStart:YES];
  [super trackScrubFromMouseDown:event];
}
- (void)trackScrubFromMouseDown:(NSEvent *)event {
  (void)event;
  self.scrubStarts++;
}
@end
@interface MenuTrackingProbe : NSObject <NSMenuDelegate>
@property BOOL opened;
@end
@implementation MenuTrackingProbe
- (void)menuWillOpen:(NSMenu *)menu {
  (void)menu;
  self.opened = YES;
}
@end
static NSEvent *click(NSWindow *window, NSPoint point) {
  return [NSEvent mouseEventWithType:NSEventTypeLeftMouseDown
                            location:point
                       modifierFlags:0
                           timestamp:0
                        windowNumber:window.windowNumber
                             context:nil
                         eventNumber:1
                          clickCount:1
                            pressure:1];
}
static NSPoint centreInWindow(NSView *view, NSRect rect) {
  return [view convertPoint:NSMakePoint(NSMidX(rect), NSMidY(rect)) toView:nil];
}
int main(void) {
  @autoreleasepool {
    [NSApplication sharedApplication];
    NSWindow *window =
        [[NSWindow alloc] initWithContentRect:NSMakeRect(100, 100, 360, 100)
                                    styleMask:NSWindowStyleMaskTitled
                                      backing:NSBackingStoreBuffered
                                        defer:NO];
    window.releasedWhenClosed = NO;
    FocusField *field = (FocusField *)[FocusField valueField];
    field.frame = NSMakeRect(20, 40, 220, 22);
    field.stringValue = @"162.0";
    [window.contentView addSubview:field];
    [window makeKeyAndOrderFront:nil];
    NSRect readout = [field visibleValueRect];
    assert(NSWidth(readout) < NSWidth(field.bounds) / 2);
    [field.cursorRects removeAllObjects];
    [field resetCursorRects];
    NSUInteger textRegions = 0;
    for (NSDictionary *region in field.cursorRects) {
      NSRect rect = [region[@"rect"] rectValue];
      if (region[@"cursor"] == NSCursor.IBeamCursor) {
        textRegions++;
        assert(NSEqualRects(rect, readout));
      } else {
        assert(region[@"cursor"] == NSCursor.arrowCursor);
        assert(NSIsEmptyRect(NSIntersectionRect(rect, readout)));
      }
    }
    assert(textRegions == 1);
    NSMenu *menu = [ICContextMenu new];
    field.contextMenuProvider = ^{
      return menu;
    };
    NSPoint blankPoint = [field convertPoint:NSMakePoint(10, 11) toView:nil];
    NSEvent *rightBlank = [NSEvent mouseEventWithType:NSEventTypeRightMouseDown
                                             location:blankPoint
                                        modifierFlags:0
                                            timestamp:0
                                         windowNumber:window.windowNumber
                                              context:nil
                                          eventNumber:3
                                           clickCount:1
                                             pressure:1];
    assert([field menuForEvent:rightBlank] == menu);
    NSEvent *blank = click(window, [field convertPoint:NSMakePoint(10, 11)
                                                toView:nil]);
    [field mouseDown:blank];
    assert(!field.icEditing && !field.scrubStarts);
    [field mouseDown:click(window, centreInWindow(field, readout))];
    assert(field.scrubStarts == 1);
    [field startEditingWithClick:click(window,
                                       centreInWindow(
                                           field, [field visibleValueRect]))];
    assert(field.currentEditor);
    NSTextView *editor = (NSTextView *)field.currentEditor;
    assert(!field.automaticTextCompletionEnabled && !field.contentType);
    assert(!editor.automaticTextCompletionEnabled && !editor.contentType);
    assert(!editor.automaticSpellingCorrectionEnabled &&
           !editor.automaticTextReplacementEnabled);
    assert(!editor.automaticDashSubstitutionEnabled &&
           !editor.automaticQuoteSubstitutionEnabled);
    assert(editor.rangeForUserCompletion.location == NSNotFound);
    if (@available(macOS 14.0, *))
      assert(editor.inlinePredictionType == NSTextInputTraitTypeNo);
    if (@available(macOS 15.0, *)) {
      assert(editor.mathExpressionCompletionType == NSTextInputTraitTypeNo);
      assert(editor.writingToolsBehavior == NSWritingToolsBehaviorNone);
    }
    [editor insertText:@"-1234.56"
        replacementRange:NSMakeRange(0, editor.string.length)];
    assert(field.icEditing);
    NSRect editingRect = [field visibleValueRect];
    assert(NSWidth(editingRect) > 0 &&
           NSWidth(editingRect) < NSWidth(field.bounds) / 2);
    [field
        blurForOutsideClick:click(window, centreInWindow(field, editingRect))];
    assert(field.currentEditor == editor);
    NSEvent *blankUp = [NSEvent mouseEventWithType:NSEventTypeLeftMouseUp
                                          location:blank.locationInWindow
                                     modifierFlags:0
                                         timestamp:0
                                      windowNumber:window.windowNumber
                                           context:nil
                                       eventNumber:4
                                        clickCount:1
                                          pressure:0];
    [NSApp postEvent:blankUp atStart:YES];
    [editor mouseDown:blank];
    [NSApp nextEventMatchingMask:NSEventMaskLeftMouseUp
                       untilDate:NSDate.distantPast
                          inMode:NSDefaultRunLoopMode
                         dequeue:YES];
    assert(!field.currentEditor && !field.icEditing);
    [field mouseDown:blank];
    assert(!field.currentEditor && field.scrubStarts == 1);
    assert([field.stringValue isEqual:@"-1234.56"]);
    [field startEditingWithClick:click(window,
                                       centreInWindow(
                                           field, [field visibleValueRect]))];
    assert(field.currentEditor);
    [menu addItemWithTitle:@"Reset Parameter" action:nil keyEquivalent:@""];
    MenuTrackingProbe *probe = [MenuTrackingProbe new];
    menu.delegate = probe;
    NSTimer *cancel = [NSTimer timerWithTimeInterval:.05
                                             repeats:NO
                                               block:^(NSTimer *timer) {
                                                 (void)timer;
                                                 [menu cancelTracking];
                                               }];
    [NSRunLoop.mainRunLoop addTimer:cancel forMode:NSEventTrackingRunLoopMode];
    [field.currentEditor rightMouseDown:rightBlank];
    [cancel invalidate];

    assert(probe.opened);
    assert(!field.currentEditor);
    [field startEditingWithClick:click(window,
                                       centreInWindow(
                                           field, [field visibleValueRect]))];
    assert(field.currentEditor);
    [field blurForOutsideClick:click(window, NSMakePoint(340, 80))];
    assert(!field.currentEditor);
    [window close];
    puts("ValueFocusTests: blank space commits and blurs, visible text retains "
         "focus and scrubbing passed");
  }
  return 0;
}
