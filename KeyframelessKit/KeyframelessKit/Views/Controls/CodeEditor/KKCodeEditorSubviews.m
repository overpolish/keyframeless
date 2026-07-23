/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKCodeEditorSubviews.h"
#import "KKFieldEditorSupport.h"
#import "KKGLSLSyntax.h"
#import "NSColor+KKColors.h"
#import <QuartzCore/QuartzCore.h>

static const CGFloat kKKComplRowH = 22.0;
static const NSInteger kKKComplMaxRows = 8;
static const CGFloat kKKComplWidth = 400.0;
static const CGFloat kKKComplPad = 8.0; // horizontal text inset

// The code editor lives in a nonactivating FxPlug ViewBridge popover where the
// host window stays key, so key events arrive as key EQUIVALENTS, not keyDown -
// exactly why a plain NSTextView's arrows / return / escape leak to the host.
// Mirror KKValueTextField: while we're the first responder, dispatch the
// equivalent to ourselves as a keyDown so it edits the code. Also handle the
// Cmd-A/C/V/X/Z cluster explicitly (a ViewBridge popover has no Edit menu, so
// those equivalents never reach us otherwise).
@implementation _KKCodeTextView {
  id _outsideClickMon;
  BOOL _inMouseDown;
}

// Focus from a real click only, never the window's key-view loop on open (so a
// freshly-shown popover doesn't auto-focus the editor). The window checks
// acceptsFirstResponder BEFORE delivering mouseDown, so a flag set in mouseDown
// is one click too late (the 2-click bug). Gate on the CURRENT EVENT being a
// mouse-down instead - true while the window routes a click, false for the
// key-loop auto-focus.
- (BOOL)acceptsFirstResponder {
  NSEvent *cur = NSApp.currentEvent;
  BOOL fromClick = cur && (cur.type == NSEventTypeLeftMouseDown ||
                           cur.type == NSEventTypeRightMouseDown);
  // The popover OPENS on a mouse-down too, so "is the current event a click"
  // isn't enough - the open-time key-view-loop auto-focus sees that opening
  // click and would grab focus (the auto-focus regression). Require the click
  // to be in OUR window and land on the editor's visible area: the opening
  // click is in the host window (or off the editor), so it's rejected.
  if (!fromClick || cur.window != self.window)
    return NO;
  NSView *area = self.enclosingScrollView ?: (NSView *)self;
  NSPoint p = [area convertPoint:cur.locationInWindow fromView:nil];
  return NSPointInRect(p, area.bounds);
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES; // act on the first click even when the panel isn't key yet
}
- (void)mouseDown:(NSEvent *)event {
  // Guard the spurious resignFirstResponder that can fire while the panel takes
  // key on the click.
  _inMouseDown = YES;
  [super mouseDown:event];
  _inMouseDown = NO;
}

// While focused, a click anywhere outside the editor drops focus (like a value
// field losing its edit). Clicks in the host window close the popover via its
// own outside-click monitor, which resigns us too. Installed only while first
// responder so it isn't running otherwise.
- (BOOL)becomeFirstResponder {
  BOOL ok = [super becomeFirstResponder];
  if (ok && !_outsideClickMon) {
    __weak typeof(self) weak = self;
    _outsideClickMon = [NSEvent
        addLocalMonitorForEventsMatchingMask:NSEventMaskLeftMouseDown |
                                             NSEventMaskRightMouseDown
                                     handler:^NSEvent *(NSEvent *e) {
                                       __strong typeof(weak) s = weak;
                                       if (!s)
                                         return e;
                                       // Different window (or none) = outside.
                                       if (e.window != s.window) {
                                         [s.window makeFirstResponder:nil];
                                         return e;
                                       }
                                       // Compare against the VISIBLE editor
                                       // (the scroll view's frame in window
                                       // coords), not the text view's bounds -
                                       // that's the scrollable document view
                                       // and moves/grows with content.
                                       NSView *area =
                                           s.enclosingScrollView ?: (NSView *)s;
                                       NSRect r = [area convertRect:area.bounds
                                                             toView:nil];
                                       if (!NSPointInRect(e.locationInWindow,
                                                          r)) {
                                         // A click on the autocomplete overlay
                                         // is benign - let it pick, don't blur.
                                         if (s.benignOutsideClick &&
                                             s.benignOutsideClick(e))
                                           return e;
                                         [s.window makeFirstResponder:nil];
                                       }
                                       return e;
                                     }];
  }
  return ok;
}

