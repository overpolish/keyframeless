//
//  KKNumberField.m
//  KeyframelessKit
//
//  Created by Dom on 28/02/2026.
//

#import "KKNumberField.h"
#import <QuartzCore/QuartzCore.h>

// Layout
static const CGFloat KKNumberFieldFontSize = 11.0;
static const CGFloat KKNumberFieldHInset = 3.0;
static const CGFloat KKNumberFieldTextInset = 3.5;
static const CGFloat KKNumberFieldVerticalInsetBias = 2.0; // nudge to optically centre text
static const CGFloat KKNumberFieldDefaultValue = 20.0;
static const CGFloat KKNumberFieldInputWidth = 57.0;  // width of the editable field area
static const CGFloat KKNumberFieldPrefixWidth = 12.0; // reserved for 1-char prefix (e.g. "X")
static const CGFloat KKNumberFieldSuffixWidth = 18.0; // reserved for 1-2 char suffix (e.g. "px")
static const CGFloat KKNumberFieldLabelGap = 1.0;     // gap between label and field edge

// Focus ring
static const CGFloat KKNumberFieldFocusInset = 1.0;
static const CGFloat KKNumberFieldFocusCornerRadius = 2.0;
static const CGFloat KKNumberFieldFocusLineWidth = 3.5;
static const CGFloat KKNumberFieldGlowInset = 2.0;
static const CGFloat KKNumberFieldGlowLineWidth = 3.0;
static const CGFloat KKNumberFieldGlowAlpha = 0.2;
// Extra space added to all sides of the focus panel so the ring stroke is never clipped
// by the panel window's edges (window server clips at the frame boundary).
static const CGFloat KKFocusRingPanelPadding = 18.0;
// Reduced padding used after animate-in completes — just enough to show the ring stroke
// without the panel's large footprint blocking sibling controls.
static const CGFloat KKFocusRingPostAnimPadding = 3.0;

// Keys
static const unichar KKKeyEscape = 27;

@interface KKNumberFieldTextView : NSTextView
@property (nonatomic, weak) KKNumberField *parentField;
@end

/// Transparent, click-through view that hosts the animated focus ring as CA layers.
@interface KKFocusRingOverlay : NSView {
    NSColor *_color;
    CALayer *_containerLayer;
    CAShapeLayer *_ringLayer;
    CAShapeLayer *_glowLayer;
    CGFloat _padding;
}
- (instancetype)initWithColor:(NSColor *)color;
- (void)animateIn;
- (void)hide;
/// Updates the padding used to position ring paths within the overlay's bounds.
- (void)setPanelPadding:(CGFloat)padding;
@end

@implementation KKFocusRingOverlay

- (instancetype)initWithColor:(NSColor *)color {
    self = [super initWithFrame:NSZeroRect];
    if (self) {
        _color = color;
        _padding = KKFocusRingPanelPadding;
        self.wantsLayer = YES;
        [self buildLayers];
    }
    return self;
}

- (void)buildLayers {
    self.layer.masksToBounds = NO;

    // Container holds the ring layers and is the animation target.
    // anchorPoint is updated in updatePaths to match the field rect center.
    _containerLayer = [CALayer layer];
    _containerLayer.masksToBounds = NO;
    _containerLayer.opacity = 0;
    [self.layer addSublayer:_containerLayer];

    _glowLayer = [CAShapeLayer layer];
    _glowLayer.fillColor = nil;
    _glowLayer.strokeColor = [_color colorWithAlphaComponent:KKNumberFieldGlowAlpha].CGColor;
    _glowLayer.lineWidth = KKNumberFieldGlowLineWidth;
    [_containerLayer addSublayer:_glowLayer];

    // Ring is a filled even-odd compound path (outer rounded rect + inner hole).
    // This ensures the stroke can never extend inward regardless of animation state.
    _ringLayer = [CAShapeLayer layer];
    _ringLayer.fillColor = _color.CGColor;
    _ringLayer.strokeColor = nil;
    _ringLayer.fillRule = kCAFillRuleEvenOdd;
    [_containerLayer addSublayer:_ringLayer];
}

