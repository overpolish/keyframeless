/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKValueTextField.h"

#import "KKFieldEditorSupport.h"
#import "KKTokens.h"
#import "NSColor+KKColors.h"

#import <CoreGraphics/CoreGraphics.h>

// Travel (points) before a press becomes a scrub rather than a click, and
// travel per value step. Coarse/fine modifiers multiply the step.
static const CGFloat kKKScrubStartThreshold = 3.0;
static const CGFloat kKKScrubPointsPerStep = 4.0;
static const double kKKScrubCoarseMultiplier = 10.0; // Shift
static const double kKKScrubFineMultiplier = 0.1;    // Option

// A fully transparent cursor. [NSCursor hide] is process-global and doesn't
// reach the cursor over an FxPlug ViewBridge popover (a separate process owns
// it); -set on a blank cursor does route through the normal cursor mechanism,
// so we re-set it each drag tick to keep the pointer invisible while scrubbing.
static NSCursor *KKBlankCursor(void) {
  static NSCursor *blank;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSImage *img = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    blank = [[NSCursor alloc] initWithImage:img hotSpot:NSZeroPoint];
  });
  return blank;
}

@interface KKValueTextField ()
// Set by the Tab helper while it moves focus to a sibling field, so this
// field's textDidEndEditing doesn't yank focus back to the window (its default
// "genuine end" behavior) and cancel the navigation.
@property(nonatomic) BOOL kkNavigatingAway;
@end

@implementation KKValueTextField {
  BOOL _userClickPending;
  BOOL _kkEditing;
  BOOL _inMouseDown;
  id _outsideClickMon;
}

+ (instancetype)valueField {
  KKValueTextField *f = [[self alloc] init];
  f.translatesAutoresizingMaskIntoConstraints = NO;
  f.font = [NSFont monospacedDigitSystemFontOfSize:KKFontSizeSM
                                            weight:NSFontWeightRegular];
  f.alignment = NSTextAlignmentRight;
  f.textColor = [NSColor inspectorLabel];
  f.backgroundColor = [NSColor clearColor];
  f.bordered = NO;
  f.bezeled = NO;
  f.drawsBackground = NO;
  f.focusRingType = NSFocusRingTypeNone;
  f.editable = YES;
  f.selectable = YES;
  // Single line: the field editor scrolls horizontally instead of wrapping a
  // long value onto a second line when focused.
  f.usesSingleLineMode = YES;
  f.lineBreakMode = NSLineBreakByClipping;
  f.cell.wraps = NO;
  f.cell.scrollable = YES;
  // Fire the action on Return *and* on focus loss, so a typed value commits
  // without a drag (the host applies it immediately).
  [f.cell setSendsActionOnEndEditing:YES];
  return f;
}

- (BOOL)kkEditing {
  return _kkEditing;
}
- (BOOL)acceptsFirstResponder {
  return _userClickPending;
}
// Act on the first click even when our window isn't key yet (e.g. a freshly
// shown popover): without this the first click only activates the window and
// editing won't start until a second click. Matches the popover row views.
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}
- (void)mouseDown:(NSEvent *)event {
  // Already editing, opted out, or not editable: plain click-to-edit behaviour.
  if (self.currentEditor || self.scrubDisabled || !self.isEditable) {
    [self _beginClickEditing:event];
    return;
  }
  [self _trackScrubFromMouseDown:event];
}

// Click-to-edit: takes focus (acceptsFirstResponder is gated on this), and the
// _inMouseDown guard keeps the spurious textDidEndEditing that fires the
// instant we become first responder from resigning the just-started edit.
- (void)_beginClickEditing:(NSEvent *)event {
  _userClickPending = YES;
  _inMouseDown = YES;
  [super mouseDown:event];
  _inMouseDown = NO;
}

