//
//  KKNumberField.m
//  KeyframelessKit
//
//  Created by Dom on 28/02/2026.
//

#import "KKNumberField.h"
#import "KKFocusRingOverlay.h"
#import "KKNumberField+Private.h"
#import "KKNumberFieldGeometry.h"
#import "KKNumberFieldInputValidator.h"
#import "KKNumberFieldTextView.h"
#import <QuartzCore/QuartzCore.h>

// Layout
static const CGFloat KKNumberFieldFontSize = 11.0;
static const CGFloat KKNumberFieldHInset = 3.0;
static const CGFloat KKNumberFieldTextInset = 3.5;
static const CGFloat KKNumberFieldVerticalInsetBias = 2.0; // nudge to optically centre text
static const CGFloat KKNumberFieldDefaultValue = 20.0;
static const CGFloat KKNumberFieldInputWidth = 57.0; // width of the editable field area
static const CGFloat KKNumberFieldLabelGap = 1.0;    // gap between label and field edge

// Reduced padding used after animate-in completes — just enough to show the ring stroke
// without the panel's large footprint blocking sibling controls.
static const CGFloat KKFocusRingPostAnimPadding = 3.0;

@interface KKNumberField ()
@property (nonatomic, strong) NSTextView *textView;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, strong) KKFocusRingOverlay *focusRingOverlay;
@property (nonatomic, strong) NSPanel *focusRingPanel;
@property (nonatomic, readwrite) BOOL isEditing;
@property (nonatomic, strong) KKNumberFieldInputValidator *inputValidator;
- (NSRect)fieldRect;
- (void)updateTextAlignment;
- (void)setupFocusRingOverlay;
- (void)updateFocusRingOverlayFrame;
- (NSColor *)focusRingColor;
- (NSColor *)selectionColor;
- (void)drawPrefixAndSuffix;
@end

@implementation KKNumberField

- (instancetype)initWithFrame:(NSRect)frame apiManager:(id<PROAPIAccessing>)apiManager {
    self = [super initWithFrame:frame];
    if (self) {
        self.apiManager = apiManager;
        _backgroundColor = [NSColor clearColor];
        _doubleValue = KKNumberFieldDefaultValue;
        _minValue = -INFINITY;
        _maxValue = INFINITY;
        self.wantsLayer = YES;
        self.layer.masksToBounds = NO;
        _inputValidator = [[KKNumberFieldInputValidator alloc] init];
        [self setupTextView];
        [self setupFocusRingOverlay];
    }
    return self;
}

- (void)setupTextView {
    [self configureScrollView];

    KKNumberFieldTextView *textView = [self createTextView];
    [self configureTextViewSizing:textView];
    textView.string = [self displayStringForValue:_doubleValue];

    self.textView = textView;
    self.scrollView.documentView = textView;
    [self addSubview:self.scrollView];

    // Ensure layout is correct before first display (prevents a shift on first keystroke).
    [textView.layoutManager ensureLayoutForTextContainer:textView.textContainer];
    [textView setNeedsDisplay:YES];

    [self updateTextAlignment];
}

- (void)setupFocusRingOverlay {
    self.focusRingOverlay = [[KKFocusRingOverlay alloc] initWithColor:[self focusRingColor]];

    // Independent floating panel — not a child window so it works in FxPlug embedding.
    // Shown/hidden explicitly in beginEditing / textDidEndEditing.
    NSPanel *panel =
        [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 1, 1)
                                   styleMask:NSWindowStyleMaskBorderless | NSWindowStyleMaskNonactivatingPanel
                                     backing:NSBackingStoreBuffered
                                       defer:NO];
    panel.backgroundColor = [NSColor clearColor];
    panel.opaque = NO;
    panel.hasShadow = NO;
    panel.ignoresMouseEvents = YES;
    panel.hidesOnDeactivate = NO;
    panel.contentView = self.focusRingOverlay;
    self.focusRingPanel = panel;
}

- (void)viewDidMoveToWindow {
    [super viewDidMoveToWindow];
    if (!self.window) {
        [self.focusRingPanel orderOut:nil];
    }
}

- (void)updateFocusRingOverlayFrameWithPadding:(CGFloat)padding {
    if (!self.window)
        return;
    NSRect frameInWindow = [self convertRect:self.bounds toView:nil];
    NSRect frameOnScreen = [self.window convertRectToScreen:frameInWindow];
    frameOnScreen = NSInsetRect(frameOnScreen, -padding, -padding);
    [self.focusRingOverlay setPanelPadding:padding];
    [self.focusRingPanel setFrame:frameOnScreen display:NO];
}

- (void)updateFocusRingOverlayFrame {
    [self updateFocusRingOverlayFrameWithPadding:KKFocusRingPanelPadding];
}

