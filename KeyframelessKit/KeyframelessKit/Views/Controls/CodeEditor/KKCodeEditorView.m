/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#import "KKCodeEditorView.h"
#import "KKChoiceChecklistView.h"
#import "KKCodeEditorSubviews.h" // lifted helper views (_KKCodeTextView, ...)
#import "KKCodeEditorView_Private.h" // @package ivars shared with the categories
#import "KKCodeGrammar.h"
#import "KKCodeGutterView.h"
#import "KKFieldEditorSupport.h"
#import "KKGLSLSyntax.h"
#import "KKLinkExpr.h" // expression error range for the red squiggle
#import "KKLocalized.h"
#import "KKPopoverKeepAlive.h"
#import "KKTimeline.h" // KKCodeEditorSave* notification constant declarations
#import "KKTimelineLanesView_Private.h" // _KKDropdownTrigger, _KKLVPopoverContentView
#import "KKTokens.h"
#import "NSColor+KKColors.h"
#import <QuartzCore/QuartzCore.h>

NSNotificationName const KKCodeEditorSaveRequestedNotification =
    @"KKCodeEditorSaveRequestedNotification";
NSString *const KKCodeEditorSaveNameKey = @"name";
NSString *const KKCodeEditorSaveSectionsKey = @"sections";
NSString *const KKCodeEditorSaveCategoryIndexKey = @"categoryIndex";

NSNotificationName const KKCodeEditorReloadNotification =
    @"KKCodeEditorReloadNotification";

@implementation KKCodeEditorView
@synthesize codeValidator = _codeValidator;
@synthesize codeFormatter = _codeFormatter;
// Accessors live in +SaveBar (backed by the name field's placeholderString,
// resetting to a default on nil) - @dynamic stops the primary from
// auto-synthesizing a nil-unaware setter for this null_resettable property.
@dynamic saveNamePlaceholder;

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

- (void)viewWillMoveToWindow:(NSWindow *)newWindow {
  [super viewWillMoveToWindow:newWindow];
  // Leaving the window (an inspector rebuild after a directive change tears
  // the editor down): the WINDOW's undo manager still holds text-change
  // entries targeting our text storage, and NSUndoManager does not retain
  // targets - a later Cmd-Z would objc_msgSend a dangling pointer (the
  // fresh-paste -> rebuild -> Cmd-Z ViewBridge crash). Clear now, while the
  // responder chain still reaches that undo manager; after detach
  // `_textView.undoManager` resolves to nil and the clears in the commit path
  // silently no-op.
  if (!newWindow && self.window)
    [_textView.undoManager removeAllActions];
  // The autocomplete overlay lives in the WINDOW's content view, so drop it
  // when the editor leaves that window (popover close / row rebuild) or it
  // would be orphaned. (Kept here, not in the Autocomplete category - a
  // category override would REPLACE this method and kill the undo clear.)
  if (newWindow != self.window)
    [self _hideCompletion];
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

- (void)setSavable:(BOOL)savable {
  _savable = savable;
  _saveBar.hidden = !savable;
  _saveBarHeight.constant = savable ? 34.0 : 0.0;
}

- (void)_reloadRequested:(NSNotification *)note {
  if (!_savable) // only the shader (savable) editor responds
    return;
  NSArray<NSDictionary<NSString *, NSString *> *> *sections =
      note.userInfo[KKCodeEditorSaveSectionsKey];
  if (sections.count)
    [self setSections:sections];
}

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
