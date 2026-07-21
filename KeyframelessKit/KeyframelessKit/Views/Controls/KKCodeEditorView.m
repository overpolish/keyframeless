/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKCodeEditorView.h"
#import "KKChoiceChecklistView.h"
#import "KKCodeGutterView.h"
#import "KKFieldEditorSupport.h"
#import "KKGLSLSyntax.h"
#import "KKLinkExpr.h" // expression error range for the red squiggle
#import "KKLocalized.h"
#import "KKPopoverKeepAlive.h"
#import "KKTimelineLanesView_Private.h" // _KKDropdownTrigger, _KKLVPopoverContentView
#import "KKTimingStage.h" // KKCodeEditorSave* notification constant declarations
#import "KKTokens.h"
#import "NSColor+KKColors.h"
#import <QuartzCore/QuartzCore.h>

NSNotificationName const KKCodeEditorSaveRequestedNotification =
    @"KKCodeEditorSaveRequestedNotification";
NSString *const KKCodeEditorSaveNameKey = @"name";
NSString *const KKCodeEditorSaveSectionsKey = @"sections";
NSString *const KKCodeEditorSaveCategoryIndexKey = @"categoryIndex";

// Wide enough for the longest category a host is likely to offer without the
// name field losing its own room.
static const CGFloat kSaveCategoryW = 96.0;
// ~6 rows before the list scrolls, matching the other capped checklists.
static const CGFloat kSaveCategoryListMaxBody = 168.0;
NSNotificationName const KKCodeEditorReloadNotification =
    @"KKCodeEditorReloadNotification";

// The code editor lives in a nonactivating FxPlug ViewBridge popover where the
// host window stays key, so key events arrive as key EQUIVALENTS, not keyDown -
// exactly why a plain NSTextView's arrows / return / escape leak to the host.
// Mirror KKValueTextField: while we're the first responder, dispatch the
// equivalent to ourselves as a keyDown so it edits the code. Also handle the
// Cmd-A/C/V/X/Z cluster explicitly (a ViewBridge popover has no Edit menu, so
// those equivalents never reach us otherwise).
@interface _KKCodeTextView : NSTextView
// Gives the owner (KKCodeEditorView) first crack at Escape: returns YES to
// consume it (dismiss an open autocomplete) instead of blurring the editor.
@property(nonatomic, copy) BOOL (^escapeHandler)(void);
// Returns YES when an outside-the-editor click should NOT blur us (e.g. it
// landed on the autocomplete overlay, which the owner owns). Lets a click pick
// a row.
@property(nonatomic, copy) BOOL (^benignOutsideClick)(NSEvent *event);
@end

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

// Draw-only, hit-transparent edge fade hinting horizontal overflow in the error
// strip, matching the pill bars' overflow shadow.
@interface _KKErrEdgeShadow : NSView
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
@interface _KKNameField : NSTextField
@end
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
static const CGFloat kKKComplRowH = 22.0;
static const NSInteger kKKComplMaxRows = 8;
static const CGFloat kKKComplWidth = 400.0;
static const CGFloat kKKComplPad = 8.0; // horizontal text inset

@interface _KKExprCompletionView : NSView
@property(nonatomic, copy)
    NSArray<NSDictionary<NSString *, NSString *> *> *items;
@property(nonatomic) NSInteger selectedIndex;
@property(nonatomic, copy) void (^onPick)(NSInteger index);
@end

@implementation _KKExprCompletionView {
  NSTrackingArea *_track;
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
  self.needsDisplay = YES;
}