- (BOOL)resignFirstResponder {
  // Ignore the spurious resign fired inside our own click; a genuine resign
  // (Esc / click-away) tears down the outside-click monitor.
  if (!_inMouseDown && _outsideClickMon) {
    [NSEvent removeMonitor:_outsideClickMon];
    _outsideClickMon = nil;
  }
  return [super resignFirstResponder];
}

- (void)dealloc {
  if (_outsideClickMon)
    [NSEvent removeMonitor:_outsideClickMon];
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
  if (self.window.firstResponder != self)
    return [super performKeyEquivalent:event];
  if (event.keyCode == 53) { // Escape
    if (_escapeHandler && _escapeHandler())
      return YES; // consumed (e.g. dismissed autocomplete)
    [self.window makeFirstResponder:nil]; // else drop focus, like a value field
    return YES;
  }
  NSEventModifierFlags mods =
      event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
  if (mods == NSEventModifierFlagCommand) {
    NSString *key = event.charactersIgnoringModifiers.lowercaseString;
    if ([key isEqualToString:@"a"]) {
      [self selectAll:nil];
      return YES;
    }
    if ([key isEqualToString:@"c"]) {
      [self copy:nil];
      return YES;
    }
    if ([key isEqualToString:@"v"]) {
      [self paste:nil];
      return YES;
    }
    if ([key isEqualToString:@"x"]) {
      [self cut:nil];
      return YES;
    }
    if ([key isEqualToString:@"z"]) {
      // Only consume Cmd-Z while there's local (uncommitted) typing to undo;
      // once the burst is committed its local history is cleared (see the
      // debounce commit) so this falls through to the host's (FCP) undo of the
      // last timeline change - the two stacks no longer fight for Cmd-Z.
      if (self.undoManager.canUndo) {
        [self.undoManager undo];
        return YES;
      }
      return [super performKeyEquivalent:event];
    }
  } else if (mods == (NSEventModifierFlagCommand | NSEventModifierFlagShift) &&
             [event.charactersIgnoringModifiers.lowercaseString
                 isEqualToString:@"z"]) {
    if (self.undoManager.canRedo) {
      [self.undoManager redo];
      return YES;
    }
    return [super performKeyEquivalent:event];
  }
  [self keyDown:event];
  return YES;
}
@end

@implementation _KKErrEdgeShadow
- (NSView *)hitTest:(NSPoint)point {
  return nil;
}
@end

// The save-bar name field: same first-responder gating as _KKCodeTextView so a
// freshly-shown popover doesn't auto-focus it (the key-view loop asks
// acceptsFirstResponder on open; only a real click in our bounds should grab
// it).
@implementation _KKNameField
- (BOOL)acceptsFirstResponder {
  NSEvent *cur = NSApp.currentEvent;
  BOOL fromClick = cur && (cur.type == NSEventTypeLeftMouseDown ||
                           cur.type == NSEventTypeRightMouseDown);
  if (!fromClick || cur.window != self.window)
    return NO;
  NSPoint p = [self convertPoint:cur.locationInWindow fromView:nil];
  return NSPointInRect(p, self.bounds);
}
- (BOOL)acceptsFirstMouse:(NSEvent *)event {
  return YES;
}
// ViewBridge popover: key events arrive as key equivalents, not keyDown, so a
// plain field never sees typing. Forward them to the field editor (matches
// KKValueTextField / the code text view).
- (BOOL)performKeyEquivalent:(NSEvent *)event {
  NSText *editor = self.currentEditor;
  if (!editor)
    return [super performKeyEquivalent:event];
  if (KKHandleEditMenuKeyEquivalent(editor, event))
    return YES;
  [editor keyDown:event];
  return YES;
}
// Accent caret + selection from the FIRST tick (styling in the delegate's
// controlTextDidBeginEditing doesn't repaint until the first keystroke). Apply
// on focus AND next tick once the field editor is wired.
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

// Inline autocomplete list for the expression editor: a display-only overlay
// (hit-transparent, keyboard-driven) that lists matching catalog entries below
// the caret. Each row is a signature + dimmed description; the selected row is
// accent- filled. All state pushed in by the editor.
@implementation _KKExprCompletionView {
  NSTrackingArea *_track;
  // First visible row when the list overflows kKKComplMaxRows. Follows the
  // keyboard selection and the scroll wheel; rows are drawn from this offset.
  NSInteger _firstRow;
  CGFloat _wheelAcc; // sub-row wheel deltas accumulated into row steps
}

