//
//  KKNumberField.m
//  KeyframelessKit
//
//  Created by Dom on 28/02/2026.
//

#import "KKNumberField.h"

@interface KKNumberFieldTextView : NSTextView
@property (nonatomic, weak) KKNumberField *parentField;
@end

@implementation KKNumberFieldTextView

- (void)mouseDown:(NSEvent *)event
{
    if (!self.isEditable)
    {
        self.editable = YES;
        self.selectable = YES;
        self.parentField.isFocused = YES;
        [self.parentField setNeedsDisplay:YES];
        
        if (self.parentField.doubleValue == floor(self.parentField.doubleValue)) {
            self.string = [NSString stringWithFormat:@"%.1f", self.parentField.doubleValue];
        } else {
            // Show full precision when editing
            self.string = [NSString stringWithFormat:@"%g", self.parentField.doubleValue];
        }
        
        [self.parentField updateTextAlignment];
        
        [self.window makeFirstResponder:self];
        [super mouseDown:event];
    } else {
        [super mouseDown:event];
    }
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
    // Capture arrow keys when editing - without this arrows control the timeline scrubber
    if (self.isEditable && event.type == NSEventTypeKeyDown) {
        NSString *chars = event.charactersIgnoringModifiers;
        if (chars.length == 1) {
            unichar c = [chars characterAtIndex:0];
            if (c == NSLeftArrowFunctionKey || c == NSRightArrowFunctionKey
                || c == NSUpArrowFunctionKey || c == NSDownArrowFunctionKey) {
                // Let NSTextView handle it
                [self interpretKeyEvents:@[event]];
                return YES;
            } else if (c == 27) { // Escape key - cancels editing
                if (self.parentField.doubleValue == floor(self.parentField.doubleValue)) {
                    self.string = [NSString stringWithFormat:@"%.1f", self.parentField.doubleValue];
                } else {
                    self.string = [NSString stringWithFormat:@"%g", self.parentField.doubleValue];
                }
                [self.window makeFirstResponder:nil];
                return YES;
            }
        }
    }
    return [super performKeyEquivalent:event];
}

@end

@implementation KKNumberField

- (instancetype)initWithFrame:(NSRect)frame
                   apiManager:(id<PROAPIAccessing>)apiManager
{
    self = [super initWithFrame:frame];
    if (self) {
        self.apiManager = apiManager;
        _backgroundColor = [NSColor clearColor];
        _doubleValue = 20.0;
        _minValue = -INFINITY;
        _maxValue = INFINITY;
        [self setupTextView];
    }
    return self;
}

- (void)setupTextView {
    // Create scroll view container for clipping
    NSRect scrollFrame = NSInsetRect(self.bounds, 3, 0);
    self.scrollView = [[NSScrollView alloc] initWithFrame:scrollFrame];
    self.scrollView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    self.scrollView.hasVerticalScroller = NO;
    self.scrollView.hasHorizontalScroller = NO;
    self.scrollView.borderType = NSNoBorder;
    self.scrollView.drawsBackground = NO;
    
    KKNumberFieldTextView *textView = [[KKNumberFieldTextView alloc] initWithFrame:self.scrollView.bounds];
    textView.parentField = self;
    textView.delegate = self;
    textView.drawsBackground = NO;
    textView.textColor = [NSColor labelColor];
    textView.font = [NSFont systemFontOfSize:11];
    textView.alignment = NSTextAlignmentLeft;
    
    // Selection color
    textView.selectedTextAttributes = @{
        NSBackgroundColorAttributeName: [NSColor colorWithRed:0x59/255.0 green:0x59/255.0 blue:0xE1/255.0 alpha:1.0]
    };
    
    textView.textContainer.lineFragmentPadding = 0;
    
    // Single line
    textView.textContainer.containerSize = NSMakeSize(CGFLOAT_MAX, NSHeight(self.bounds));
    textView.textContainer.widthTracksTextView = NO;
    textView.horizontallyResizable = YES;
    textView.verticallyResizable = NO;
    textView.maxSize = NSMakeSize(CGFLOAT_MAX, NSHeight(self.bounds));
    
    // Vertical centering
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11]};
    NSSize textSize = [@"0" sizeWithAttributes:attrs];
    CGFloat verticalInset = floor((NSHeight(self.bounds) - textSize.height) / 2.0);
    textView.textContainerInset = NSMakeSize(4, verticalInset + 1);
    
    textView.string = [NSString stringWithFormat:@"%.1f", _doubleValue];
    textView.autoresizingMask = NSViewHeightSizable;
    textView.fieldEditor = YES;
    textView.editable = NO;
    textView.selectable = NO;
    
    self.textView = textView;
    self.scrollView.documentView = textView;
    [self addSubview:self.scrollView];
    
    // Position in correct location (without this typing causes a shift down initially)
    [textView.layoutManager ensureLayoutForTextContainer:textView.textContainer];
    [textView setNeedsDisplay:YES];
    
    [self updateTextAlignment];
}