- (void)beginEditing {
    if (self.isFocused)
        return;
    self.textView.editable = YES;
    self.textView.selectable = YES;
    self.isFocused = YES;
    self.isEditing = YES;
    self.textView.string = [self displayStringForEditing];
    [self updateTextAlignment];
    // Restore full padding so the animate-in has room for the expanding ring.
    [self updateFocusRingOverlayFrame];
    // Attach as a child window so it always stays above the parent regardless of
    // what the FxPlug host does with window ordering (hover effects, etc).
    if (self.window && !self.focusRingPanel.parentWindow) {
        [self.window addChildWindow:self.focusRingPanel ordered:NSWindowAbove];
    }
    [self.focusRingPanel orderFront:nil];
    // Re-assert after ordering — addChildWindow: can reset ignoresMouseEvents on some macOS versions.
    self.focusRingPanel.ignoresMouseEvents = YES;
    [self.focusRingOverlay animateIn];
    [self setNeedsDisplay:YES];

    // After the animate-in finishes, shrink the panel to just the ring's visual bounds
    // so the padded area stops blocking sibling controls.
    __weak typeof(self) weak = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        __strong typeof(self) strong = weak;
        if (!strong || !strong.isFocused)
            return;
        [strong updateFocusRingOverlayFrameWithPadding:KKFocusRingPostAnimPadding];
    });
}

/// The rect occupied by the input field itself, excluding prefix and suffix label zones.
- (NSRect)fieldRect {
    return NSMakeRect(KKNumberFieldPrefixWidth, 0,
                      NSWidth(self.bounds) - KKNumberFieldPrefixWidth - KKNumberFieldSuffixWidth,
                      NSHeight(self.bounds));
}

- (void)configureScrollView {
    // Only inset on the left of the field rect; right edge extends to the field boundary so
    // right padding is controlled solely by KKNumberFieldTextInset inside the text container.
    NSRect fr = [self fieldRect];
    NSRect frame = NSMakeRect(NSMinX(fr) + KKNumberFieldHInset, 0, NSWidth(fr) - KKNumberFieldHInset, NSHeight(fr));
    self.scrollView = [[NSScrollView alloc] initWithFrame:frame];
    self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.scrollView.hasVerticalScroller = NO;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.borderType = NSNoBorder;
    self.scrollView.drawsBackground = NO;
}

- (KKNumberFieldTextView *)createTextView {
    KKNumberFieldTextView *textView = [[KKNumberFieldTextView alloc] initWithFrame:self.scrollView.bounds];
    textView.parentField = self;
    textView.delegate = self;
    textView.drawsBackground = NO;
    textView.textColor = [NSColor labelColor];
    textView.font = [self fieldFont];
    textView.alignment = NSTextAlignmentLeft;
    textView.selectedTextAttributes = @{NSBackgroundColorAttributeName : [self selectionColor]};
    textView.textContainer.lineFragmentPadding = 0;
    textView.autoresizingMask = NSViewHeightSizable;
    textView.fieldEditor = YES;
    textView.editable = NO;
    textView.selectable = NO;
    return textView;
}

- (void)configureTextViewSizing:(NSTextView *)textView {
    textView.textContainer.containerSize = NSMakeSize(CGFLOAT_MAX, NSHeight(self.bounds));
    textView.textContainer.widthTracksTextView = NO;
    textView.horizontallyResizable = YES;
    textView.verticallyResizable = NO;
    textView.maxSize = NSMakeSize(CGFLOAT_MAX, NSHeight(self.bounds));
    textView.textContainerInset = NSMakeSize(KKNumberFieldTextInset, [self verticalTextInset]);
}

+ (CGFloat)preferredWidth {
    return KKNumberFieldPrefixWidth + KKNumberFieldInputWidth + KKNumberFieldSuffixWidth;
}

- (NSSize)intrinsicContentSize {
    return NSMakeSize(KKNumberFieldPrefixWidth + KKNumberFieldInputWidth + KKNumberFieldSuffixWidth,
                      NSViewNoIntrinsicMetric);
}

- (NSFont *)fieldFont {
    return [NSFont systemFontOfSize:KKNumberFieldFontSize];
}

- (void)updateTextAlignment {
    NSDictionary *attrs = @{NSFontAttributeName : [self fieldFont]};
    NSSize textSize = [self.textView.string sizeWithAttributes:attrs];

    NSRect fr = [self fieldRect];
    CGFloat availableWidth = NSWidth(fr) - KKNumberFieldHInset - (KKNumberFieldTextInset * 2);
    CGFloat offset = MAX(0, availableWidth - textSize.width);

    NSRect scrollFrame = self.scrollView.frame;
    scrollFrame.origin.x = NSMinX(fr) + KKNumberFieldHInset + offset;
    // Pin right edge to NSMaxX(fr) so the scroll view never overlaps the suffix zone.
    scrollFrame.size.width = NSMaxX(fr) - scrollFrame.origin.x;
    self.scrollView.frame = scrollFrame;
}

- (CGFloat)verticalTextInset {
    NSDictionary *attrs = @{NSFontAttributeName : [self fieldFont]};
    NSSize textSize = [@"0" sizeWithAttributes:attrs];
    return floor((NSHeight(self.bounds) - textSize.height) / 2.0) + KKNumberFieldVerticalInsetBias;
}