// Run our own tracking loop so we can tell a click from a drag. Past the start
// threshold we scrub: hide+freeze the cursor, step the value by mouse delta
// (Shift = coarse, Option = fine), and fire `action` on each change so the
// owner's commit path runs. A press that never crosses the threshold falls
// through to text editing on mouse-up.
- (void)_trackScrubFromMouseDown:(NSEvent *)event {
  double step = self.scrubStep > 0 ? self.scrubStep : 1.0;
  // Value accumulates incrementally so a modifier only scales the travel made
  // *while it's held* - pressing Shift mid-drag mustn't retroactively multiply
  // the distance dragged before it. `residual` is travel not yet converted to
  // a whole step; once it crosses a step boundary it's applied at the
  // multiplier active right now, then carried forward.
  double value = self.doubleValue;
  CGFloat residual = 0;    // travel pending conversion to steps
  CGFloat startTravel = 0; // travel before the scrub threshold is crossed
  BOOL scrubbing = NO;
  // Anchor the freeze at the mouse-down point. Disassociating stops the cursor
  // from following the hardware, and warping back to the anchor each tick pins
  // it there - while association is off the warp does NOT corrupt event.deltaX
  // (which keeps reporting real hardware movement), so the value still tracks
  // the drag and there's no phantom delta carried into the next drag.
  NSPoint anchor = NSEvent.mouseLocation; // screen coords, y-up
  CGFloat primaryH =
      NSScreen.screens.count ? NSHeight(NSScreen.screens.firstObject.frame) : 0;
  CGPoint anchorCG = CGPointMake(anchor.x, primaryH - anchor.y);
  NSEventMask mask = NSEventMaskLeftMouseDragged | NSEventMaskLeftMouseUp;
  while (YES) {
    NSEvent *e = [self.window nextEventMatchingMask:mask];
    if (!e || e.type == NSEventTypeLeftMouseUp)
      break;
    // Hardware deltas. Right and up both increase; AppKit's deltaY is positive
    // moving down, so subtract it.
    CGFloat d = e.deltaX - e.deltaY;
    if (!scrubbing) {
      startTravel += d;
      if (fabs(startTravel) < kKKScrubStartThreshold)
        continue;
      scrubbing = YES;
      CGAssociateMouseAndMouseCursorPosition(false);
      if (self.onScrubBegin)
        self.onScrubBegin();
    }
    [KKBlankCursor() set]; // keep the pointer invisible for the whole drag
    double mult = 1.0;
    NSEventModifierFlags m = e.modifierFlags;
    if (m & NSEventModifierFlagShift)
      mult *= kKKScrubCoarseMultiplier;
    if (m & NSEventModifierFlagOption)
      mult *= kKKScrubFineMultiplier;
    residual += d;
    NSInteger steps = (NSInteger)(residual / kKKScrubPointsPerStep);
    if (steps != 0) {
      residual -= (CGFloat)steps * kKKScrubPointsPerStep;
      value += (double)steps * step * mult;
      self.stringValue = [NSString stringWithFormat:@"%.10g", value];
      [self sendAction:self.action to:self.target];
    }
    if (primaryH > 0)
      CGWarpMouseCursorPosition(anchorCG); // pin the (disassociated) cursor
  }
  if (scrubbing) {
    if (primaryH > 0)
      CGWarpMouseCursorPosition(anchorCG);
    CGAssociateMouseAndMouseCursorPosition(true);
    [[NSCursor arrowCursor] set];
    if (self.onScrubEnd)
      self.onScrubEnd();
  } else {
    // No drag: a plain click. Begin editing with the value selected for
    // overtype (matches keyboard-nav focus).
    _userClickPending = YES;
    _inMouseDown = YES;
    if ([self.window makeFirstResponder:self])
      [self selectText:nil];
    _inMouseDown = NO;
  }
}
- (BOOL)performKeyEquivalent:(NSEvent *)event {
  NSText *editor = self.currentEditor;
  // Escape ends the edit and drops focus (like a native field). In a ViewBridge
  // popover the host stays key, so Escape arrives here as a key equivalent, not
  // a cancelOperation: - handle it explicitly.
  if (editor && event.keyCode == 53) {
    [self.window makeFirstResponder:nil];
    return YES;
  }
  // Cmd-A/C/V/X (no Edit menu in a ViewBridge popover to route them).
  if (KKHandleEditMenuKeyEquivalent(editor, event))
    return YES;
  if (editor) {
    [editor keyDown:event];
    return YES;
  }
  return [super performKeyEquivalent:event];
}
- (BOOL)becomeFirstResponder {
  BOOL ok = [super becomeFirstResponder];
  if (ok) {
    _kkEditing = YES;
    // Install the click-away monitor HERE, not in textDidBeginEditing: these
    // fields scrub, so mouseDown runs its own event loop and consumes the
    // mouse-up. The field editor then gets installed via makeFirstResponder:
    // WITHOUT the interactive begin that posts the begin-editing notification,
    // so textDidBeginEditing: never fires. becomeFirstResponder always does.
    [self _installOutsideClickMonitor];
    [self _styleFieldEditor];
    // The field editor may not be installed yet on this runloop tick;
    // re-apply next tick so the accent caret/selection actually takes.
    __weak typeof(self) weak = self;
    dispatch_async(dispatch_get_main_queue(), ^{
      [weak _styleFieldEditor];
    });
  }
  return ok;
}
- (void)_styleFieldEditor {
  KKStyleFieldEditorAccent(self.currentEditor);
}