/// Maintain right alignment visually by offsetting the scroll view.
- (void)updateTextAlignment {
    NSDictionary *attrs = @{NSFontAttributeName: [NSFont systemFontOfSize:11]};
    NSSize textSize = [self.textView.string sizeWithAttributes:attrs];
    
    CGFloat availableWidth = NSWidth(self.scrollView.bounds) - 8;
    CGFloat offset = MAX(0, availableWidth - textSize.width);
    
    NSRect scrollFrame = self.scrollView.frame;
    scrollFrame.origin.x = 3 + offset; // 3 is original inset
    self.scrollView.frame = scrollFrame;
}

- (BOOL)acceptsFirstResponder
{
    return YES;
}

- (BOOL)becomeFirstResponder
{
    return YES;
}

- (BOOL)resignFirstResponder
{
    return YES;
}

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
    
    NSString *rawText = self.textView.string;
    if (rawText.length == 0 || [rawText isEqualToString:@"-"] || [rawText isEqualToString:@"."] || [rawText isEqualToString:@"-."]) {
        _doubleValue = 0.0;
    } else {
        _doubleValue = [rawText doubleValue]; // Store full precision
    }
    
    if (_doubleValue < self.minValue)
    {
        _doubleValue = self.minValue;
    } else if (_doubleValue > self.maxValue) {
        _doubleValue = self.maxValue;
    }
    
    self.textView.string = [NSString stringWithFormat:@"%.1f", _doubleValue];
    [self updateTextAlignment];
    
    self.textView.editable = NO;
    self.textView.selectable = NO;
    [self setNeedsDisplay:YES];
}

- (BOOL)textView:(NSTextView *)textView shouldChangeTextInRange:(NSRange)affectedCharRange replacementString:(NSString *)replacementString
{
    // Allow deletions
    if (replacementString.length == 0) {
        return YES;
    }
    
    NSString *currentText = textView.string;
    NSString *proposedText = [currentText stringByReplacingCharactersInRange:affectedCharRange withString:replacementString];
    
    // Allow empty
    if (proposedText.length == 0) {
        return YES;
    }
    
    NSCharacterSet *allowedChars = [NSCharacterSet characterSetWithCharactersInString:@"0123456789.-"];
    NSCharacterSet *inputChars = [NSCharacterSet characterSetWithCharactersInString:replacementString];
    
    if (![allowedChars isSupersetOfSet:inputChars]) {
        return NO;
    }
    
    // Single decimal
    NSUInteger decimalCount = [[proposedText componentsSeparatedByString:@"."] count] - 1;
    if (decimalCount > 1) {
        return NO;
    }
    
    NSUInteger minusCount = [[proposedText componentsSeparatedByString:@"-"] count] - 1;
    // Minut sign must be at the beginning
    if (minusCount > 1) {
        return NO;
    }
    
    if (minusCount == 1 && ![proposedText hasPrefix:@"-"]) {
        return NO;
    }
    
    // Allows intermediate states
    if ([proposedText isEqualToString:@"-"] || [proposedText isEqualToString:@"."] || [proposedText isEqualToString:@"-."]) {
        return YES;
    }
    
    // Attempt to parse to double
    NSScanner *scanner = [NSScanner scannerWithString:proposedText];
    double value;
    if (!([scanner scanDouble:&value] && [scanner isAtEnd])) {
        return NO;
    }
    
    // Check min/max bounds
    if (value < self.minValue || value > self.maxValue) {
        return NO;
    }
    
    return YES;
}

- (void)drawRect:(NSRect)dirtyRect
{
    [self.backgroundColor setFill];
    NSRectFill(self.bounds);
    
    if (self.isFocused)
    {
        NSColor *focusColor = [NSColor colorWithRed:0x28/255.0 green:0x47/255.0 blue:0x77/255.0 alpha:1.0];
        NSRect focusRect = NSInsetRect(self.bounds, 1, 1);
        NSBezierPath *focusPath = [NSBezierPath bezierPathWithRoundedRect:focusRect
                                                                  xRadius:2
                                                                  yRadius:2];
        
        // Main ring
        focusPath.lineWidth = 3.5;
        [focusColor setStroke];
        [focusPath stroke];
        
        // Inner glow
        [[focusColor colorWithAlphaComponent:0.2] setStroke];
        NSBezierPath *innerPath = [NSBezierPath bezierPathWithRect:NSInsetRect(focusRect, 2.0, 2.0)];
        innerPath.lineWidth = 5.5;
        [innerPath stroke];
        
    }
}

- (void)setBackgroundColor:(NSColor *)backgroundColor {
    _backgroundColor = backgroundColor;
    [self setNeedsDisplay:YES];
}

@end