/// Compound fill path for the ring: outer rounded rect minus inner rounded rect hole.
/// |expansion| expands the outer boundary outward beyond its steady-state position.
/// The inner boundary is always fixed so the ring never encroaches inward.
- (CGPathRef)ringPathWithExpansion:(CGFloat)expansion CF_RETURNS_RETAINED {
    CGFloat w = NSWidth(self.bounds);
    CGFloat h = NSHeight(self.bounds);
    CGFloat p = _padding;
    NSRect fr = NSMakeRect(p + KKNumberFieldPrefixWidth, p,
                           w - 2 * p - KKNumberFieldPrefixWidth - KKNumberFieldSuffixWidth, h - 2 * p);
    NSRect focusRect = NSInsetRect(fr, KKNumberFieldFocusInset, KKNumberFieldFocusInset);
    CGFloat halfLW = KKNumberFieldFocusLineWidth / 2.0;

    NSRect outerRect = NSInsetRect(focusRect, -(halfLW + expansion), -(halfLW + expansion));
    CGFloat outerRadius = KKNumberFieldFocusCornerRadius + halfLW + expansion;

    NSRect innerRect = NSInsetRect(focusRect, halfLW, halfLW);
    CGFloat innerRadius = MAX(0.1, KKNumberFieldFocusCornerRadius - halfLW);

    CGMutablePathRef path = CGPathCreateMutable();
    CGPathAddRoundedRect(path, NULL, NSRectToCGRect(outerRect), outerRadius, outerRadius);
    CGPathAddRoundedRect(path, NULL, NSRectToCGRect(innerRect), innerRadius, innerRadius);
    return path;
}

- (void)setFrameSize:(NSSize)newSize {
    [super setFrameSize:newSize];
    [self updatePaths];
}

- (void)updatePaths {
    CGFloat w = NSWidth(self.bounds);
    CGFloat h = NSHeight(self.bounds);

    // The panel frame is padded on all sides by _padding so the ring stroke is never clipped
    // at the window edge. Compute the field rect within those padded bounds.
    CGFloat p = _padding;
    NSRect fr = NSMakeRect(p + KKNumberFieldPrefixWidth, p,
                           w - 2 * p - KKNumberFieldPrefixWidth - KKNumberFieldSuffixWidth, h - 2 * p);
    NSRect focusRect = NSInsetRect(fr, KKNumberFieldFocusInset, KKNumberFieldFocusInset);

    [CATransaction begin];
    [CATransaction setDisableActions:YES];

    _containerLayer.bounds = CGRectMake(0, 0, w, h);
    _containerLayer.anchorPoint = CGPointMake(0.5, 0.5);
    _containerLayer.position = CGPointMake(w / 2.0, h / 2.0);

    CGPathRef ringPath = [self ringPathWithExpansion:0];
    _ringLayer.path = ringPath;
    CGPathRelease(ringPath);

    // Position the glow so its outer edge aligns with the ring's inner boundary.
    // The glow then extends inward from there — the ring fill covers the outward half.
    CGFloat halfLW = KKNumberFieldFocusLineWidth / 2.0;
    CGFloat halfGlowLW = KKNumberFieldGlowLineWidth / 2.0;
    NSRect innerRect = NSInsetRect(focusRect, halfLW, halfLW);
    NSRect glowRect = NSInsetRect(innerRect, halfGlowLW, halfGlowLW);
    CGPathRef glowPath = CGPathCreateWithRect(NSRectToCGRect(glowRect), nil);
    _glowLayer.path = glowPath;
    CGPathRelease(glowPath);

    [CATransaction commit];
}

- (void)setPanelPadding:(CGFloat)padding {
    _padding = padding;
}

- (NSView *)hitTest:(NSPoint)point {
    return nil; // pass all events through to views beneath
}

