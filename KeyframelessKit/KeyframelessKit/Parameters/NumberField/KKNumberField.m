//
//  KKNumberField.m
//  KeyframelessKit
//
//  Created by Dom on 28/02/2026.
//

#import "KKNumberField.h"

// Layout
static const CGFloat KKNumberFieldFontSize          = 11.0;
static const CGFloat KKNumberFieldHInset            = 3.0;
static const CGFloat KKNumberFieldTextInset         = 3.5;
static const CGFloat KKNumberFieldVerticalInsetBias = 1.0;  // nudge to optically centre text
static const CGFloat KKNumberFieldDefaultValue      = 20.0;

// Focus ring
static const CGFloat KKNumberFieldFocusInset        = 1.0;
static const CGFloat KKNumberFieldFocusCornerRadius = 2.0;
static const CGFloat KKNumberFieldFocusLineWidth    = 3.5;
static const CGFloat KKNumberFieldGlowInset         = 2.0;
static const CGFloat KKNumberFieldGlowLineWidth     = 5.5;
static const CGFloat KKNumberFieldGlowAlpha         = 0.2;

// Keys
static const unichar KKKeyEscape = 27;

@interface KKNumberFieldTextView : NSTextView
@property (nonatomic, weak) KKNumberField *parentField;
@end

// Minimal extension declared here so KKNumberFieldTextView can access the members it needs.
@interface KKNumberField ()
@property (nonatomic, readwrite) BOOL isFocused;
/// Right-aligns display text by shifting the scroll view's origin.
- (void)updateTextAlignment;
/// Returns the current value formatted for editing — full precision for non-integers.
- (NSString *)displayStringForEditing;
@end

@implementation KKNumberFieldTextView

- (void)mouseDown:(NSEvent *)event
{
    if (!self.isEditable) {
        self.editable = YES;
        self.selectable = YES;
        self.parentField.isFocused = YES;
        [self.parentField setNeedsDisplay:YES];
        self.string = [self.parentField displayStringForEditing];
        [self.parentField updateTextAlignment];
        [self.window makeFirstResponder:self];
        [super mouseDown:event];
    } else {
        [super mouseDown:event];
    }
}

- (BOOL)performKeyEquivalent:(NSEvent *)event
{
    // Capture arrow keys when editing — without this, arrows control the timeline scrubber.
    if (self.isEditable && event.type == NSEventTypeKeyDown) {
        NSString *chars = event.charactersIgnoringModifiers;
        if (chars.length == 1) {
            unichar c = [chars characterAtIndex:0];
            if (c == NSLeftArrowFunctionKey || c == NSRightArrowFunctionKey
                || c == NSUpArrowFunctionKey || c == NSDownArrowFunctionKey) {
                [self interpretKeyEvents:@[event]];
                return YES;
            } else if (c == KKKeyEscape) {
                self.string = [self.parentField displayStringForEditing];
                [self.window makeFirstResponder:nil];
                return YES;
            }
        }
    }
    return [super performKeyEquivalent:event];
}

@end

@interface KKNumberField ()
@property (nonatomic, strong) NSTextView *textView;
@property (nonatomic, strong) NSScrollView *scrollView;
@property (nonatomic, readwrite) BOOL isEditing;
- (BOOL)isPartialInput:(NSString *)string;
- (NSColor *)focusRingColor;
- (NSColor *)selectionColor;
@end

@implementation KKNumberField

- (instancetype)initWithFrame:(NSRect)frame
                   apiManager:(id<PROAPIAccessing>)apiManager
{
    self = [super initWithFrame:frame];
    if (self) {
        self.apiManager = apiManager;
        _backgroundColor = [NSColor clearColor];
        _doubleValue = KKNumberFieldDefaultValue;
        _minValue = -INFINITY;
        _maxValue = INFINITY;
        [self setupTextView];
    }
    return self;
}