- (instancetype)initWithFrame:(NSRect)frame {
  if ((self = [super initWithFrame:frame])) {
    // Rounded, bordered panel matching the code editor's own chrome
    // (GitHub-Dark: radius 8, KKCodeBorder, an elevated panel tint over the
    // editor).
    self.wantsLayer = YES;
    self.layer.cornerRadius = 8.0;
    self.layer.masksToBounds = YES;
    self.layer.borderWidth = 1.0;
    self.layer.borderColor = KKCodeBorder().CGColor;
    self.layer.backgroundColor = KKHex(0x161b22).CGColor;
  }
  return self;
}

- (BOOL)isFlipped {
  return YES; // rows drawn + hit-tested top-down
}

- (void)setItems:(NSArray<NSDictionary<NSString *, NSString *> *> *)items {
  _items = [items copy];
  _firstRow = 0;
  _wheelAcc = 0.0;
  self.needsDisplay = YES;
}

- (NSInteger)_maxFirstRow {
  return MAX(0, (NSInteger)self.items.count - kKKComplMaxRows);
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
  _selectedIndex = selectedIndex;
  // Keep the selection inside the visible window (arrow keys walk the FULL
  // list, the drawn rows are only a slice of it).
  if (selectedIndex >= 0) {
    if (selectedIndex < _firstRow)
      _firstRow = selectedIndex;
    else if (selectedIndex >= _firstRow + kKKComplMaxRows)
      _firstRow = selectedIndex - kKKComplMaxRows + 1;
    _firstRow = MAX(0, MIN(_firstRow, [self _maxFirstRow]));
  }
  self.needsDisplay = YES;
}

- (void)scrollWheel:(NSEvent *)event {
  if ([self _maxFirstRow] == 0)
    return;
  _wheelAcc += event.scrollingDeltaY;
  NSInteger steps = (NSInteger)(_wheelAcc / kKKComplRowH);
  if (steps == 0)
    return;
  _wheelAcc -= steps * kKKComplRowH;
  // Natural scrolling: positive deltaY pulls earlier rows into view.
  _firstRow = MAX(0, MIN(_firstRow - steps, [self _maxFirstRow]));
  self.needsDisplay = YES;
}

- (CGFloat)_descHeight:(NSString *)desc {
  if (desc.length == 0)
    return 0.0;
  NSRect r = [desc
      boundingRectWithSize:NSMakeSize(kKKComplWidth - 2 * kKKComplPad, 1000)
                   options:NSStringDrawingUsesLineFragmentOrigin
                attributes:@{
                  NSFontAttributeName : [NSFont systemFontOfSize:9.5]
                }];
  return ceil(r.size.height);
}

// Footer sized to the TALLEST description in the current list (ALL items, the
// selection can scroll to any of them), so switching the selection swaps the
// shown text without resizing the popup (no jump).
- (CGFloat)_footerHeight {
  CGFloat maxH = 0.0;
  for (NSDictionary<NSString *, NSString *> *e in self.items)
    maxH = MAX(maxH, [self _descHeight:e[@"desc"]]);
  return maxH > 0.0 ? (1.0 + 6.0 + maxH + 6.0)
                    : 0.0; // divider + pad + text + pad
}

- (CGFloat)fittingHeight {
  NSInteger n = MIN((NSInteger)self.items.count, kKKComplMaxRows);
  return 1.0 + n * kKKComplRowH + [self _footerHeight] + 1.0;
}

+ (CGFloat)preferredWidth {
  return kKKComplWidth;
}

- (NSInteger)_rowAtPoint:(NSPoint)p {
  NSInteger slot = (NSInteger)floor((p.y - 1.0) / kKKComplRowH);
  NSInteger n = MIN((NSInteger)self.items.count, kKKComplMaxRows);
  if (slot < 0 || slot >= n)
    return -1;
  NSInteger i = _firstRow + slot;
  return i < (NSInteger)self.items.count ? i : -1;
}

- (void)updateTrackingAreas {
  [super updateTrackingAreas];
  if (_track)
    [self removeTrackingArea:_track];
  _track = [[NSTrackingArea alloc]
      initWithRect:self.bounds
           options:NSTrackingMouseMoved | NSTrackingActiveAlways
             owner:self
          userInfo:nil];
  [self addTrackingArea:_track];
}

- (void)mouseMoved:(NSEvent *)event {
  NSInteger i = [self _rowAtPoint:[self convertPoint:event.locationInWindow
                                            fromView:nil]];
  if (i >= 0 && i != _selectedIndex) {
    _selectedIndex = i;
    self.needsDisplay = YES;
  }
}