- (void)setSelectedIndex:(NSInteger)selectedIndex {
  _selectedIndex = selectedIndex;
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

// Footer sized to the TALLEST description in the current list, so switching the
// selection swaps the shown text without resizing the popup (no jump).
- (CGFloat)_footerHeight {
  NSInteger n = MIN((NSInteger)self.items.count, kKKComplMaxRows);
  CGFloat maxH = 0.0;
  for (NSInteger i = 0; i < n; i++)
    maxH = MAX(maxH, [self _descHeight:self.items[i][@"desc"]]);
  return maxH > 0.0 ? (1.0 + 6.0 + maxH + 6.0)
                    : 0.0; // divider + pad + text + pad
}

- (CGFloat)fittingHeight {
  NSInteger n = MIN((NSInteger)self.items.count, kKKComplMaxRows);
  return 1.0 + n * kKKComplRowH + [self _footerHeight] + 1.0;
}

- (NSInteger)_rowAtPoint:(NSPoint)p {
  NSInteger i = (NSInteger)floor((p.y - 1.0) / kKKComplRowH);
  NSInteger n = MIN((NSInteger)self.items.count, kKKComplMaxRows);
  return (i >= 0 && i < n) ? i : -1;
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

  for (NSInteger i = 0; i < n; i++) {
    NSRect row = NSMakeRect(1.0, 1.0 + i * kKKComplRowH,
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
@interface _KKSparklineView : NSView
@property(nonatomic, copy, nullable) NSArray<NSNumber *> *samples;
@property(nonatomic) double marker; // 0..1, negative hides the dot
@end

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

@interface KKCodeEditorView () <NSTextViewDelegate, NSTextStorageDelegate,
                                NSTextFieldDelegate, NSPopoverDelegate>
@end

@implementation KKCodeEditorView {
  NSTextView *_textView;
  NSTimer *_debounce;
  // Inline autocomplete (Expression syntax only): the overlay list, its current
  // matches, the highlighted row, and the partial-word range being completed.
  _KKExprCompletionView *_completion;
  NSArray<NSDictionary<NSString *, NSString *> *> *_completionItems;
  NSInteger _completionIndex;
  NSRange _completionWord;
  BOOL _highlightScheduled;
  KKCodeGutterView *_lineGutter;
  NSView *_errorBar;             // red strip container (height toggled 0/on)
  NSScrollView *_errorScroll;    // horizontal scroll so long messages fit
  NSTextField *_errorLabel;      // the message (document view of _errorScroll)
  NSButton *_errorCopyButton;    // floats on the right, copies the message
  CAGradientLayer *_errLeftGrad; // overflow edge fades (opacity = scroll pos)
  CAGradientLayer *_errRightGrad;
  NSLayoutConstraint
      *_errorScrollHeight; // = label line height, centered in strip
  NSLayoutConstraint *_errorBarHeight;
  NSInteger _errorLine; // 1-based line to flag, 0 = none
  // Optional read-only result strip (height toggled 0/on), under the error bar:
  // a host pushes the live computed result of an expression here for clarity.
  NSView *_resultBar;
  NSTextField *_resultLabel;
  _KKSparklineView *_sparkline; // trailing curve preview in the result strip
  NSButton *_resultCopyButton;  // trailing copy button, shown only on error
  NSLayoutConstraint *_resultBarHeight;
  NSString *_resultValueText; // host's "-> value" readout (shown when valid)
  NSString
      *_exprErrorText; // parser error (shown red in the strip when invalid)
  NSView *_saveBar;    // optional name + Save strip (height toggled 0/on)
  NSTextField *_saveNameField;
  NSButton *_saveButton;
  NSLayoutConstraint *_saveBarHeight;
  id _nameOutsideClickMon; // blur the name field on an outside click
  // Optional category picker between the name field and Save. Width collapses
  // to 0 when a host offers no labels, so the name field takes the whole strip.
  _KKDropdownTrigger *_saveCategoryField;
  NSLayoutConstraint *_saveCategoryWidth;
  NSLayoutConstraint *_saveCategoryGap; // name field -> picker
  NSPopover *_saveCategoryPopover;
  KKChoiceChecklistView *_saveCategoryList;
  NSArray<NSString *> *_saveCategoryLabels;
  NSInteger _saveCategoryIndex;
  // Tabbed sections: parallel names/codes, the active one shown in _textView.
  // A single (default) section behaves exactly like the plain editor - the tab
  // strip stays collapsed.
  NSMutableArray<NSString *> *_sectionNames;
  NSMutableArray<NSString *> *_sectionCodes;
  NSInteger _activeTab;
  NSStackView *_tabBar;
  NSLayoutConstraint *_tabBarHeight;
}
@synthesize codeValidator = _codeValidator;
@synthesize codeFormatter = _codeFormatter;

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
    // One implicit unnamed section until a host sets more (keeps the plain
    // single-editor behaviour + tab strip collapsed). The name is invisible
    // while there's a single section; a tabbed host (e.g. the shader lane)
    // names its sections explicitly via setSections:.
    _sectionNames = [@[ @"Main" ] mutableCopy];
    _sectionCodes = [@[ @"" ] mutableCopy];
    _activeTab = 0;
    // Solid GitHub-Dark box, forced dark so scrollers / caret render for a dark
    // theme regardless of the host inspector's appearance.
    self.appearance = [NSAppearance appearanceNamed:NSAppearanceNameDarkAqua];
    self.wantsLayer = YES;
    self.layer.backgroundColor = KKCodeBG().CGColor;
    self.layer.borderColor = KKCodeBorder().CGColor;
    self.layer.borderWidth = 1.0;
    self.layer.cornerRadius = 8.0;
    self.layer.masksToBounds = YES; // clip the scroller to the rounded corners

    NSScrollView *scroll = [[NSScrollView alloc] initWithFrame:self.bounds];
    scroll.translatesAutoresizingMaskIntoConstraints = NO;
    scroll.hasVerticalScroller = YES;
    scroll.hasHorizontalScroller = YES; // code overflows, not wraps
    scroll.borderType = NSNoBorder;
    scroll.drawsBackground = NO; // let the container's tint show through

    _textView = [[_KKCodeTextView alloc] initWithFrame:self.bounds];
    _textView.delegate = self;
    _completionWord = NSMakeRange(NSNotFound, 0);
    __weak typeof(self) weakEsc = self;
    ((_KKCodeTextView *)_textView).escapeHandler = ^BOOL {
      __strong typeof(weakEsc) s = weakEsc;
      if (s && s->_completion.superview) {
        [s _hideCompletion];
        return YES;
      }
      return NO;
    };
    ((_KKCodeTextView *)_textView).benignOutsideClick = ^BOOL(NSEvent *e) {
      __strong typeof(weakEsc) s = weakEsc;
      NSView *content = s ? s->_completion.superview : nil;
      if (!content)
        return NO;
      NSPoint p = [content convertPoint:e.locationInWindow fromView:nil];
      return NSPointInRect(p, s->_completion.frame);
    };
    _textView.textStorage.delegate = self; // drives syntax colouring
    _textView.font = [NSFont monospacedSystemFontOfSize:9.5
                                                 weight:NSFontWeightRegular];
    _textView.richText = NO;
    _textView.drawsBackground = NO; // show the container's tint behind the code
    _textView.automaticQuoteSubstitutionEnabled = NO;
    _textView.automaticDashSubstitutionEnabled = NO;
    _textView.automaticTextReplacementEnabled = NO;
    _textView.automaticSpellingCorrectionEnabled = NO;
    _textView.allowsUndo = YES;
    // No wrapping: lines overflow horizontally into the scroll view.
    _textView.horizontallyResizable = YES;
    _textView.verticallyResizable = YES;
    _textView.maxSize = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    _textView.textContainer.widthTracksTextView = NO;
    _textView.textContainer.size = NSMakeSize(CGFLOAT_MAX, CGFLOAT_MAX);
    _textView.textContainerInset = NSMakeSize(6.0, 6.0); // breathing room
    // Themed default text, caret and selection (GitHub Dark). Typing attributes
    // seed newly typed characters light before the re-colour pass runs.
    _textView.textColor = KKCodeText();
    _textView.typingAttributes = @{
      NSForegroundColorAttributeName : KKCodeText(),
      NSFontAttributeName : _textView.font,
    };
    _textView.insertionPointColor = KKCodeCursor();
    _textView.selectedTextAttributes = @{
      NSBackgroundColorAttributeName : KKHex(0x264f78),
    };

    scroll.documentView = _textView;
    // Line-number gutter: a plain strip to the left of the scroll view, redrawn
    // as the text scrolls (we watch the clip view's bounds).
    _lineGutter = [[KKCodeGutterView alloc] initWithFrame:NSZeroRect];
    _lineGutter.textView = _textView;
    _lineGutter.translatesAutoresizingMaskIntoConstraints = NO;
    [self addSubview:_lineGutter];
    scroll.contentView.postsBoundsChangedNotifications = YES;
    [NSNotificationCenter.defaultCenter
        addObserver:self
           selector:@selector(_scrollBoundsChanged:)
               name:NSViewBoundsDidChangeNotification
             object:scroll.contentView];
    [self addSubview:scroll];

    // Error bar under the editor: collapsed (height 0) until a validator
    // reports a problem. Compiler messages can be long, so the text lives in a
    // horizontal scroll view (read the whole thing, no truncation) with a copy
    // button pinned on the right.
    _errorBar = [NSView new];
    _errorBar.translatesAutoresizingMaskIntoConstraints = NO;
    _errorBar.wantsLayer = YES;
    _errorBar.layer.backgroundColor = KKHex(0x2d1214).CGColor;
    [self addSubview:_errorBar];
    _errorBarHeight = [_errorBar.heightAnchor constraintEqualToConstant:0.0];

    _errorLabel = [NSTextField labelWithString:@""];
    _errorLabel.font = [NSFont monospacedSystemFontOfSize:8.5
                                                   weight:NSFontWeightMedium];
    _errorLabel.textColor = KKCodeError();
    _errorLabel.lineBreakMode = NSLineBreakByClipping;
    _errorLabel.maximumNumberOfLines = 1;
    _errorLabel.drawsBackground = NO;
    _errorLabel.selectable = YES;

    _errorScroll = [NSScrollView new];
    _errorScroll.translatesAutoresizingMaskIntoConstraints = NO;
    _errorScroll.drawsBackground = NO;
    _errorScroll.hasHorizontalScroller = YES;
    _errorScroll.hasVerticalScroller = NO;
    _errorScroll.horizontalScrollElasticity = NSScrollElasticityAllowed;
    _errorScroll.verticalScrollElasticity = NSScrollElasticityNone;
    _errorScroll.scrollerStyle = NSScrollerStyleOverlay;
    _errorScroll.automaticallyAdjustsContentInsets = NO;
    _errorScroll.documentView = _errorLabel;
    _errorScrollHeight =
        [_errorScroll.heightAnchor constraintEqualToConstant:12.0];
    _errorScroll.contentView.postsBoundsChangedNotifications = YES;
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(_errorScrolled)
               name:NSViewBoundsDidChangeNotification
             object:_errorScroll.contentView];
    [_errorBar addSubview:_errorScroll];

    // Overflow edge fades over the scroll (opacity driven by scroll position),
    // same idiom as the pill bars.
    _KKErrEdgeShadow *errLeft = [_KKErrEdgeShadow new];
    _KKErrEdgeShadow *errRight = [_KKErrEdgeShadow new];
    errLeft.translatesAutoresizingMaskIntoConstraints = NO;
    errRight.translatesAutoresizingMaskIntoConstraints = NO;
    id fadeOpaque =
        (__bridge id)[[NSColor blackColor] colorWithAlphaComponent:0.3].CGColor;
    id fadeClear = (__bridge id)[NSColor clearColor].CGColor;
    _errLeftGrad = [CAGradientLayer layer];
    _errLeftGrad.colors = @[ fadeOpaque, fadeClear ];
    _errLeftGrad.startPoint = CGPointMake(0, 0.5);
    _errLeftGrad.endPoint = CGPointMake(1, 0.5);
    _errLeftGrad.opacity = 0.0;
    errLeft.wantsLayer = YES;
    errLeft.layer = _errLeftGrad;
    _errRightGrad = [CAGradientLayer layer];
    _errRightGrad.colors = @[ fadeClear, fadeOpaque ];
    _errRightGrad.startPoint = CGPointMake(0, 0.5);
    _errRightGrad.endPoint = CGPointMake(1, 0.5);
    _errRightGrad.opacity = 0.0;
    errRight.wantsLayer = YES;
    errRight.layer = _errRightGrad;
    [_errorBar addSubview:errLeft];
    [_errorBar addSubview:errRight];

    NSImage *copyImg = [NSImage imageWithSystemSymbolName:@"doc.on.doc"
                                 accessibilityDescription:@"Copy"];
    copyImg = [copyImg imageWithSymbolConfiguration:
                           [NSImageSymbolConfiguration
                               configurationWithPointSize:9.5
                                                   weight:NSFontWeightRegular]];
    _errorCopyButton =
        copyImg
            ? [NSButton buttonWithImage:copyImg
                                 target:self
                                 action:@selector(_copyError:)]
            : [NSButton
                  buttonWithTitle:KKLoc(@"Copy",
                                        @"Copy button (error bar fallback).")
                           target:self
                           action:@selector(_copyError:)];
    _errorCopyButton.translatesAutoresizingMaskIntoConstraints = NO;
    _errorCopyButton.bordered = NO;
    _errorCopyButton.imagePosition = copyImg ? NSImageOnly : NSNoImage;
    _errorCopyButton.imageScaling = NSImageScaleProportionallyDown;
    _errorCopyButton.contentTintColor = KKCodeError();
    _errorCopyButton.toolTip =
        KKLoc(@"Copy error message", @"Error-bar copy button tooltip.");
    [_errorBar addSubview:_errorCopyButton];

    [NSLayoutConstraint activateConstraints:@[
      [errLeft.leadingAnchor
          constraintEqualToAnchor:_errorScroll.leadingAnchor],
      [errLeft.topAnchor constraintEqualToAnchor:_errorBar.topAnchor],
      [errLeft.bottomAnchor constraintEqualToAnchor:_errorBar.bottomAnchor],
      [errLeft.widthAnchor constraintEqualToConstant:16.0],
      [errRight.trailingAnchor
          constraintEqualToAnchor:_errorScroll.trailingAnchor],
      [errRight.topAnchor constraintEqualToAnchor:_errorBar.topAnchor],
      [errRight.bottomAnchor constraintEqualToAnchor:_errorBar.bottomAnchor],
      [errRight.widthAnchor constraintEqualToConstant:16.0],
    ]];

    // Optional save bar at the very bottom: a name field + Save button (Save
    // disabled until a name is typed). Collapsed to height 0 unless `savable`.
    _saveBar = [NSView new];
    _saveBar.translatesAutoresizingMaskIntoConstraints = NO;
    _saveBar.wantsLayer = YES;
    _saveBar.layer.backgroundColor = KKHex(0x161b22).CGColor;
    _saveBar.hidden = YES;
    [self addSubview:_saveBar];
    _saveBarHeight = [_saveBar.heightAnchor constraintEqualToConstant:0.0];

    _saveNameField = [_KKNameField new];
    _saveNameField.translatesAutoresizingMaskIntoConstraints = NO;
    _saveNameField.font = [NSFont systemFontOfSize:11.0];
    _saveNameField.placeholderString = KKLoc(
        @"Name", @"Code editor save-bar name field placeholder (generic).");
    _saveNameField.bezelStyle = NSTextFieldRoundedBezel;
    _saveNameField.focusRingType = NSFocusRingTypeNone;
    _saveNameField.delegate = self;
    // Blur on a click outside the field (persistent monitor, gated on editing;
    // begin/end-editing fires too late for the first click-away).
    _nameOutsideClickMon = KKMakeFieldOutsideClickMonitor(_saveNameField);
    [_saveBar addSubview:_saveNameField];

    _saveCategoryField = [_KKDropdownTrigger new];
    _saveCategoryField.translatesAutoresizingMaskIntoConstraints = NO;
    _saveCategoryField.hidden = YES; // until a host supplies labels
    __weak typeof(self) weakSelf = self;
    _saveCategoryField.onTapped = ^{
      [weakSelf _toggleSaveCategoryList];
    };
    [_saveBar addSubview:_saveCategoryField];
    _saveCategoryWidth =
        [_saveCategoryField.widthAnchor constraintEqualToConstant:0.0];
    _saveCategoryGap = [_saveNameField.trailingAnchor
        constraintEqualToAnchor:_saveCategoryField.leadingAnchor
                       constant:0.0];

    _saveButton =
        [NSButton buttonWithTitle:KKLoc(@"Save", @"Save-shader button.")
                           target:self
                           action:@selector(_saveClicked:)];
    _saveButton.translatesAutoresizingMaskIntoConstraints = NO;
    _saveButton.bezelStyle = NSBezelStyleRegularSquare; // fills its height
    _saveButton.enabled = NO;
    [_saveBar addSubview:_saveButton];

    // Read-only result strip under the error bar: collapsed until a host sets
    // `resultText` (the live computed result of an expression). Dimmed, single
    // line, truncates with a tooltip.
    _resultBar = [NSView new];
    _resultBar.translatesAutoresizingMaskIntoConstraints = NO;
    _resultBar.wantsLayer = YES;
    _resultBar.layer.backgroundColor = KKHex(0x161b22).CGColor;
    [self addSubview:_resultBar];
    _resultBarHeight = [_resultBar.heightAnchor constraintEqualToConstant:0.0];
    _resultLabel = [NSTextField labelWithString:@""];
    _resultLabel.translatesAutoresizingMaskIntoConstraints = NO;
    _resultLabel.font = [NSFont monospacedSystemFontOfSize:8.5
                                                    weight:NSFontWeightMedium];
    _resultLabel.textColor = [KKCodeText() colorWithAlphaComponent:0.55];
    _resultLabel.lineBreakMode = NSLineBreakByTruncatingTail;
    _resultLabel.maximumNumberOfLines = 1;
    _resultLabel.drawsBackground = NO;
    _resultLabel.selectable = NO;
    [_resultBar addSubview:_resultLabel];

    // Curve preview at the trailing end of the result strip: hidden until a
    // host pushes samples. Fixed width so the number keeps the rest of the row.
    _sparkline = [_KKSparklineView new];
    _sparkline.translatesAutoresizingMaskIntoConstraints = NO;
    _sparkline.marker = -1.0;
    _sparkline.hidden = YES;
    [_resultBar addSubview:_sparkline];

    // Copy button for an error message (mirrors the GLSL error bar's), at the
    // trailing edge where the sparkline sits; only one of the two shows at a
    // time.
    NSImage *rCopyImg = [NSImage imageWithSystemSymbolName:@"doc.on.doc"
                                  accessibilityDescription:nil];
    _resultCopyButton =
        rCopyImg
            ? [NSButton buttonWithImage:rCopyImg
                                 target:self
                                 action:@selector(_copyExprError:)]
            : [NSButton buttonWithTitle:KKLoc(@"Copy",
                                              @"Copy button (error fallback).")
                                 target:self
                                 action:@selector(_copyExprError:)];
    _resultCopyButton.translatesAutoresizingMaskIntoConstraints = NO;
    _resultCopyButton.bordered = NO;
    _resultCopyButton.imagePosition = rCopyImg ? NSImageOnly : NSNoImage;
    _resultCopyButton.imageScaling = NSImageScaleProportionallyDown;
    _resultCopyButton.contentTintColor = KKCodeError();
    _resultCopyButton.toolTip =
        KKLoc(@"Copy error message", @"Result-strip copy button tooltip.");
    _resultCopyButton.hidden = YES;
    [_resultBar addSubview:_resultCopyButton];

    // A host can post this to reload the editor after loading a different
    // shader.
    [[NSNotificationCenter defaultCenter]
        addObserver:self
           selector:@selector(_reloadRequested:)
               name:KKCodeEditorReloadNotification
             object:nil];

    // Tab strip across the top: a row of section buttons. Collapsed to height 0
    // until a host sets 2+ sections (single-section editing looks unchanged).
    _tabBar = [NSStackView new];
    _tabBar.translatesAutoresizingMaskIntoConstraints = NO;
    _tabBar.orientation = NSUserInterfaceLayoutOrientationHorizontal;
    _tabBar.alignment = NSLayoutAttributeCenterY;
    _tabBar.spacing = 2.0;
    _tabBar.edgeInsets = NSEdgeInsetsMake(0, 6, 0, 6);
    _tabBar.hidden = YES;
    [self addSubview:_tabBar];
    _tabBarHeight = [_tabBar.heightAnchor constraintEqualToConstant:0.0];

    [NSLayoutConstraint activateConstraints:@[
      [_tabBar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [_tabBar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [_tabBar.topAnchor constraintEqualToAnchor:self.topAnchor],
      _tabBarHeight,
      [_lineGutter.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [_lineGutter.topAnchor constraintEqualToAnchor:_tabBar.bottomAnchor],
      [_lineGutter.bottomAnchor constraintEqualToAnchor:_errorBar.topAnchor],
      [_lineGutter.widthAnchor constraintEqualToConstant:34.0],
      [scroll.leadingAnchor constraintEqualToAnchor:_lineGutter.trailingAnchor],
      [scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [scroll.topAnchor constraintEqualToAnchor:_tabBar.bottomAnchor],
      [scroll.bottomAnchor constraintEqualToAnchor:_errorBar.topAnchor],
      [_errorBar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [_errorBar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [_errorBar.bottomAnchor constraintEqualToAnchor:_resultBar.topAnchor],
      _errorBarHeight,
      [_resultBar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [_resultBar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [_resultBar.bottomAnchor constraintEqualToAnchor:_saveBar.topAnchor],
      _resultBarHeight,
      [_resultLabel.leadingAnchor
          constraintEqualToAnchor:_resultBar.leadingAnchor
                         constant:6.0],
      [_resultLabel.trailingAnchor
          constraintLessThanOrEqualToAnchor:_sparkline.leadingAnchor
                                   constant:-6.0],
      [_resultLabel.centerYAnchor
          constraintEqualToAnchor:_resultBar.centerYAnchor],
      [_sparkline.trailingAnchor
          constraintEqualToAnchor:_resultBar.trailingAnchor
                         constant:-6.0],
      [_sparkline.topAnchor constraintEqualToAnchor:_resultBar.topAnchor
                                           constant:1.0],
      [_sparkline.bottomAnchor constraintEqualToAnchor:_resultBar.bottomAnchor
                                              constant:-1.0],
      [_sparkline.widthAnchor constraintEqualToConstant:54.0],
      [_resultCopyButton.trailingAnchor
          constraintEqualToAnchor:_resultBar.trailingAnchor
                         constant:-6.0],
      [_resultCopyButton.centerYAnchor
          constraintEqualToAnchor:_resultBar.centerYAnchor],
      [_resultCopyButton.widthAnchor constraintEqualToConstant:13.0],
      [_resultCopyButton.heightAnchor constraintEqualToConstant:13.0],
      [_saveBar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [_saveBar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [_saveBar.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
      _saveBarHeight,
      // Field pinned with equal top/bottom insets (symmetric padding); the Save
      // button matches the field's height and centre.
      [_saveNameField.leadingAnchor
          constraintEqualToAnchor:_saveBar.leadingAnchor
                         constant:8.0],
      [_saveNameField.topAnchor constraintEqualToAnchor:_saveBar.topAnchor
                                               constant:6.0],
      [_saveNameField.bottomAnchor constraintEqualToAnchor:_saveBar.bottomAnchor
                                                  constant:-6.0],
      // Name field -> category picker -> Save. Both the picker's width and the
      // gap BEFORE it collapse to 0 when unused, leaving just the gap after it
      // - so a save bar with no categories measures exactly as it did before
      // the picker existed.
      _saveCategoryGap,
      _saveCategoryWidth,
      [_saveCategoryField.trailingAnchor
          constraintEqualToAnchor:_saveButton.leadingAnchor
                         constant:-6.0],
      [_saveCategoryField.centerYAnchor
          constraintEqualToAnchor:_saveNameField.centerYAnchor],
      [_saveCategoryField.heightAnchor
          constraintEqualToAnchor:_saveNameField.heightAnchor],
      [_saveButton.trailingAnchor
          constraintEqualToAnchor:_saveBar.trailingAnchor
                         constant:-8.0],
      [_saveButton.centerYAnchor
          constraintEqualToAnchor:_saveNameField.centerYAnchor],
      [_saveButton.heightAnchor
          constraintEqualToAnchor:_saveNameField.heightAnchor],
      [_errorCopyButton.trailingAnchor
          constraintEqualToAnchor:_errorBar.trailingAnchor
                         constant:-6.0],
      [_errorCopyButton.centerYAnchor
          constraintEqualToAnchor:_errorBar.centerYAnchor
                         constant:-1.0], // optical nudge up (SF symbol sits
                                         // low)
      [_errorCopyButton.widthAnchor constraintEqualToConstant:16.0],
      [_errorScroll.leadingAnchor
          constraintEqualToAnchor:_errorBar.leadingAnchor
                         constant:6.0],
      [_errorScroll.trailingAnchor
          constraintEqualToAnchor:_errorCopyButton.leadingAnchor
                         constant:-6.0],
      // Clip = one line tall, centered in the strip, so the message reads
      // vertically centered (a full-height clip would top-align the text).
      [_errorScroll.centerYAnchor
          constraintEqualToAnchor:_errorBar.centerYAnchor],
      _errorScrollHeight,
    ]];
  }
  return self;
}

- (void)_scrollBoundsChanged:(NSNotification *)note {
  [_lineGutter setNeedsDisplay:YES];
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
  if (_nameOutsideClickMon)
    [NSEvent removeMonitor:_nameOutsideClickMon];
}

- (NSString *)codeText {
  // -[NSTextView string] returns the LIVE mutable backing store, not a
  // snapshot; copy so callers (and our section array) hold stable text that
  // doesn't mutate when the editor content later changes.
  return [_textView.string copy];
}

- (void)setCodeText:(NSString *)codeText {
  if ([_textView.string isEqualToString:codeText])
    return;
  _textView.string = codeText ?: @"";
  _sectionCodes[_activeTab] = [_textView.string copy];
  [self _runValidator]; // validates expressions too (KKLinkExpr) -> error strip
}

- (void)insertReferenceText:(NSString *)text {
  if (text.length == 0)
    return;
  // Replace the current selection (a plain caret is a zero-length selection at
  // the insertion point); when the editor was never focused the selection sits
  // at 0, so a leading token lands at the start - acceptable for an append-like
  // insert. Route through shouldChange/didChange so it's one undoable edit and
  // fires the normal debounce -> onChange persist, exactly like _formatClicked.
  NSRange sel = _textView.selectedRange;
  if (sel.location == NSNotFound || NSMaxRange(sel) > _textView.string.length)
    sel = NSMakeRange(_textView.string.length, 0);
  if (![_textView shouldChangeTextInRange:sel replacementString:text])
    return;
  [_textView replaceCharactersInRange:sel withString:text];
  [_textView didChangeText]; // fires textDidChange: -> debounce -> commit
  NSUInteger caret = MIN(sel.location + text.length, _textView.string.length);
  _textView.selectedRange = NSMakeRange(caret, 0);
  [self _runValidator];
}

- (void)setCodeValidator:(NSString * (^)(NSString *,
                                         NSInteger *))codeValidator {
  _codeValidator = [codeValidator copy];
  [self _runValidator];
}

- (void)setCodeFormatter:(NSString * (^)(NSString *))codeFormatter {
  _codeFormatter = [codeFormatter copy];
  [self _rebuildTabBar]; // show / hide the Format button
}

- (void)setSections:
    (NSArray<NSDictionary<NSString *, NSString *> *> *)sections {
  if (sections.count == 0)
    return;
  NSMutableArray<NSString *> *names = [NSMutableArray array];
  NSMutableArray<NSString *> *codes = [NSMutableArray array];
  for (NSDictionary *s in sections) {
    [names addObject:[s[@"name"] isKindOfClass:[NSString class]] ? s[@"name"]
                                                                 : @""];
    [codes addObject:[s[@"code"] isKindOfClass:[NSString class]] ? s[@"code"]
                                                                 : @""];
  }
  _sectionNames = names;
  _sectionCodes = codes;
  if (_activeTab >= (NSInteger)codes.count)
    _activeTab = 0;
  _textView.string = _sectionCodes[_activeTab] ?: @"";
  [self _rebuildTabBar];
  [self _runValidator];
}

- (NSArray<NSDictionary<NSString *, NSString *> *> *)sections {
  _sectionCodes[_activeTab] =
      [_textView.string copy]; // fold active tab's edits
  NSMutableArray<NSDictionary<NSString *, NSString *> *> *out =
      [NSMutableArray array];
  for (NSInteger i = 0; i < (NSInteger)_sectionNames.count; i++)
    [out addObject:@{
      @"name" : _sectionNames[i],
      @"code" : _sectionCodes[i] ?: @""
    }];
  return out;
}

// `canUndo` is our "uncommitted local burst in progress" signal: the debounce
// commit clears the local undo, so a non-empty local stack means the user is
// mid-typing and an external re-apply would clobber them.
- (BOOL)_hasUncommittedTyping {
  return self.undoManager.canUndo;
}

- (void)applyExternalText:(NSString *)text {
  if ([self _hasUncommittedTyping])
    return;
  if ([_textView.string isEqualToString:text ?: @""])
    return;
  self.codeText = text ?: @"";
  [_textView.undoManager removeAllActions];
}

- (void)applyExternalSections:
    (NSArray<NSDictionary<NSString *, NSString *> *> *)sections {
  if (!sections.count || [self _hasUncommittedTyping])
    return;
  if ([[self sections] isEqualToArray:sections])
    return;
  [self setSections:sections];
  [_textView.undoManager removeAllActions];
}

// A borderless text button styled for the strip.
- (NSButton *)_stripButton:(NSString *)title
                    action:(SEL)action
                       tag:(NSInteger)tag
                     color:(NSColor *)color
                      size:(CGFloat)size
                    weight:(NSFontWeight)weight {
  NSButton *b = [NSButton buttonWithTitle:title target:self action:action];
  b.tag = tag;
  b.bordered = NO;
  b.attributedTitle = [[NSAttributedString alloc]
      initWithString:title
          attributes:@{
            NSForegroundColorAttributeName : color,
            NSFontAttributeName : [NSFont monospacedSystemFontOfSize:size
                                                              weight:weight]
          }];
  return b;
}

// Rebuild the tab strip: current sections (active bright + semibold), a close
// button on each added (non-first) tab, and a "+" menu of not-yet-added catalog
// names. Collapses to nothing when there's a single tab and nothing to add.
- (void)_rebuildTabBar {
  for (NSView *v in [_tabBar.arrangedSubviews copy]) {
    [_tabBar removeArrangedSubview:v];
    [v removeFromSuperview];
  }
  NSMutableArray<NSString *> *addable = [NSMutableArray array];
  for (NSString *n in _addableTabNames)
    if (![_sectionNames containsObject:n])
      [addable addObject:n];
  BOOL show = (_sectionNames.count > 1) || (addable.count > 0) ||
              (_codeFormatter != nil);
  _tabBar.hidden = !show;
  _tabBarHeight.constant = show ? 22.0 : 0.0;
  // Fill only when the Format button is present, so a spacer can push it to the
  // trailing edge; otherwise gravity-areas keeps the tabs left-packed at their
  // natural size.
  _tabBar.distribution = _codeFormatter ? NSStackViewDistributionFill
                                        : NSStackViewDistributionGravityAreas;
  if (!show)
    return;
  for (NSInteger i = 0; i < (NSInteger)_sectionNames.count; i++) {
    BOOL active = (i == _activeTab);
    [_tabBar addArrangedSubview:
                 [self _stripButton:_sectionNames[i]
                             action:@selector(_tabClicked:)
                                tag:i
                              color:active ? KKCodeText()
                                           : [KKCodeText()
                                                 colorWithAlphaComponent:0.45]
                               size:9.5
                             weight:active ? NSFontWeightSemibold
                                           : NSFontWeightRegular]];
    if (i > 0) // the first section is permanent; added tabs get a close button
      [_tabBar
          addArrangedSubview:[self
                                 _stripButton:@"✕"
                                       action:@selector(_tabCloseClicked:)
                                          tag:i
                                        color:[KKCodeText()
                                                  colorWithAlphaComponent:0.35]
                                         size:8.5
                                       weight:NSFontWeightRegular]];
  }
  if (addable.count > 0)
    [_tabBar
        addArrangedSubview:[self _stripButton:@"+"
                                       action:@selector(_plusClicked:)
                                          tag:-1
                                        color:[KKCodeText()
                                                  colorWithAlphaComponent:0.6]
                                         size:13.0
                                       weight:NSFontWeightMedium]];
  if (_codeFormatter) {
    // A greedy spacer (lowest hugging in a fill stack) eats the slack so the
    // Format button sits at the trailing edge, whatever the tab count.
    NSView *spacer = [NSView new];
    [spacer setContentHuggingPriority:1
                       forOrientation:NSLayoutConstraintOrientationHorizontal];
    [_tabBar addArrangedSubview:spacer];
    NSButton *fmt =
        [self _stripButton:KKLoc(@"Format", @"Code editor: reformat button.")
                    action:@selector(_formatClicked:)
                       tag:-2
                     color:[KKCodeText() colorWithAlphaComponent:0.6]
                      size:9.5
                    weight:NSFontWeightMedium];
    fmt.toolTip = KKLoc(@"Reformat the code to the house style",
                        @"Code editor: Format button tooltip.");
    [_tabBar addArrangedSubview:fmt];
  }
}

// Run the owner's formatter over the active section and replace the editor
// content with the result, as a single undoable edit. The change flows through
// the normal textDidChange debounce (stash / validate / commit), so the host
// persists the formatted text just like a typed edit. No-op when the formatter
// returns nil or text that is already formatted.
- (void)_formatClicked:(id)sender {
  [self formatUsing:_codeFormatter];
}

- (void)formatUsing:(NSString * (^)(NSString *))formatter {
  if (!formatter)
    return;
  NSString *current = [_textView.string copy];
  NSString *formatted = formatter(current);
  if (formatted.length == 0 || [formatted isEqualToString:current])
    return;
  NSRange full = NSMakeRange(0, current.length);
  if (![_textView shouldChangeTextInRange:full replacementString:formatted])
    return;
  NSUInteger caret = _textView.selectedRange.location;
  [_textView replaceCharactersInRange:full withString:formatted];
  [_textView didChangeText]; // fires textDidChange: -> debounce -> commit
  NSUInteger newLen = _textView.string.length;
  _textView.selectedRange = NSMakeRange(MIN(caret, newLen), 0);
  [self _runValidator]; // snappier than waiting for the debounce
}

- (void)_tabClicked:(NSButton *)sender {
  [self _selectTab:sender.tag];
}

// "+" menu: the catalog names not yet present. Selecting one adds that section.
- (void)_plusClicked:(NSButton *)sender {
  NSMenu *menu = [[NSMenu alloc] init];
  for (NSString *n in _addableTabNames) {
    if ([_sectionNames containsObject:n])
      continue;
    NSMenuItem *it =
        [[NSMenuItem alloc] initWithTitle:n
                                   action:@selector(_addTabFromMenu:)
                            keyEquivalent:@""];
    it.target = self;
    it.representedObject = n;
    [menu addItem:it];
  }
  [menu popUpMenuPositioningItem:nil
                      atLocation:NSMakePoint(0, NSHeight(sender.bounds))
                          inView:sender];
}

- (void)_addTabFromMenu:(NSMenuItem *)item {
  NSString *name = item.representedObject;
  if (!name.length || [_sectionNames containsObject:name])
    return;
  // Insert keeping catalog order among the extra tabs (section 0 stays first).
  NSInteger catIdx = (NSInteger)[_addableTabNames indexOfObject:name];
  NSInteger insertAt = (NSInteger)_sectionNames.count;
  for (NSInteger i = 1; i < (NSInteger)_sectionNames.count; i++) {
    NSInteger ci = (NSInteger)[_addableTabNames indexOfObject:_sectionNames[i]];
    if (ci != NSNotFound && ci > catIdx) {
      insertAt = i;
      break;
    }
  }
  _sectionCodes[_activeTab] = [_textView.string copy]; // stash current
  [_sectionNames insertObject:name atIndex:insertAt];
  [_sectionCodes insertObject:@"" atIndex:insertAt];
  _activeTab = insertAt;
  _textView.string = @"";
  [self _rebuildTabBar];
  [self _runValidator];
  if (self.onSectionsChange)
    self.onSectionsChange([self sections]);
}

- (void)_tabCloseClicked:(NSButton *)sender {
  NSInteger i = sender.tag;
  if (i <= 0 || i >= (NSInteger)_sectionNames.count)
    return; // never remove the first section's tab
  [_sectionNames removeObjectAtIndex:i];
  [_sectionCodes removeObjectAtIndex:i];
  if (_activeTab >= (NSInteger)_sectionNames.count)
    _activeTab = (NSInteger)_sectionNames.count - 1;
  if (_activeTab < 0)
    _activeTab = 0;
  _textView.string = _sectionCodes[_activeTab] ?: @"";
  [self _rebuildTabBar];
  [self _runValidator];
  if (self.onSectionsChange)
    self.onSectionsChange([self sections]);
}

// Switch the visible tab: stash the current text, load the target's,
// revalidate.
- (void)_selectTab:(NSInteger)i {
  if (i < 0 || i >= (NSInteger)_sectionCodes.count || i == _activeTab)
    return;
  _sectionCodes[_activeTab] = [_textView.string copy];
  _activeTab = i;
  _textView.string = _sectionCodes[i] ?: @"";
  [self _rebuildTabBar]; // restyle the active button
  [self _runValidator];
}

// Run the owner's validator over the current text and reflect the result: a
// one-line red bar and a flagged line, or clear both when it's valid / absent.
- (void)_runValidator {
  // A host may pre-compose the active section with others (e.g. a shader
  // prepending a shared section) before validation; `prependLines` maps a
  // reported error line back to the active section, and an error landing in the
  // prepended region is suppressed here (it surfaces on that section's own
  // tab). With no composer the active section is validated as-is.
  NSString *code = _textView.string;
  NSInteger prependLines = 0;
  NSString *activeName = (_activeTab < (NSInteger)_sectionNames.count)
                             ? _sectionNames[_activeTab]
                             : @"";
  if (_validationSourceComposer) {
    NSInteger pl = 0;
    NSString *composed =
        _validationSourceComposer(activeName, code, [self sections], &pl);
    if (composed) {
      code = composed;
      prependLines = pl;
    }
  }
  NSInteger line = 0;
  NSString *err = _codeValidator ? _codeValidator(code, &line) : nil;
  if (err.length && prependLines > 0) {
    line -= prependLines;
    if (line < 1) { // error lives in Common; it's flagged on the Common tab
      err = nil;
      line = 0;
    }
  }
  // Expression editors have a BUILT-IN validator (KKLinkExpr) rather than a
  // host block, so they get the same error treatment (red line + gutter +
  // message + copy) for free.
  if (!_codeValidator && _syntax == KKCodeSyntaxExpression) {
    NSString *msg = nil;
    NSString *exprSrc = _textView.string;
    NSRange bad = [KKLinkExpr errorCharRangeForSource:exprSrc message:&msg];
    if (bad.location != NSNotFound && msg.length) {
      // Sentence-case the parser message.
      err = [[[msg substringToIndex:1] uppercaseString]
          stringByAppendingString:[msg substringFromIndex:1]];
      line = 1; // the line the error sits on (expressions are single-line)
      for (NSUInteger i = 0; i < bad.location && i < exprSrc.length; i++)
        if ([exprSrc characterAtIndex:i] == '\n')
          line++;
    }
  }
  _errorLine = err.length ? line : 0;

  // GLSL uses the tall (20px) error bar; the compact expression editor has no
  // room for it, so it surfaces the message in the result strip (with its own
  // copy button) instead. Both share the red line + red gutter highlight.
  BOOL exprMode = (_syntax == KKCodeSyntaxExpression);
  BOOL useBar = err.length && !exprMode;
  if (useBar) {
    _errorLabel.stringValue = err;
    [_errorLabel sizeToFit];
    // Document view = the text's own size so the scroll can pan a wide message
    // and the single line stays vertically centered (clip height == line
    // height).
    NSSize fit = _errorLabel.fittingSize;
    CGFloat lineH = ceil(fit.height);
    _errorLabel.frame = NSMakeRect(0, 0, ceil(fit.width) + 4.0, lineH);
    _errorScrollHeight.constant = lineH;
    [_errorScroll.contentView scrollToPoint:NSZeroPoint]; // reset to start
    _errorBarHeight.constant = 20.0;
  } else {
    _errorLabel.stringValue = @"";
    _errorBarHeight.constant = 0.0;
  }
  _errorCopyButton.hidden = !useBar;
  _exprErrorText = (err.length && exprMode) ? err : nil;
  [self _errorScrolled]; // refresh overflow fades for the new message width
  _lineGutter.errorLine = _errorLine;
  [self _applyHighlighting];  // repaint the flagged-line background
  [self _refreshResultStrip]; // expression message / value + copy button
  [_lineGutter setNeedsDisplay:YES];
}

- (void)_copyError:(id)sender {
  NSString *msg = _errorLabel.stringValue;
  if (!msg.length)
    return;
  NSPasteboard *pb = NSPasteboard.generalPasteboard;
  [pb clearContents];
  [pb setString:msg forType:NSPasteboardTypeString];
}

- (NSString *)resultText {
  return _resultValueText;
}

- (void)setResultText:(NSString *)resultText {
  _resultValueText = [resultText copy];
  [self _refreshResultStrip];
}

// The strip shows the parser error (red, Error-Lens style: always visible, no
// hover) when the expression is invalid, otherwise the host's "-> value"
// readout (dim) with its sparkline. Error wins because an invalid expression
// has no value.
- (void)_refreshResultStrip {
  BOOL hasError = _exprErrorText.length > 0;
  NSString *text = hasError ? _exprErrorText : (_resultValueText ?: @"");
  _resultLabel.stringValue = text;
  _resultLabel.textColor =
      hasError ? KKCodeError() : [KKCodeText() colorWithAlphaComponent:0.55];
  // Match the GLSL error bar: red text on a dark-red strip when invalid, the
  // neutral panel tint otherwise.
  _resultBar.layer.backgroundColor =
      (hasError ? KKHex(0x2d1214) : KKHex(0x161b22)).CGColor;
  _resultBarHeight.constant = text.length ? 16.0 : 0.0;
  // Error and value are mutually exclusive in the strip: error shows the copy
  // button, a valid value shows the sparkline.
  _resultCopyButton.hidden = !hasError;
  _sparkline.hidden =
      hasError || text.length == 0 || _sparkline.samples.count < 2;
}

- (void)_copyExprError:(id)sender {
  if (!_exprErrorText.length)
    return;
  NSPasteboard *pb = NSPasteboard.generalPasteboard;
  [pb clearContents];
  [pb setString:_exprErrorText forType:NSPasteboardTypeString];
}

- (NSArray<NSNumber *> *)sparklineSamples {
  return _sparkline.samples;
}

- (void)setSparklineSamples:(NSArray<NSNumber *> *)sparklineSamples {
  _sparkline.samples = sparklineSamples;
  [self _refreshResultStrip];
}

- (double)sparklineMarker {
  return _sparkline.marker;
}

- (void)setSparklineMarker:(double)sparklineMarker {
  _sparkline.marker = sparklineMarker;
}

- (void)setSavable:(BOOL)savable {
  _savable = savable;
  _saveBar.hidden = !savable;
  _saveBarHeight.constant = savable ? 34.0 : 0.0;
}

- (NSString *)saveNamePlaceholder {
  return _saveNameField.placeholderString;
}

- (void)setSaveNamePlaceholder:(NSString *)placeholder {
  _saveNameField.placeholderString =
      placeholder.length
          ? placeholder
          : KKLoc(@"Name",
                  @"Code editor save-bar name field placeholder (generic).");
}

- (NSArray<NSString *> *)saveCategoryLabels {
  return _saveCategoryLabels;
}

- (void)setSaveCategoryLabels:(NSArray<NSString *> *)labels {
  _saveCategoryLabels = [labels copy];
  BOOL on = _saveCategoryLabels.count > 0;
  _saveCategoryField.hidden = !on;
  _saveCategoryWidth.constant = on ? kSaveCategoryW : 0.0;
  _saveCategoryGap.constant = on ? -6.0 : 0.0;
  if (_saveCategoryIndex >= (NSInteger)_saveCategoryLabels.count)
    _saveCategoryIndex = 0; // a shorter list can't leave the pick dangling
  [self _syncSaveCategoryTitle];
}

- (NSInteger)saveCategoryIndex {
  return (_saveCategoryIndex >= 0 &&
          _saveCategoryIndex < (NSInteger)_saveCategoryLabels.count)
             ? _saveCategoryIndex
             : 0;
}

- (void)setSaveCategoryIndex:(NSInteger)index {
  _saveCategoryIndex = index;
  [self _syncSaveCategoryTitle];
}

- (void)_syncSaveCategoryTitle {
  NSInteger i = self.saveCategoryIndex;
  NSString *title =
      i < (NSInteger)_saveCategoryLabels.count ? _saveCategoryLabels[i] : nil;
  _saveCategoryField.summaryOverride = title;
  // What the trigger reads as "has a selection" - without it the title draws
  // dimmed, like an unset picker.
  _saveCategoryField.selectedLabels = title ? @[ title ] : nil;
  _saveCategoryField.rightAligned = NO;
  [_saveCategoryField setNeedsDisplay:YES];
}

// The picker's popover, built exactly like a `#choice dropdown` lane's: the
// wrapper strips AppKit's own glass so the kit's chrome isn't double-drawn, and
// the keep-alive registration stops the nonactivating host window from
// dismissing it the moment the click lands in the child window.
- (void)_toggleSaveCategoryList {
  if (_saveCategoryPopover) {
    [_saveCategoryPopover performClose:nil];
    return;
  }
  if (!_saveCategoryLabels.count)
    return;
  _saveCategoryList =
      [[KKChoiceChecklistView alloc] initWithOptions:_saveCategoryLabels
                                       selectedIndex:self.saveCategoryIndex
                                       maxBodyHeight:kSaveCategoryListMaxBody];
  __weak typeof(self) weak = self;
  _saveCategoryList.onSelect = ^(NSInteger index) {
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    s.saveCategoryIndex = index;
    [s->_saveCategoryPopover performClose:nil]; // a pick ends the interaction
  };

  _KKLVPopoverContentView *wrapper = [[_KKLVPopoverContentView alloc] init];
  wrapper.frame = _saveCategoryList.bounds;
  _saveCategoryList.translatesAutoresizingMaskIntoConstraints = NO;
  [wrapper addSubview:_saveCategoryList];
  [NSLayoutConstraint activateConstraints:@[
    [_saveCategoryList.leadingAnchor
        constraintEqualToAnchor:wrapper.leadingAnchor],
    [_saveCategoryList.trailingAnchor
        constraintEqualToAnchor:wrapper.trailingAnchor],
    [_saveCategoryList.topAnchor constraintEqualToAnchor:wrapper.topAnchor],
    [_saveCategoryList.bottomAnchor
        constraintEqualToAnchor:wrapper.bottomAnchor],
  ]];

  NSViewController *vc = [[NSViewController alloc] init];
  vc.view = wrapper;
  _saveCategoryPopover = [[NSPopover alloc] init];
  _saveCategoryPopover.contentViewController = vc;
  _saveCategoryPopover.behavior = NSPopoverBehaviorTransient;
  _saveCategoryPopover.delegate = self;
  // Wire the popover BEFORE sizing: the list only knows it is the popover's
  // whole content (rather than a section of a bigger one) once this is set, and
  // -refilterAndResize is what sizes the popover to the capped list. Skipping
  // it leaves the popover at the wrapper's init frame, which clips every row
  // past the first few until a search edit happens to re-run the resize.
  _saveCategoryList.popover = _saveCategoryPopover;
  [_saveCategoryList refilterAndResize];
  [_saveCategoryPopover showRelativeToRect:_saveCategoryField.bounds
                                    ofView:_saveCategoryField
                             preferredEdge:NSRectEdgeMinY];
  KKPopoverAddKeepAliveWindow(_saveCategoryList.window); // only once shown
}

- (void)popoverDidClose:(NSNotification *)notification {
  KKPopoverRemoveKeepAliveWindow(_saveCategoryList.window);
  _saveCategoryPopover = nil;
  _saveCategoryList = nil;
}

- (void)controlTextDidChange:(NSNotification *)note {
  if (note.object == _saveNameField)
    _saveButton.enabled =
        [_saveNameField.stringValue
            stringByTrimmingCharactersInSet:
                NSCharacterSet.whitespaceAndNewlineCharacterSet]
            .length > 0;
}

// Esc / Enter drop focus (blur), matching the code editor + value fields.
- (BOOL)control:(NSControl *)control
               textView:(NSTextView *)textView
    doCommandBySelector:(SEL)selector {
  if (control != _saveNameField)
    return NO;
  if (selector == @selector(insertNewline:) ||
      selector == @selector(cancelOperation:)) {
    [_saveNameField.window makeFirstResponder:nil];
    return YES;
  }
  return NO;
}

- (void)_reloadRequested:(NSNotification *)note {
  if (!_savable) // only the shader (savable) editor responds
    return;
  NSArray<NSDictionary<NSString *, NSString *> *> *sections =
      note.userInfo[KKCodeEditorSaveSectionsKey];
  if (sections.count)
    [self setSections:sections];
}

- (void)_saveClicked:(id)sender {
  NSString *name = [_saveNameField.stringValue
      stringByTrimmingCharactersInSet:NSCharacterSet
                                          .whitespaceAndNewlineCharacterSet];
  if (!name.length)
    return;
  NSMutableDictionary *info = [@{
    KKCodeEditorSaveNameKey : name,
    KKCodeEditorSaveSectionsKey : [self sections]
  } mutableCopy];
  // Absent, not 0, when the host offers no categories: 0 is a real pick, so a
  // host that never showed a picker must be able to tell the difference.
  if (_saveCategoryLabels.count)
    info[KKCodeEditorSaveCategoryIndexKey] = @(self.saveCategoryIndex);
  [[NSNotificationCenter defaultCenter]
      postNotificationName:KKCodeEditorSaveRequestedNotification
                    object:self
                  userInfo:info];
}

// Fade the overflow edges in/out with scroll position (0 when the message
// fits).
- (void)_errorScrolled {
  CGFloat docW = NSWidth(_errorLabel.frame);
  CGFloat visW = _errorScroll.contentView.bounds.size.width;
  CGFloat offX = _errorScroll.contentView.bounds.origin.x;
  CGFloat scrollable = docW - visW;
  [CATransaction begin];
  [CATransaction setDisableActions:YES];
  if (scrollable <= 0.5) {
    _errLeftGrad.opacity = 0.0;
    _errRightGrad.opacity = 0.0;
  } else {
    _errLeftGrad.opacity = (float)MAX(0.0, MIN(1.0, offX / 16.0));
    _errRightGrad.opacity =
        (float)MAX(0.0, MIN(1.0, (scrollable - offX) / 16.0));
  }
  [CATransaction commit];
}

// Character range of 1-based `line` in `s`, or {NSNotFound,0}.
- (NSRange)_rangeOfLine:(NSInteger)line in:(NSString *)s {
  if (line < 1)
    return NSMakeRange(NSNotFound, 0);
  NSUInteger idx = 0, cur = 1, start = 0, len = s.length;
  while (cur < line && idx < len) {
    if ([s characterAtIndex:idx] == '\n') {
      cur++;
      start = idx + 1;
    }
    idx++;
  }
  if (cur != line)
    return NSMakeRange(NSNotFound, 0);
  NSUInteger end = start;
  while (end < len && [s characterAtIndex:end] != '\n')
    end++;
  return NSMakeRange(start, end - start);
}

// Re-colour the whole document. Cheap for shader-sized sources, and full-doc is
// necessary so multi-line `/* ... */` comments colour correctly. Runs outside
// the text storage's edit processing (scheduled async), so begin/endEditing is
// safe here.
- (void)_applyHighlighting {
  NSTextStorage *ts = _textView.textStorage;
  NSString *src = ts.string;
  NSRange full = NSMakeRange(0, src.length);
  NSCharacterSet *ws = NSCharacterSet.whitespaceCharacterSet;
  [ts beginEditing];
  [_lineGutter setNeedsDisplay:YES]; // line count may have changed
  [ts removeAttribute:NSBackgroundColorAttributeName range:full];
  [ts addAttribute:NSForegroundColorAttributeName
             value:KKCodeText()
             range:full];
  if (_errorLine > 0) {
    NSRange lr = [self _rangeOfLine:_errorLine in:src];
    if (lr.location != NSNotFound)
      [ts addAttribute:NSBackgroundColorAttributeName
                 value:[KKCodeError() colorWithAlphaComponent:0.16]
                 range:lr];
  }
  if (_syntax == KKCodeSyntaxExpression) {
    // Expression grammar: 1 `${ref}` (orange, like an external input), 2
    // number, 3 identifier (built-in fn -> purple, var/const -> coral, else
    // default).
    [KKExprTokenizer()
        enumerateMatchesInString:src
                         options:0
                           range:full
                      usingBlock:^(NSTextCheckingResult *m,
                                   NSMatchingFlags flags, BOOL *stop) {
                        NSColor *color = nil;
                        NSRange r = [m rangeAtIndex:1];
                        if (r.location != NSNotFound) {
                          color = KKCodeUniform(); // ${ref}
                        } else if ((r = [m rangeAtIndex:2]).location !=
                                   NSNotFound) {
                          color = KKCodeNumber();
                        } else if ((r = [m rangeAtIndex:3]).location !=
                                   NSNotFound) {
                          color = KKExprWordColor([src substringWithRange:r]);
                        }
                        if (color && r.location != NSNotFound)
                          [ts addAttribute:NSForegroundColorAttributeName
                                     value:color
                                     range:r];
                      }];
    [ts endEditing];
    return;
  }
  [KKGLSLTokenizer()
      enumerateMatchesInString:src
                       options:0
                         range:full
                    usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags,
                                 BOOL *stop) {
                      NSColor *color = nil;
                      NSRange r = [m rangeAtIndex:1];
                      if (r.location != NSNotFound) {
                        color = KKCodeComment();
                      } else if ((r = [m rangeAtIndex:2]).location !=
                                 NSNotFound) {
                        color = KKCodeKeyword(); // #directive
                      } else if ((r = [m rangeAtIndex:3]).location !=
                                 NSNotFound) {
                        color = KKCodeNumber();
                      } else if ((r = [m rangeAtIndex:4]).location !=
                                 NSNotFound) {
                        color = KKGLSLWordColor([src substringWithRange:r]);
                        if (!color) {
                          // Not a known word: a function call if the next
                          // non-space char is `(`, else a plain variable.
                          NSUInteger j = NSMaxRange(r);
                          while (j < src.length &&
                                 [ws characterIsMember:[src
                                                           characterAtIndex:j]])
                            j++;
                          if (j < src.length && [src characterAtIndex:j] == '(')
                            color = KKCodeFunction();
                        }
                      }
                      if (color && r.location != NSNotFound)
                        [ts addAttribute:NSForegroundColorAttributeName
                                   value:color
                                   range:r];
                    }];
  // Overlay directive colouring on the grey comments: `// #kind` / `// @block`
  // headers + their `key = value` attributes/fields read as structured
  // annotations, not flat comments.
  [self _highlightDirectivesInStorage:ts source:src];
  [ts endEditing];
}

// A directive HEADER comment: `// #kind ...` / `// @block ...`. Group 1 is the
// `#kind` / `@block` token. `^` anchors it to the line start (after indent).
static NSRegularExpression *KKDirectiveHeaderRE(void) {
  static NSRegularExpression *re;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    re = [NSRegularExpression
        regularExpressionWithPattern:@"^\\s*//\\s*([#@][A-Za-z_]\\w*)"
                             options:0
                               error:nil];
  });
  return re;
}

// The colourable pieces after a directive header (and on each `key = value`
// block-continuation line): group 1 an attribute/field KEY (a word right before
// `=`), 2 a quoted string, 3 a number.
static NSRegularExpression *KKDirectiveBodyRE(void) {
  static NSRegularExpression *re;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    re = [NSRegularExpression
        regularExpressionWithPattern:@"([A-Za-z_]\\w*)(?=\\s*=(?!=))" // 1 key
                                     @"|(\"(?:[^\"\\\\]|\\\\.)*\")"   // 2 str
                                     @"|(?<![\\w.])(-?\\d+\\.?\\d*)"  // 3 num
                                     @"|([A-Za-z_]\\w*)"              // 4 ident
                             options:0
                               error:nil];
  });
  return re;
}

// Colour keys/strings/numbers in `range` (a directive line's body). `ts`/`src`
// as in -_applyHighlighting; `range` is in `src` coordinates.
- (void)_colorDirectiveBodyRange:(NSRange)range
                       inStorage:(NSTextStorage *)ts
                          source:(NSString *)src {
  if (range.length == 0)
    return;
  NSCharacterSet *ws = NSCharacterSet.whitespaceCharacterSet;
  [KKDirectiveBodyRE()
      enumerateMatchesInString:src
                       options:0
                         range:range
                    usingBlock:^(NSTextCheckingResult *m, NSMatchingFlags flags,
                                 BOOL *stop) {
                      NSColor *color = nil;
                      NSRange r = [m rangeAtIndex:1];
                      if (r.location != NSNotFound) {
                        color = KKCodeUniform(); // key= (orange)
                      } else if ((r = [m rangeAtIndex:2]).location !=
                                 NSNotFound) {
                        color = KKCodeString();
                      } else if ((r = [m rangeAtIndex:3]).location !=
                                 NSNotFound) {
                        color = KKCodeNumber();
                      } else if ((r = [m rangeAtIndex:4]).location !=
                                 NSNotFound) {
                        // A value identifier (tr, pad, vec2…): a function call
                        // when the next non-space char is `(`, else a plain
                        // value - either way NOT the flat comment grey.
                        NSUInteger j = NSMaxRange(r);
                        while (j < src.length &&
                               [ws characterIsMember:[src characterAtIndex:j]])
                          j++;
                        color =
                            (j < src.length && [src characterAtIndex:j] == '(')
                                ? KKCodeFunction()
                                : KKCodeText();
                      }
                      if (color && r.location != NSNotFound)
                        [ts addAttribute:NSForegroundColorAttributeName
                                   value:color
                                   range:r];
                    }];
}

- (void)_highlightDirectivesInStorage:(NSTextStorage *)ts
                               source:(NSString *)src {
  NSRegularExpression *header = KKDirectiveHeaderRE();
  NSCharacterSet *ws = NSCharacterSet.whitespaceCharacterSet;
  __block BOOL inBlock =
      NO; // inside an open `@block` (its `key = value` lines)
  [src enumerateSubstringsInRange:NSMakeRange(0, src.length)
                          options:NSStringEnumerationByLines
                       usingBlock:^(NSString *line, NSRange lineRange,
                                    NSRange enclosing, BOOL *stop) {
                         NSRange slashes = [line rangeOfString:@"//"];
                         if (slashes.location == NSNotFound) {
                           inBlock =
                               NO; // a non-comment line closes any open block
                           return;
                         }
                         NSTextCheckingResult *h = [header
                             firstMatchInString:line
                                        options:0
                                          range:NSMakeRange(0, line.length)];
                         if (h) {
                           NSRange tok = [h rangeAtIndex:1];
                           NSString *token = [line substringWithRange:tok];
                           [ts addAttribute:NSForegroundColorAttributeName
                                      value:KKCodeDirective() // green: a
                                                              // directive, not
                                                              // a code keyword
                                      range:NSMakeRange(lineRange.location +
                                                            tok.location,
                                                        tok.length)];
                           // `@block` opens a multi-line block (its indented
                           // `key = value` fields); a `#kind` directive is
                           // single-line.
                           inBlock = [token hasPrefix:@"@"];
                           NSUInteger bodyStart = NSMaxRange(tok);
                           [self
                               _colorDirectiveBodyRange:NSMakeRange(
                                                            lineRange.location +
                                                                bodyStart,
                                                            line.length -
                                                                bodyStart)
                                              inStorage:ts
                                                 source:src];
                           return;
                         }
                         if (!inBlock)
                           return;
                         // A block continuation line: the comment body after
                         // `//`. A blank comment (or `}`) ends the block;
                         // otherwise colour its key = value.
                         NSUInteger bs = NSMaxRange(slashes);
                         NSString *body = [[line substringFromIndex:bs]
                             stringByTrimmingCharactersInSet:ws];
                         if (body.length == 0 || [body isEqualToString:@"}"]) {
                           inBlock = NO;
                           return;
                         }
                         [self _colorDirectiveBodyRange:NSMakeRange(
                                                            lineRange.location +
                                                                bs,
                                                            line.length - bs)
                                              inStorage:ts
                                                 source:src];
                       }];
}

- (void)textStorage:(NSTextStorage *)textStorage
    didProcessEditing:(NSTextStorageEditActions)editedMask
                range:(NSRange)editedRange
       changeInLength:(NSInteger)delta {
  // Only character edits change tokens (our own colour writes are attribute
  // edits). Coalesce and defer so we don't mutate attributes mid-processing.
  if (!(editedMask & NSTextStorageEditedCharacters) || _highlightScheduled)
    return;
  _highlightScheduled = YES;
  __weak typeof(self) weak = self;
  dispatch_async(dispatch_get_main_queue(), ^{
    __strong typeof(weak) s = weak;
    if (!s)
      return;
    s->_highlightScheduled = NO;
    [s _applyHighlighting];
  });
}

// While the autocomplete list is open, arrows navigate it, Return/Tab accept,
// and a caret move dismisses it. Otherwise Escape drops focus (like a value
// field) and everything else falls through to the default multi-line editing.
// (Covers the routing where these arrive as commands rather than key
// equivalents.)
- (BOOL)textView:(NSTextView *)textView
    doCommandBySelector:(SEL)commandSelector {
  if (_completion.superview) {
    if (commandSelector == @selector(moveDown:))
      return [self _moveCompletionBy:1];
    if (commandSelector == @selector(moveUp:))
      return [self _moveCompletionBy:-1];
    if (commandSelector == @selector(insertNewline:) ||
        commandSelector == @selector(insertTab:))
      return [self _acceptCompletion];
    if (commandSelector == @selector(cancelOperation:)) {
      [self _hideCompletion];
      return YES;
    }
    if (commandSelector == @selector(moveLeft:) ||
        commandSelector == @selector(moveRight:) ||
        commandSelector == @selector(moveToBeginningOfLine:) ||
        commandSelector == @selector(moveToEndOfLine:) ||
        commandSelector == @selector(deleteBackward:))
      [self _hideCompletion]; // then fall through to perform the edit
  }
  if (commandSelector == @selector(cancelOperation:)) {
    [textView.window makeFirstResponder:nil];
    return YES;
  }
  return NO;
}

// The identifier prefix under the caret (empty selection), or a not-found
// range.
- (NSRange)_completionWordRange {
  NSRange sel = _textView.selectedRange;
  if (sel.length > 0)
    return NSMakeRange(NSNotFound, 0);
  NSString *s = _textView.string;
  NSUInteger caret = sel.location;
  static NSCharacterSet *idSet;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    idSet = [NSCharacterSet
        characterSetWithCharactersInString:
            @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_"];
  });
  NSUInteger start = caret;
  while (start > 0 && [idSet characterIsMember:[s characterAtIndex:start - 1]])
    start--;
  if (start == caret)
    return NSMakeRange(NSNotFound, 0);
  unichar first = [s characterAtIndex:start];
  if (first >= '0' && first <= '9') // a numeric literal, not an identifier
    return NSMakeRange(NSNotFound, 0);
  return NSMakeRange(start, caret - start);
}

static BOOL KKIsExprIdentChar(unichar c) {
  return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') ||
         (c >= '0' && c <= '9') || c == '_';
}

// Vector-swizzle completions for an expression `value` / `${ref}` / call
// result, filtered by the partial after the dot. Generic (no component count) -
// the user picks the ones their vector actually has.
static NSArray<NSDictionary<NSString *, NSString *> *> *
KKSwizzleCompletionItems(NSString *prefix) {
  static NSArray *all;
  static dispatch_once_t once;
  dispatch_once(&once, ^{
    NSDictionary * (^S)(NSString *, NSString *) = ^(NSString *n, NSString *d) {
      return @{
        @"name" : n,
        @"signature" : n,
        @"desc" : KKLoc(d, @"Code editor: help for a vector swizzle "
                           @"component (.x / .rgba …)."),
        @"insert" : n
      };
    };
    all = @[
      S(@"x", @"1st component (or red)."),
      S(@"y", @"2nd component (or green)."),
      S(@"z", @"3rd component (or blue)."),
      S(@"w", @"4th component (or alpha)."), S(@"r", @"Red (1st component)."),
      S(@"g", @"Green (2nd component)."), S(@"b", @"Blue (3rd component)."),
      S(@"a", @"Alpha (4th component)."),
      S(@"xy", @"The first two components."),
      S(@"xyz", @"The first three components."),
      S(@"xyzw", @"All four components."), S(@"rgb", @"Red, green, blue."),
      S(@"rgba", @"Red, green, blue, alpha.")
    ];
  });
  if (prefix.length == 0)
    return all;
  NSMutableArray *out = [NSMutableArray array];
  for (NSDictionary<NSString *, NSString *> *e in all)
    if ([e[@"name"] rangeOfString:prefix
                          options:NSCaseInsensitiveSearch | NSAnchoredSearch]
            .location == 0)
      [out addObject:e];
  if (out.count == 1 &&
      [out[0][@"name"] caseInsensitiveCompare:prefix] == NSOrderedSame)
    return @[];
  return out;
}

// Recompute the autocomplete list from the word under the caret. Expression
// syntax only, only while the editor is focused. Hides when nothing matches (or
// the only match is already fully typed).
- (void)_updateCompletions {
  if (self.window.firstResponder != _textView) {
    [self _hideCompletion];
    return;
  }
  // GLSL mode with a host provider: it owns the vocabulary + context (a
  // shader's `//` directives, GLSL builtins, declared uniforms) and returns the
  // filtered items + the range the pick replaces. Only fires when the caret has
  // no selection (a live word/context, like the expression path).
  if (_syntax == KKCodeSyntaxGLSL && self.completionProvider) {
    if (_textView.selectedRange.length > 0) {
      [self _hideCompletion];
      return;
    }
    NSRange replace = NSMakeRange(NSNotFound, 0);
    NSArray<NSDictionary<NSString *, NSString *> *> *items =
        self.completionProvider(_textView.string,
                                _textView.selectedRange.location, &replace);
    if (items.count == 0 || replace.location == NSNotFound) {
      [self _hideCompletion];
      return;
    }
    _completionWord = replace;
    _completionItems = items;
    if (_completionIndex >= (NSInteger)items.count)
      _completionIndex = 0;
    [self _showCompletion];
    return;
  }
  if (_syntax != KKCodeSyntaxExpression) {
    [self _hideCompletion];
    return;
  }
  // Vector swizzle: a `.` right after a value / `${ref}` / `)` offers the
  // component accessors (`.x`, `.rgba`, …). Handled before the word lookup so
  // an empty partial (`value.`) still shows the list.
  if (_textView.selectedRange.length == 0) {
    NSString *src = _textView.string;
    NSUInteger caret = _textView.selectedRange.location;
    NSUInteger sw = caret;
    while (sw > 0 && KKIsExprIdentChar([src characterAtIndex:sw - 1]))
      sw--;
    if (sw > 0 && [src characterAtIndex:sw - 1] == '.') {
      unichar b = sw >= 2 ? [src characterAtIndex:sw - 2] : 0;
      if (KKIsExprIdentChar(b) || b == ')' || b == '}') {
        NSArray *items = KKSwizzleCompletionItems(
            [src substringWithRange:NSMakeRange(sw, caret - sw)]);
        if (items.count) {
          _completionWord = NSMakeRange(sw, caret - sw);
          _completionItems = items;
          if (_completionIndex >= (NSInteger)items.count)
            _completionIndex = 0;
          [self _showCompletion];
        } else {
          [self _hideCompletion];
        }
        return;
      }
    }
  }
  NSRange word = [self _completionWordRange];
  if (word.location == NSNotFound) {
    [self _hideCompletion];
    return;
  }
  NSString *prefix = [_textView.string substringWithRange:word];
  NSMutableArray *matches = [NSMutableArray array];
  for (NSDictionary<NSString *, NSString *> *e in KKExprCatalog())
    if ([e[@"name"] rangeOfString:prefix
                          options:NSCaseInsensitiveSearch | NSAnchoredSearch]
            .location == 0)
      [matches addObject:e];
  if (matches.count == 0 ||
      (matches.count == 1 &&
       [matches[0][@"name"] caseInsensitiveCompare:prefix] == NSOrderedSame)) {
    [self _hideCompletion];
    return;
  }
  _completionWord = word;
  _completionItems = matches;
  if (_completionIndex >= (NSInteger)matches.count)
    _completionIndex = 0;
  [self _showCompletion];
}

// Position the overlay just under the caret in the window's content view (not a
// child of the clipped editor), so it can extend past the one-line editor.
// Flips above the caret when it would fall off the bottom.
- (void)_showCompletion {
  NSView *content = self.window.contentView;
  if (!content) {
    [self _hideCompletion];
    return;
  }
  if (!_completion) {
    _completion = [[_KKExprCompletionView alloc] initWithFrame:NSZeroRect];
    __weak typeof(self) weak = self;
    _completion.onPick = ^(NSInteger index) {
      __strong typeof(weak) s = weak;
      if (!s)
        return;
      s->_completionIndex = index;
      [s _acceptCompletion];
    };
  }
  _completion.items = _completionItems;
  _completion.selectedIndex = _completionIndex;

  // Caret rect -> content-view coords (handles the content view's flippedness),
  // then place the list just UNDER the text line, flipping above only if it
  // would fall off the bottom edge.
  NSRect caretScreen = [_textView
      firstRectForCharacterRange:NSMakeRange(_completionWord.location, 0)
                     actualRange:NULL];
  NSRect caret =
      [content convertRect:[self.window convertRectFromScreen:caretScreen]
                  fromView:nil];
  CGFloat w = kKKComplWidth;
  CGFloat h = [_completion fittingHeight];
  CGFloat gap = 4.0;
  CGFloat x = caret.origin.x - 6.0;
  CGFloat
      y; // one line below the caret, in whichever vertical direction is "down"
  if (content.isFlipped) {
    y = NSMaxY(caret) + gap;
    if (y + h > NSMaxY(content.bounds) - 4.0)
      y = caret.origin.y - gap - h;
  } else {
    y = caret.origin.y - gap - h;
    if (y < 4.0)
      y = NSMaxY(caret) + gap;
  }
  if (x + w > NSMaxX(content.bounds) - 4.0)
    x = NSMaxX(content.bounds) - 4.0 - w;
  if (x < 4.0)
    x = 4.0;
  _completion.frame = NSMakeRect(x, y, w, h);
  if (_completion.superview != content)
    [content addSubview:_completion positioned:NSWindowAbove relativeTo:nil];
  [_completion setNeedsDisplay:YES];
}

- (void)_hideCompletion {
  [_completion removeFromSuperview];
  _completionItems = nil;
  _completionIndex = 0;
  _completionWord = NSMakeRange(NSNotFound, 0);
}

- (BOOL)_moveCompletionBy:(NSInteger)delta {
  NSInteger n = (NSInteger)_completionItems.count;
  if (n == 0)
    return NO;
  _completionIndex = (_completionIndex + delta + n) % n;
  _completion.selectedIndex = _completionIndex;
  return YES;
}

- (BOOL)_acceptCompletion {
  if (_completionWord.location == NSNotFound ||
      _completionIndex >= (NSInteger)_completionItems.count)
    return NO;
  NSString *insert = _completionItems[_completionIndex][@"insert"];
  NSRange r = _completionWord;
  [self _hideCompletion];
  if (![_textView shouldChangeTextInRange:r replacementString:insert])
    return YES;
  [_textView replaceCharactersInRange:r withString:insert];
  [_textView setSelectedRange:NSMakeRange(r.location + insert.length, 0)];
  [_textView didChangeText]; // commits through the debounce like typed text
  return YES;
}

// Blur (click-away / Esc) closes the autocomplete list.
- (void)textDidEndEditing:(NSNotification *)notification {
  [self _hideCompletion];
}

// The overlay lives in the window's content view, so drop it when the editor
// leaves that window (popover close / row rebuild) or it would be orphaned.
- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
  [super viewWillMoveToWindow:newWindow];
  if (newWindow != self.window)
    [self _hideCompletion];
}

// Debounce so consumers recompile on a pause, not on every keystroke.
- (void)textDidChange:(NSNotification *)notification {
  [self _updateCompletions]; // live, not debounced - it tracks the caret word
  [_debounce invalidate];
  __weak typeof(self) weak = self;
  _debounce = [NSTimer
      scheduledTimerWithTimeInterval:0.4
                             repeats:NO
                               block:^(NSTimer *t) {
                                 __strong typeof(weak) s = weak;
                                 if (!s)
                                   return;
                                 s->_sectionCodes[s->_activeTab] =
                                     [s->_textView.string copy];
                                 [s _runValidator];
                                 if (s.onChange)
                                   s.onChange(s->_textView.string);
                                 if (s.onSectionsChange)
                                   s.onSectionsChange([s sections]);
                                 // This burst is now a durable timeline
                                 // state captured by the host's (FCP)
                                 // undo; drop the local text-view undo
                                 // for it so Cmd-Z doesn't walk the whole
                                 // typing history before reaching a
                                 // lane/OSC edit made after the commit.
                                 [s->_textView.undoManager removeAllActions];
                               }];
}

@end
