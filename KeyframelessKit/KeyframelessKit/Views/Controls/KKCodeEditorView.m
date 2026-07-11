/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKCodeEditorView.h"
#import "KKCodeGutterView.h"
#import "KKGLSLSyntax.h"
#import "NSColor+KKColors.h"

// The code editor lives in a nonactivating FxPlug ViewBridge popover where the
// host window stays key, so key events arrive as key EQUIVALENTS, not keyDown -
// exactly why a plain NSTextView's arrows / return / escape leak to the host.
// Mirror KKValueTextField: while we're the first responder, dispatch the
// equivalent to ourselves as a keyDown so it edits the code. Also handle the
// Cmd-A/C/V/X/Z cluster explicitly (a ViewBridge popover has no Edit menu, so
// those equivalents never reach us otherwise).
@interface _KKCodeTextView : NSTextView
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
                                                          r))
                                         [s.window makeFirstResponder:nil];
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
  if (event.keyCode == 53) { // Escape: drop focus, like a value field
    [self.window makeFirstResponder:nil];
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
      [self.undoManager undo];
      return YES;
    }
  } else if (mods == (NSEventModifierFlagCommand | NSEventModifierFlagShift) &&
             [event.charactersIgnoringModifiers.lowercaseString
                 isEqualToString:@"z"]) {
    [self.undoManager redo];
    return YES;
  }
  [self keyDown:event];
  return YES;
}
@end

@interface KKCodeEditorView () <NSTextViewDelegate, NSTextStorageDelegate>
@end

@implementation KKCodeEditorView {
  NSTextView *_textView;
  NSTimer *_debounce;
  BOOL _highlightScheduled;
  KKCodeGutterView *_lineGutter;
  NSTextField *_errorBar;
  NSLayoutConstraint *_errorBarHeight;
  NSInteger _errorLine; // 1-based line to flag, 0 = none
}
@synthesize codeValidator = _codeValidator;

- (instancetype)initWithFrame:(NSRect)frame {
  self = [super initWithFrame:frame];
  if (self) {
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
    // reports a problem, then a one-line red strip with the message.
    _errorBar = [NSTextField labelWithString:@""];
    _errorBar.translatesAutoresizingMaskIntoConstraints = NO;
    _errorBar.font = [NSFont monospacedSystemFontOfSize:8.5
                                                 weight:NSFontWeightMedium];
    _errorBar.textColor = KKCodeError();
    _errorBar.lineBreakMode = NSLineBreakByTruncatingTail;
    _errorBar.maximumNumberOfLines = 1;
    _errorBar.drawsBackground = YES;
    _errorBar.backgroundColor = KKHex(0x2d1214);
    [self addSubview:_errorBar];
    _errorBarHeight = [_errorBar.heightAnchor constraintEqualToConstant:0.0];

    [NSLayoutConstraint activateConstraints:@[
      [_lineGutter.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [_lineGutter.topAnchor constraintEqualToAnchor:self.topAnchor],
      [_lineGutter.bottomAnchor constraintEqualToAnchor:_errorBar.topAnchor],
      [_lineGutter.widthAnchor constraintEqualToConstant:34.0],
      [scroll.leadingAnchor constraintEqualToAnchor:_lineGutter.trailingAnchor],
      [scroll.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [scroll.topAnchor constraintEqualToAnchor:self.topAnchor],
      [scroll.bottomAnchor constraintEqualToAnchor:_errorBar.topAnchor],
      [_errorBar.leadingAnchor constraintEqualToAnchor:self.leadingAnchor],
      [_errorBar.trailingAnchor constraintEqualToAnchor:self.trailingAnchor],
      [_errorBar.bottomAnchor constraintEqualToAnchor:self.bottomAnchor],
      _errorBarHeight,
    ]];
  }
  return self;
}

- (void)_scrollBoundsChanged:(NSNotification *)note {
  [_lineGutter setNeedsDisplay:YES];
}

- (void)dealloc {
  [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (NSString *)codeText {
  return _textView.string;
}

- (void)setCodeText:(NSString *)codeText {
  if ([_textView.string isEqualToString:codeText])
    return;
  _textView.string = codeText ?: @"";
  [self _runValidator];
}

- (void)setCodeValidator:(NSString * (^)(NSString *,
                                         NSInteger *))codeValidator {
  _codeValidator = [codeValidator copy];
  [self _runValidator];
}

// Run the owner's validator over the current text and reflect the result: a
// one-line red bar and a flagged line, or clear both when it's valid / absent.
- (void)_runValidator {
  NSInteger line = 0;
  NSString *err =
      _codeValidator ? _codeValidator(_textView.string, &line) : nil;
  _errorLine = err.length ? line : 0;
  if (err.length) {
    _errorBar.stringValue = [@"  " stringByAppendingString:err];
    _errorBarHeight.constant = 18.0;
  } else {
    _errorBar.stringValue = @"";
    _errorBarHeight.constant = 0.0;
  }
  _lineGutter.errorLine = _errorLine;
  [self _applyHighlighting]; // repaint the flagged-line background
  [_lineGutter setNeedsDisplay:YES];
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
  [ts endEditing];
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

// Escape drops focus (like a value field). Return / arrows fall through to the
// default multi-line editing. Covers the routing where Escape arrives as a
// command rather than a key equivalent.
- (BOOL)textView:(NSTextView *)textView
    doCommandBySelector:(SEL)commandSelector {
  if (commandSelector == @selector(cancelOperation:)) {
    [textView.window makeFirstResponder:nil];
    return YES;
  }
  return NO;
}

// Debounce so consumers recompile on a pause, not on every keystroke.
- (void)textDidChange:(NSNotification *)notification {
  [_debounce invalidate];
  __weak typeof(self) weak = self;
  _debounce =
      [NSTimer scheduledTimerWithTimeInterval:0.4
                                      repeats:NO
                                        block:^(NSTimer *t) {
                                          __strong typeof(weak) s = weak;
                                          if (!s)
                                            return;
                                          [s _runValidator];
                                          if (s.onChange)
                                            s.onChange(s->_textView.string);
                                        }];
}

@end
