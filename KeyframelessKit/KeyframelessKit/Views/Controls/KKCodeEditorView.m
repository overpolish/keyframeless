/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKCodeEditorView.h"
#import "KKChoiceChecklistView.h"
#import "KKCodeGutterView.h"
#import "KKFieldEditorSupport.h"
#import "KKGLSLSyntax.h"
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

@interface KKCodeEditorView () <NSTextViewDelegate, NSTextStorageDelegate,
                                NSTextFieldDelegate, NSPopoverDelegate>
@end

@implementation KKCodeEditorView {
  NSTextView *_textView;
  NSTimer *_debounce;
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
  NSView *_saveBar;     // optional name + Save strip (height toggled 0/on)
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
    // One implicit "Image" section until a host sets more (keeps the plain
    // single-editor behaviour + tab strip collapsed).
    _sectionNames = [@[ @"Image" ] mutableCopy];
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
    _saveNameField.placeholderString =
        KKLoc(@"Shader name", @"Save-shader name field placeholder.");
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
      [_errorBar.bottomAnchor constraintEqualToAnchor:_saveBar.topAnchor],
      _errorBarHeight,
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
    if (i > 0) // Image (0) is permanent; added tabs get a close button
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
  if (!_codeFormatter)
    return;
  NSString *current = [_textView.string copy];
  NSString *formatted = _codeFormatter(current);
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
  // Insert keeping catalog order among the extra tabs (Image stays first).
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
    return; // never remove the first (Image) tab
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
  // Multi-pass: validate the tab WITH the Common section prepended (so shared
  // decls resolve), mirroring the render. The Common tab itself is validated
  // with a dummy entry point so its own syntax is still checked. `prependLines`
  // maps a reported error back to this tab; an error inside Common is
  // suppressed here (it surfaces on the Common tab).
  NSString *code = _textView.string;
  NSInteger prependLines = 0;
  NSString *activeName = (_activeTab < (NSInteger)_sectionNames.count)
                             ? _sectionNames[_activeTab]
                             : @"";
  NSUInteger ci = [_sectionNames indexOfObject:@"Common"];
  NSString *commonCode = (ci != NSNotFound) ? _sectionCodes[ci] : nil;
  if ([activeName isEqualToString:@"Common"]) {
    code = [code stringByAppendingString:
                     @"\nvoid mainImage(out vec4 kkO, in vec2 kkC){ kkO = "
                     @"vec4(0.0); }\n"];
  } else if (commonCode.length) {
    prependLines =
        (NSInteger)[commonCode componentsSeparatedByString:@"\n"].count;
    code = [NSString stringWithFormat:@"%@\n%@", commonCode, code];
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
  _errorLine = err.length ? line : 0;
  if (err.length) {
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
  _errorCopyButton.hidden = (err.length == 0);
  [self _errorScrolled]; // refresh overflow fades for the new message width
  _lineGutter.errorLine = _errorLine;
  [self _applyHighlighting]; // repaint the flagged-line background
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

- (void)setSavable:(BOOL)savable {
  _savable = savable;
  _saveBar.hidden = !savable;
  _saveBarHeight.constant = savable ? 34.0 : 0.0;
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