// While editing, a click outside this field ends the edit (drops focus). The
// ViewBridge popover doesn't resign fields on a click that lands on a
// non-responder (another slider, the mini-viewer, empty space), so a monitor
// bridges that gap. Runs only between textDidBeginEditing/textDidEndEditing.
- (void)_installOutsideClickMonitor {
  if (_outsideClickMon)
    return;
  __weak typeof(self) weak = self;
  _outsideClickMon = [NSEvent
      addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown |
                                           NSEventMaskRightMouseDown
                                   handler:^NSEvent *(NSEvent *e) {
                                     __strong typeof(weak) s = weak;
                                     if (!s)
                                       return e;
                                     // Monitor is alive only while focused, so
                                     // no currentEditor guard (it can read nil
                                     // mid-routing and wrongly skip the
                                     // resign).
                                     NSRect r = [s convertRect:s.bounds
                                                        toView:nil];
                                     BOOL inField =
                                         e.window == s.window &&
                                         NSPointInRect(e.locationInWindow, r);
                                     if (!inField)
                                       [s.window makeFirstResponder:nil];
                                     return e;
                                   }];
}
- (void)_removeOutsideClickMonitor {
  if (_outsideClickMon) {
    [NSEvent removeMonitor:_outsideClickMon];
    _outsideClickMon = nil;
  }
}
- (void)dealloc {
  [self _removeOutsideClickMonitor];
}

- (void)textDidBeginEditing:(NSNotification *)notification {
  [super textDidBeginEditing:notification];
  // Editing can re-start without a fresh becomeFirstResponder (the field stays
  // first responder and AppKit just re-enters editing). Set the guard here, at
  // the true session boundary, so a redisplay reliably skips us while live.
  _kkEditing = YES;
  // The click-away monitor is installed in becomeFirstResponder (this
  // notification doesn't fire for scrub fields). Belt-and-suspenders for a
  // field editor that begins interactively (first keystroke) without us.
  [self _installOutsideClickMonitor];
}
- (void)textDidEndEditing:(NSNotification *)notification {
  // Keep _kkEditing YES across super: super fires the sendsActionOnEndEditing
  // action, whose redisplay must skip this field (a stringValue write here
  // re-grabs focus + reselects). Only after super do we clear it and resign.
  [super textDidEndEditing:notification];
  // Only tear the monitor down on a GENUINE end. A spurious end fires inside
  // our own mouseDown (the instant we become first responder); removing then
  // would kill the monitor we just installed in becomeFirstResponder.
  if (!_inMouseDown)
    [self _removeOutsideClickMonitor];
  _userClickPending = NO;
  _kkEditing = NO;
  // Return focus to the window (so keyboard shortcuts work again) only on a
  // genuine end. A spurious end fires *inside* our own -mouseDown:, the instant
  // the field becomes first responder; resigning then kills the just-started
  // edit. Genuine ends (Enter / blur) happen outside the click.
  if (!_inMouseDown && !_kkNavigatingAway)
    [self.window makeFirstResponder:nil];
}