- (void)mouseDown:(NSEvent *)event {
  NSInteger i = [self _rowAtPoint:[self convertPoint:event.locationInWindow
                                            fromView:nil]];
  if (i >= 0 && self.onPick)
    self.onPick(i);
}

- (void)drawRect:(NSRect)dirty {
  NSFont *sigFont = [NSFont monospacedSystemFontOfSize:10.0
                                                weight:NSFontWeightMedium];
  NSMutableParagraphStyle *rowPara = [NSMutableParagraphStyle new];
  rowPara.lineBreakMode = NSLineBreakByTruncatingTail;
  NSColor *argColor = KKCodeComment(); // grey, like a comment/secondary
  NSInteger n = MIN((NSInteger)self.items.count, kKKComplMaxRows);

  for (NSInteger slot = 0; slot < n; slot++) {
    NSInteger i = _firstRow + slot;
    if (i >= (NSInteger)self.items.count)
      break;
    NSRect row = NSMakeRect(1.0, 1.0 + slot * kKKComplRowH,
                            self.bounds.size.width - 2.0, kKKComplRowH);
    NSDictionary<NSString *, NSString *> *e = self.items[i];
    if (i == self.selectedIndex) {
      [[NSColor colorWithWhite:1.0 alpha:0.12] setFill]; // soft grey highlight
      NSRectFill(row);
    }
    // The identifier takes its SYNTAX-highlight colour (functions purple,
    // variables coral - same as in the editor); the argument list stays grey.
    NSString *sig = e[@"signature"] ?: @"";
    NSRange paren = [sig rangeOfString:@"("];
    NSString *namePart = paren.location != NSNotFound
                             ? [sig substringToIndex:paren.location]
                             : sig;
    NSString *argPart = paren.location != NSNotFound
                            ? [sig substringFromIndex:paren.location]
                            : @"";
    // A provider-supplied `color` hex (GLSL / directive items) wins so the row
    // reads the same colour it will once inserted; expression items have none
    // and fall back to the expression grammar's own colouring.
    NSColor *nameColor;
    NSString *colorHex = e[@"color"];
    if (colorHex.length == 6) {
      unsigned int rgb = 0;
      [[NSScanner scannerWithString:colorHex] scanHexInt:&rgb];
      nameColor = KKHex(rgb);
    } else {
      nameColor = KKExprWordColor(e[@"name"]) ?: KKCodeText();
    }
    NSMutableAttributedString *a = [[NSMutableAttributedString alloc]
        initWithString:namePart
            attributes:@{
              NSFontAttributeName : sigFont,
              NSForegroundColorAttributeName : nameColor,
              NSParagraphStyleAttributeName : rowPara
            }];
    if (argPart.length)
      [a appendAttributedString:[[NSAttributedString alloc]
                                    initWithString:argPart
                                        attributes:@{
                                          NSFontAttributeName : sigFont,
                                          NSForegroundColorAttributeName :
                                              argColor,
                                          NSParagraphStyleAttributeName :
                                              rowPara
                                        }]];
    CGFloat th = a.size.height;
    NSRect textRect = NSMakeRect(row.origin.x + kKKComplPad,
                                 row.origin.y + (kKKComplRowH - th) / 2.0,
                                 row.size.width - 2 * kKKComplPad, th);
    [a drawInRect:textRect];
  }

  // Scroll-edge shadows over the rows (the standard 16pt background fade) so
  // an overflowing list reads as scrollable in each hidden direction.
  CGFloat shadowH = 16.0;
  NSColor *bg = KKHex(0x161b22);
  if (_firstRow > 0) {
    NSGradient *top = [[NSGradient alloc]
        initWithStartingColor:[bg colorWithAlphaComponent:0.95]
                  endingColor:[bg colorWithAlphaComponent:0.0]];
    [top drawInRect:NSMakeRect(1.0, 1.0, self.bounds.size.width - 2.0, shadowH)
              angle:90.0];
  }
  if (_firstRow + n < (NSInteger)self.items.count) {
    NSGradient *bottom = [[NSGradient alloc]
        initWithStartingColor:[bg colorWithAlphaComponent:0.0]
                  endingColor:[bg colorWithAlphaComponent:0.95]];
    [bottom drawInRect:NSMakeRect(1.0, 1.0 + n * kKKComplRowH - shadowH,
                                  self.bounds.size.width - 2.0, shadowH)
                 angle:90.0];
  }

  // Description of the highlighted row, wrapped, in the fixed-height footer.
  CGFloat footerH = [self _footerHeight];
  if (footerH <= 0.0 || self.selectedIndex < 0 ||
      self.selectedIndex >= (NSInteger)self.items.count)
    return;
  CGFloat rowsBottom = 1.0 + n * kKKComplRowH;
  NSRect divider = NSMakeRect(kKKComplPad, rowsBottom,
                              self.bounds.size.width - 2 * kKKComplPad, 1.0);
  [[KKCodeBorder() colorWithAlphaComponent:0.6] setFill];
  NSRectFill(divider);
  NSMutableParagraphStyle *wrap = [NSMutableParagraphStyle new];
  wrap.lineBreakMode = NSLineBreakByWordWrapping;
  NSString *desc = self.items[self.selectedIndex][@"desc"] ?: @"";
  NSRect descRect =
      NSMakeRect(kKKComplPad, rowsBottom + 7.0,
                 self.bounds.size.width - 2 * kKKComplPad, footerH - 8.0);
  [desc drawWithRect:descRect
             options:NSStringDrawingUsesLineFragmentOrigin
          attributes:@{
            NSFontAttributeName : [NSFont systemFontOfSize:9.5],
            NSForegroundColorAttributeName : KKHex(0xadbac7),
            NSParagraphStyleAttributeName : wrap
          }];
}