- (void)setupTextView
{
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

- (void)configureScrollView
{
    // Only inset on the left; right edge extends to the field boundary so right padding
    // is controlled solely by KKNumberFieldTextInset inside the text container.
    NSRect frame = NSMakeRect(KKNumberFieldHInset, 0, NSWidth(self.bounds) - KKNumberFieldHInset, NSHeight(self.bounds));
    self.scrollView = [[NSScrollView alloc] initWithFrame:frame];
    self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.scrollView.hasVerticalScroller = NO;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.borderType = NSNoBorder;
    self.scrollView.drawsBackground = NO;
}

- (KKNumberFieldTextView *)createTextView
{
    KKNumberFieldTextView *textView = [[KKNumberFieldTextView alloc] initWithFrame:self.scrollView.bounds];
    textView.parentField = self;
    textView.delegate = self;
    textView.drawsBackground = NO;
    textView.textColor = [NSColor labelColor];
    textView.font = [self fieldFont];
    textView.alignment = NSTextAlignmentLeft;
    textView.selectedTextAttributes = @{
        NSBackgroundColorAttributeName: [self selectionColor]
    };
    textView.textContainer.lineFragmentPadding = 0;
    textView.autoresizingMask = NSViewHeightSizable;
    textView.fieldEditor = YES;
    textView.editable = NO;
    textView.selectable = NO;
    return textView;
}

- (void)configureTextViewSizing:(NSTextView *)textView
{
    textView.textContainer.containerSize = NSMakeSize(CGFLOAT_MAX, NSHeight(self.bounds));
    textView.textContainer.widthTracksTextView = NO;
    textView.horizontallyResizable = YES;
    textView.verticallyResizable = NO;
    textView.maxSize = NSMakeSize(CGFLOAT_MAX, NSHeight(self.bounds));
    textView.textContainerInset = NSMakeSize(KKNumberFieldTextInset, [self verticalTextInset]);
}

- (NSFont *)fieldFont
{
    return [NSFont systemFontOfSize:KKNumberFieldFontSize];
}

- (void)updateTextAlignment
{
    NSDictionary *attrs = @{NSFontAttributeName: [self fieldFont]};
    NSSize textSize = [self.textView.string sizeWithAttributes:attrs];

    CGFloat availableWidth = NSWidth(self.scrollView.bounds) - (KKNumberFieldTextInset * 2);
    CGFloat offset = MAX(0, availableWidth - textSize.width);

    NSRect scrollFrame = self.scrollView.frame;
    scrollFrame.origin.x = KKNumberFieldHInset + offset;
    self.scrollView.frame = scrollFrame;
}

- (CGFloat)verticalTextInset
{
    NSDictionary *attrs = @{NSFontAttributeName: [self fieldFont]};
    NSSize textSize = [@"0" sizeWithAttributes:attrs];
    return floor((NSHeight(self.bounds) - textSize.height) / 2.0) + KKNumberFieldVerticalInsetBias;
}

- (BOOL)isPartialInput:(NSString *)string
{
    return [string isEqualToString:@"-"]
        || [string isEqualToString:@"."]
        || [string isEqualToString:@"-."];
}

- (double)parsedValueFromString:(NSString *)string
{
    if (string.length == 0 || [self isPartialInput:string]) return 0.0;
    return [string doubleValue];
}

- (double)clampedValue:(double)value
{
    if (value < self.minValue) return self.minValue;
    if (value > self.maxValue) return self.maxValue;
    return value;
}

/// Formats the value for display (not editing) — always 1 decimal place.
- (NSString *)displayStringForValue:(double)value
{
    return [NSString stringWithFormat:@"%.1f", value];
}

/// Formats the current value for editing — full precision for non-integers.
- (NSString *)displayStringForEditing
{
    if (_doubleValue == floor(_doubleValue)) {
        return [NSString stringWithFormat:@"%.1f", _doubleValue];
    }
    return [NSString stringWithFormat:@"%g", _doubleValue];
}

- (NSColor *)focusRingColor
{
    return [NSColor colorWithRed:0x28/255.0 green:0x47/255.0 blue:0x77/255.0 alpha:1.0];
}

- (NSColor *)selectionColor
{
    return [NSColor colorWithRed:0x59/255.0 green:0x59/255.0 blue:0xE1/255.0 alpha:1.0];
}

- (BOOL)acceptsFirstResponder { return YES; }
- (BOOL)becomeFirstResponder  { return YES; }
- (BOOL)resignFirstResponder  { return YES; }

- (void)mouseDown:(NSEvent *)event
{
    self.textView.editable = YES;
    self.textView.selectable = YES;
    [self.window makeFirstResponder:self.textView];
}

- (void)textDidChange:(NSNotification *)notification
{
    [self updateTextAlignment];
}

- (void)textDidBeginEditing:(NSNotification *)notification
{
    self.isFocused = YES;
    [self setNeedsDisplay:YES];
}

- (void)textDidEndEditing:(NSNotification *)notification
{
    self.isFocused = NO;
    _doubleValue = [self clampedValue:[self parsedValueFromString:self.textView.string]];
    self.textView.string = [self displayStringForValue:_doubleValue];
    [self updateTextAlignment];
    self.textView.editable = NO;
    self.textView.selectable = NO;
    [self setNeedsDisplay:YES];
}

- (BOOL)textView:(NSTextView *)textView
    shouldChangeTextInRange:(NSRange)affectedCharRange
          replacementString:(NSString *)replacementString
{
    // Allow deletions and clearing.
    if (replacementString.length == 0) return YES;

    NSString *proposedText = [textView.string stringByReplacingCharactersInRange:affectedCharRange
                                                                      withString:replacementString];
    if (proposedText.length == 0) return YES;

    // Only allow numeric input characters.
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789.-"];
    NSCharacterSet *input   = [NSCharacterSet characterSetWithCharactersInString:replacementString];
    if (![allowed isSupersetOfSet:input]) return NO;

    // At most one decimal point.
    if ([[proposedText componentsSeparatedByString:@"."] count] > 2) return NO;

    // Minus sign must be at the start, and only one.
    NSUInteger minusCount = [[proposedText componentsSeparatedByString:@"-"] count] - 1;
    if (minusCount > 1) return NO;
    if (minusCount == 1 && ![proposedText hasPrefix:@"-"]) return NO;

    // Allow valid intermediate states (e.g. "-", ".", "-.").
    if ([self isPartialInput:proposedText]) return YES;

    // Must parse as a complete double.
    NSScanner *scanner = [NSScanner scannerWithString:proposedText];
    double value;
    if (!([scanner scanDouble:&value] && [scanner isAtEnd])) return NO;

    // Enforce bounds.
    if (value < self.minValue || value > self.maxValue) return NO;

    return YES;
}

- (void)drawRect:(NSRect)dirtyRect
{
    [self drawBackground];
    if (self.isFocused) [self drawFocusRing];
}

- (void)drawBackground
{
    [self.backgroundColor setFill];
    NSRectFill(self.bounds);
}

/// Draws the focus ring — a rounded stroke with a soft inner glow.
- (void)drawFocusRing
{
    NSColor *color = [self focusRingColor];
    NSRect focusRect = NSInsetRect(self.bounds, KKNumberFieldFocusInset, KKNumberFieldFocusInset);

    // Main ring
    NSBezierPath *ring = [NSBezierPath bezierPathWithRoundedRect:focusRect
                                                         xRadius:KKNumberFieldFocusCornerRadius
                                                         yRadius:KKNumberFieldFocusCornerRadius];
    ring.lineWidth = KKNumberFieldFocusLineWidth;
    [color setStroke];
    [ring stroke];

    // Inner glow
    NSBezierPath *glow = [NSBezierPath bezierPathWithRect:NSInsetRect(focusRect, KKNumberFieldGlowInset, KKNumberFieldGlowInset)];
    glow.lineWidth = KKNumberFieldGlowLineWidth;
    [[color colorWithAlphaComponent:KKNumberFieldGlowAlpha] setStroke];
    [glow stroke];
}

- (void)setBackgroundColor:(NSColor *)backgroundColor
{
    _backgroundColor = backgroundColor;
    [self setNeedsDisplay:YES];
}

@end