// Take focus in response to Tab/Shift-Tab from a sibling field. The click gate
// (acceptsFirstResponder) is opened just for this transfer, then editing starts
// with all text selected so the value is ready to overtype.
- (void)kkFocusForKeyboardNavigation {
  _userClickPending = YES;
  if ([self.window makeFirstResponder:self])
    [self selectText:nil];
}
@end

BOOL KKValueFieldHandleReturnCommand(NSWindow *window, SEL commandSelector) {
  // Return commits, Escape cancels - both fully defocus. In this popover keys
  // reach the field editor as doCommandBySelector (not performKeyEquivalent),
  // so Escape lands here as cancelOperation: rather than the key-equivalent
  // path in -performKeyEquivalent:.
  if (commandSelector == @selector(insertNewline:) ||
      commandSelector == @selector(cancelOperation:)) {
    [window makeFirstResponder:nil];
    return YES;
  }
  return NO;
}

static void KKCollectValueFields(NSView *view,
                                 NSMutableArray<KKValueTextField *> *out) {
  for (NSView *sub in view.subviews) {
    if ([sub isKindOfClass:[KKValueTextField class]] &&
        ((KKValueTextField *)sub).isEditable &&
        !sub.isHiddenOrHasHiddenAncestor)
      [out addObject:(KKValueTextField *)sub];
    KKCollectValueFields(sub, out);
  }
}

BOOL KKValueFieldHandleTabCommand(NSTextField *field, SEL commandSelector) {
  BOOL fwd = (commandSelector == @selector(insertTab:));
  BOOL back = (commandSelector == @selector(insertBacktab:));
  if (!fwd && !back)
    return NO;
  if (![field isKindOfClass:[KKValueTextField class]])
    return NO;
  NSView *root = field.window.contentView;
  if (!root)
    return YES;
  // Every value field in the popover, ordered as read: top-to-bottom then
  // left-to-right (window space, y-up so a larger maxY is higher).
  NSMutableArray<KKValueTextField *> *fields = [NSMutableArray array];
  KKCollectValueFields(root, fields);
  if (fields.count < 2)
    return YES; // swallow Tab; nothing to move to
  [fields sortUsingComparator:^NSComparisonResult(KKValueTextField *a,
                                                  KKValueTextField *b) {
    NSRect ra = [a convertRect:a.bounds toView:nil];
    NSRect rb = [b convertRect:b.bounds toView:nil];
    if (fabs(NSMaxY(ra) - NSMaxY(rb)) > 1.0)
      return (NSMaxY(ra) > NSMaxY(rb)) ? NSOrderedAscending
                                       : NSOrderedDescending;
    return (NSMinX(ra) <= NSMinX(rb)) ? NSOrderedAscending
                                      : NSOrderedDescending;
  }];
  NSInteger idx = [fields indexOfObject:(KKValueTextField *)field];
  if (idx == NSNotFound)
    return YES;
  NSInteger n = (NSInteger)fields.count;
  NSInteger nextIdx = fwd ? (idx + 1) % n : (idx - 1 + n) % n;
  KKValueTextField *cur = (KKValueTextField *)field;
  cur.kkNavigatingAway = YES;
  [fields[nextIdx] kkFocusForKeyboardNavigation];
  cur.kkNavigatingAway = NO;
  return YES;
}