@end

// A tiny read-only curve preview: normalises `samples` (the expression
// evaluated across the clip, fraction 0->1) to its own min/max and strokes a
// polyline, with an accent dot at `marker` (the current playhead fraction).
// Flat / empty samples draw a centred baseline. Lives in the result strip
// beside the number; a dumb renderer, all data pushed in by the host.
@implementation _KKSparklineView

- (void)setSamples:(NSArray<NSNumber *> *)samples {
  _samples = [samples copy];
  self.needsDisplay = YES;
}

- (void)setMarker:(double)marker {
  _marker = marker;
  self.needsDisplay = YES;
}

- (BOOL)isFlipped {
  return NO;
}

- (void)drawRect:(NSRect)dirty {
  NSArray<NSNumber *> *s = _samples;
  NSRect b = NSInsetRect(self.bounds, 1.5, 2.5);
  if (b.size.width <= 1.0 || b.size.height <= 1.0)
    return;
  if (s.count < 2) {
    NSBezierPath *base = [NSBezierPath bezierPath];
    [base moveToPoint:NSMakePoint(NSMinX(b), NSMidY(b))];
    [base lineToPoint:NSMakePoint(NSMaxX(b), NSMidY(b))];
    base.lineWidth = 1.0;
    [[KKCodeText() colorWithAlphaComponent:0.28] setStroke];
    [base stroke];
    return;
  }
  double lo = s.firstObject.doubleValue, hi = lo;
  for (NSNumber *n in s) {
    double v = n.doubleValue;
    if (v < lo)
      lo = v;
    if (v > hi)
      hi = v;
  }
  double span = hi - lo;
  BOOL flat = span < 1e-9;
  CGFloat (^yFor)(double) = ^CGFloat(double v) {
    if (flat)
      return NSMidY(b);
    return NSMinY(b) + (CGFloat)((v - lo) / span) * b.size.height;
  };
  CGFloat (^xFor)(NSInteger) = ^CGFloat(NSInteger i) {
    return NSMinX(b) + (CGFloat)i / (CGFloat)(s.count - 1) * b.size.width;
  };
  NSBezierPath *line = [NSBezierPath bezierPath];
  for (NSInteger i = 0; i < (NSInteger)s.count; i++) {
    NSPoint p = NSMakePoint(xFor(i), yFor(s[i].doubleValue));
    if (i == 0)
      [line moveToPoint:p];
    else
      [line lineToPoint:p];
  }
  line.lineWidth = 1.0;
  line.lineJoinStyle = NSLineJoinStyleRound;
  [[[NSColor accentMatchingHost] colorWithAlphaComponent:0.75] setStroke];
  [line stroke];

  if (_marker >= 0.0 && _marker <= 1.0) {
    double m = _marker * (double)(s.count - 1);
    NSInteger i0 = (NSInteger)floor(m);
    NSInteger i1 = MIN(i0 + 1, (NSInteger)s.count - 1);
    double frac = m - (double)i0;
    double v = s[i0].doubleValue * (1.0 - frac) + s[i1].doubleValue * frac;
    NSPoint p =
        NSMakePoint(NSMinX(b) + (CGFloat)_marker * b.size.width, yFor(v));
    NSRect dot = NSMakeRect(p.x - 1.75, p.y - 1.75, 3.5, 3.5);
    [[NSColor accentMatchingHost] setFill];
    [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
  }
}

@end