- (void)animateIn {
    CGFloat duration = 0.23;
    CAMediaTimingFunction *easeIn = [CAMediaTimingFunction functionWithName:kCAMediaTimingFunctionEaseIn];

    // Set final model state first so layers snap to end values when animations finish.
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _containerLayer.opacity = 1.0;
    _containerLayer.transform = CATransform3DIdentity;
    [CATransaction commit];

    // Path: outer boundary starts expanded, contracts to its final position.
    CGPathRef startPath = [self ringPathWithExpansion:14.0];
    CABasicAnimation *pathAnim = [CABasicAnimation animationWithKeyPath:@"path"];
    pathAnim.fromValue = (__bridge id)startPath;
    pathAnim.duration = duration;
    pathAnim.timingFunction = easeIn;
    [_ringLayer addAnimation:pathAnim forKey:@"focusIn.path"];
    CGPathRelease(startPath);

    // Custom aggressive ease-in — stays near-transparent before snapping to full opacity.
    CAMediaTimingFunction *aggressiveEaseIn = [CAMediaTimingFunction functionWithControlPoints:0.9:0.0:1.0:1.0];
    CABasicAnimation *fade = [CABasicAnimation animationWithKeyPath:@"opacity"];
    fade.fromValue = @0.0;
    fade.duration = duration;
    fade.timingFunction = aggressiveEaseIn;
    [_containerLayer addAnimation:fade forKey:@"focusIn.opacity"];
}

- (void)hide {
    [CATransaction begin];
    [CATransaction setDisableActions:YES];
    _containerLayer.opacity = 0.0;
    [CATransaction commit];
}

@end

// Minimal extension declared here so KKNumberFieldTextView can access the members it needs.
@interface KKNumberField ()
@property (nonatomic, readwrite) BOOL isFocused;
/// Right-aligns display text by shifting the scroll view's origin.
- (void)updateTextAlignment;
/// Returns the current value formatted for editing — full precision for non-integers.
- (NSString *)displayStringForEditing;
/// Shared focus entry point — called by both the field and its embedded text view.
- (void)beginEditing;
@end

@implementation KKNumberFieldTextView

- (void)mouseDown:(NSEvent *)event {
    if (!self.isEditable) {
        [self.parentField beginEditing];
        [self.window makeFirstResponder:self];
        [super mouseDown:event];
    } else {
        [super mouseDown:event];
    }
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    // Capture arrow keys when editing — without this, arrows control the timeline scrubber.
    if (self.isEditable && event.type == NSEventTypeKeyDown) {
        NSString *chars = event.charactersIgnoringModifiers;
        if (chars.length == 1) {
            unichar c = [chars characterAtIndex:0];
            if (c == NSLeftArrowFunctionKey || c == NSRightArrowFunctionKey || c == NSUpArrowFunctionKey ||
                c == NSDownArrowFunctionKey) {
                [self interpretKeyEvents:@[ event ]];
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
@property (nonatomic, strong) KKFocusRingOverlay *focusRingOverlay;
@property (nonatomic, strong) NSPanel *focusRingPanel;
@property (nonatomic, readwrite) BOOL isEditing;
- (NSRect)fieldRect;
- (void)setupFocusRingOverlay;
- (void)updateFocusRingOverlayFrame;
- (BOOL)isPartialInput:(NSString *)string;
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

- (BOOL)isPartialInput:(NSString *)string {
    return [string isEqualToString:@"-"] || [string isEqualToString:@"."] || [string isEqualToString:@"-."];
}

- (double)parsedValueFromString:(NSString *)string {
    if (string.length == 0 || [self isPartialInput:string])
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
    // Allow deletions and clearing.
    if (replacementString.length == 0)
        return YES;

    NSString *proposedText = [textView.string stringByReplacingCharactersInRange:affectedCharRange
                                                                      withString:replacementString];
    if (proposedText.length == 0)
        return YES;

    // Only allow numeric input characters.
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:@"0123456789.-"];
    NSCharacterSet *input = [NSCharacterSet characterSetWithCharactersInString:replacementString];
    if (![allowed isSupersetOfSet:input])
        return NO;

    // At most one decimal point.
    if ([[proposedText componentsSeparatedByString:@"."] count] > 2)
        return NO;

    // Minus sign must be at the start, and only one.
    NSUInteger minusCount = [[proposedText componentsSeparatedByString:@"-"] count] - 1;
    if (minusCount > 1)
        return NO;
    if (minusCount == 1 && ![proposedText hasPrefix:@"-"])
        return NO;

    // Allow valid intermediate states (e.g. "-", ".", "-.").
    if ([self isPartialInput:proposedText])
        return YES;

    // Must parse as a complete double.
    NSScanner *scanner = [NSScanner scannerWithString:proposedText];
    double value;
    if (!([scanner scanDouble:&value] && [scanner isAtEnd]))
        return NO;

    // Enforce bounds.
    if (value < self.minValue || value > self.maxValue)
        return NO;

    return YES;
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