- (double)parsedValueFromString:(NSString *)string {
    if (string.length == 0)
        return 0.0;
    if ([string isEqualToString:@"-"] || [string isEqualToString:@"."] || [string isEqualToString:@"-."])
        return 0.0;
    return [string doubleValue];
}

- (double)clampedValue:(double)value {
    if (value < self.minValue)
        return self.minValue;
    if (value > self.maxValue)
        return self.maxValue;
    return value;
}

/// Formats the value for display (not editing) — always 1 decimal place.
- (NSString *)displayStringForValue:(double)value {
    return [NSString stringWithFormat:@"%.1f", value];
}

/// Formats the current value for editing — full precision for non-integers.
- (NSString *)displayStringForEditing {
    if (_doubleValue == floor(_doubleValue)) {
        return [NSString stringWithFormat:@"%.1f", _doubleValue];
    }
    return [NSString stringWithFormat:@"%g", _doubleValue];
}

- (NSColor *)focusRingColor {
    return [NSColor colorWithRed:0x28 / 255.0 green:0x47 / 255.0 blue:0x77 / 255.0 alpha:1.0];
}

- (NSColor *)selectionColor {
    return [NSColor colorWithRed:0x59 / 255.0 green:0x59 / 255.0 blue:0xE1 / 255.0 alpha:1.0];
}

- (BOOL)acceptsFirstResponder {
    return YES;
}

- (BOOL)becomeFirstResponder {
    return YES;
}

- (BOOL)resignFirstResponder {
    return YES;
}

- (void)mouseDown:(NSEvent *)event {
    [self beginEditing];
    [self.window makeFirstResponder:self.textView];
}

- (void)textDidChange:(NSNotification *)notification {
    [self updateTextAlignment];
}

- (void)textDidBeginEditing:(NSNotification *)notification {
    [self beginEditing];
}

- (void)textDidEndEditing:(NSNotification *)notification {
    self.isFocused = NO;
    self.isEditing = NO;
    [self.focusRingOverlay hide];
    if (self.focusRingPanel.parentWindow) {
        [self.focusRingPanel.parentWindow removeChildWindow:self.focusRingPanel];
    }
    [self.focusRingPanel orderOut:nil];
    _doubleValue = [self clampedValue:[self parsedValueFromString:self.textView.string]];
    self.textView.string = [self displayStringForValue:_doubleValue];
    [self updateTextAlignment];
    self.textView.editable = NO;
    self.textView.selectable = NO;
    [self setNeedsDisplay:YES];
}

- (BOOL)textView:(NSTextView *)textView
    shouldChangeTextInRange:(NSRange)affectedCharRange
          replacementString:(NSString *)replacementString {
    return [self.inputValidator isValidReplacementString:replacementString
                                                 inRange:affectedCharRange
                                                ofString:textView.string
                                                minValue:self.minValue
                                                maxValue:self.maxValue];
}

- (void)drawRect:(NSRect)dirtyRect {
    [self drawBackground];
    [self drawPrefixAndSuffix];
}

- (void)drawPrefixAndSuffix {
    NSDictionary *attrs = @{
        NSFontAttributeName : [self fieldFont],
        NSForegroundColorAttributeName : [NSColor colorWithRed:0xB3 / 255.0
                                                         green:0xB3 / 255.0
                                                          blue:0xB3 / 255.0
                                                         alpha:1.0]
    };

    if (self.prefix.length > 0) {
        NSString *text = [self.prefix substringToIndex:1];
        NSSize sz = [text sizeWithAttributes:attrs];
        CGFloat x = KKNumberFieldPrefixWidth - sz.width - KKNumberFieldLabelGap;
        CGFloat y = (NSHeight(self.bounds) - sz.height) / 2.0;
        [text drawAtPoint:NSMakePoint(x, y) withAttributes:attrs];
    }

    if (self.suffix.length > 0) {
        NSString *text = self.suffix.length > 2 ? [self.suffix substringToIndex:2] : self.suffix;
        NSSize sz = [text sizeWithAttributes:attrs];
        CGFloat x = NSMaxX([self fieldRect]) + KKNumberFieldLabelGap;
        CGFloat y = (NSHeight(self.bounds) - sz.height) / 2.0;
        [text drawAtPoint:NSMakePoint(x, y) withAttributes:attrs];
    }
}

- (void)drawBackground {
    [self.backgroundColor setFill];
    NSRectFill([self fieldRect]);
}

- (void)setBackgroundColor:(NSColor *)backgroundColor {
    _backgroundColor = backgroundColor;
    [self setNeedsDisplay:YES];
}

- (void)setPrefix:(NSString *)prefix {
    _prefix = [prefix copy];
    [self setNeedsDisplay:YES];
}

- (void)setSuffix:(NSString *)suffix {
    _suffix = [suffix copy];
    [self setNeedsDisplay:YES];
}

@end
