//
//  KKNumberField.m
//  KeyframelessKit
//
//  Created by Dom on 28/02/2026.
//

#import "KKNumberField.h"
#import "KKLog.h"
#import "KKNumberFieldGeometry.h"
#include "KKNumberFieldInputValidator.h"
#include <AppKit/AppKit.h>
#include <CoreFoundation/CFCGTypes.h>
#include <CoreGraphics/CGDirectDisplay.h>
#include <CoreGraphics/CGGeometry.h>
#include <CoreGraphics/CGRemoteOperation.h>
#include <Foundation/Foundation.h>
#include <math.h>
#include <objc/NSObjCRuntime.h>
#include <objc/objc.h>

// TODO move to file
@interface KKNumberFieldCell : NSTextFieldCell
@end

@implementation KKNumberFieldCell

- (NSRect)drawingRectForBounds:(NSRect)rect {
  NSRect titleRect = [super titleRectForBounds:rect];

  NSSize textSize = [self.attributedStringValue size];
  if (textSize.width > titleRect.size.width) {
    titleRect.origin.x =
        titleRect.size.width - textSize.width - 2; // 2px buffer
    titleRect.size.width = textSize.width + 2.5; // Match position of edit view
  }

  // TODO pull into const
  titleRect.origin.y += 1.0; // Push down to match Motion
  return titleRect;
}

- (void)selectWithFrame:(NSRect)rect
                 inView:(NSView *)controlView
                 editor:(NSText *)textObj
               delegate:(id)delegate
                  start:(NSInteger)selStart
                 length:(NSInteger)selLength {
  NSRect adjustedRect = rect;

  // TODO pull into const
  adjustedRect.origin.y += 1.0; // Push down to match Motion
  [super selectWithFrame:adjustedRect
                  inView:controlView
                  editor:textObj
                delegate:delegate
                   start:selStart
                  length:selLength];
}

- (void)drawInteriorWithFrame:(NSRect)cellFrame inView:(NSView *)controlView {
  [NSGraphicsContext saveGraphicsState];
  [[NSBezierPath bezierPathWithRect:cellFrame] addClip];
  [super drawInteriorWithFrame:cellFrame inView:controlView];
  [NSGraphicsContext restoreGraphicsState];
}

- (NSText *)setUpFieldEditorAttributes:(NSText *)textObj {
  NSText *result = [super setUpFieldEditorAttributes:textObj];

  if ([result isKindOfClass:[NSTextView class]]) {
    NSTextView *textView = (NSTextView *)result;
    [textView setSelectedTextAttributes:@{
      // TODO pull out into const
      NSBackgroundColorAttributeName : [NSColor colorWithRed:0x59 / 255.0
                                                       green:0x59 / 255.0
                                                        blue:0xE1 / 255.0
                                                       alpha:1.0]
    }];
  }
  return result;
}

@end

// TODO move kknumberformatter
@interface KKNumberFormatter : NSFormatter
@property(nonatomic, assign) double minValue;
@property(nonatomic, assign) double maxValue;
@end

@implementation KKNumberFormatter

- (instancetype)init {
  self = [super init];
  if (self) {
    _minValue = -DBL_MIN;
    _maxValue = DBL_MAX;
  }
  return self;
}

- (NSString *)stringForObjectValue:(id)obj {
  if (![obj isKindOfClass:[NSNumber class]]) {
    return nil;
  }

  double value = [obj doubleValue];
  return [NSString stringWithFormat:@"%.4f", value];
}

- (BOOL)getObjectValue:(out id _Nullable __autoreleasing *)obj
             forString:(NSString *)string
      errorDescription:(out NSString *_Nullable __autoreleasing *)error {
  if (obj) {
    *obj = @([string doubleValue]);
  }
  return YES;
}

- (BOOL)isPartialStringValid:(NSString *)partialString
            newEditingString:(NSString *_Nullable __autoreleasing *)newString
            errorDescription:(NSString *_Nullable __autoreleasing *)error {

  // Allow clearing
  if (partialString.length == 0)
    return YES;

  // Character set validation
  NSCharacterSet *allowed =
      [NSCharacterSet characterSetWithCharactersInString:@"0123456789.-"];
  if ([[partialString stringByTrimmingCharactersInSet:allowed] length] > 0) {
    return NO;
  }

  // Structural validation
  if ([[partialString componentsSeparatedByString:@"."] count] > 2) {
    return NO;
  }

  NSUInteger minusCount =
      [[partialString componentsSeparatedByString:@"-"] count] - 1;
  if (minusCount > 1 || (minusCount == 1 && ![partialString hasPrefix:@"-"])) {
    return NO;
  }

  // Intermediate states
  if ([partialString isEqualToString:@"-"] ||
      [partialString isEqualToString:@"."] ||
      [partialString isEqualToString:@"-."]) {
    return YES;
  }

  // Numeric and bounds validation
  NSScanner *scanner = [NSScanner scannerWithString:partialString];
  double value;
  if ([scanner scanDouble:&value] && [scanner isAtEnd]) {
    return (value >= self.minValue && value <= self.maxValue);
  }

  return NO;
}
@end

@interface KKNumberField ()
@property(nonatomic, strong) NSTextField *textField;
@property(nonatomic, strong) id<PROAPIAccessing> apiManager;
@property(nonatomic, strong) KKNumberFieldInputValidator *inputValidator;
@end

@implementation KKNumberField {
  NSPoint _dragStartPoint;
  CGFloat _dragStartValue;
  BOOL _didDrag;
  CGPoint _dragStartScreenPoint;
  BOOL _dragAxisIsVertical;
  NSEventModifierFlags _lastModifierFlags;
}

- (instancetype)initWithFrame:(NSRect)frameRect
                   apiManager:(nonnull id<PROAPIAccessing>)apiManager {
  self = [super initWithFrame:frameRect];
  if (self) {
    self.apiManager = apiManager;
    _log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless"];

    _minValue = -INFINITY;
    _maxValue = INFINITY;
    _stepValue = 1.0;
    _isStepperMode = YES;
    _isSelected = NO;

    // TODO clean
    _prefix = @"X";
    _suffix = @"px";

    // TODO move into helper
    NSRect inputFrame =
        NSMakeRect(KKNumberFieldPrefixWidth, -1, // Offset to match Motion
                   KKNumberFieldInputWidth, frameRect.size.height);
    _textField = [[NSTextField alloc] initWithFrame:inputFrame];
    // TODO clean
    KKNumberFieldCell *customCell = [[KKNumberFieldCell alloc] init];
    _textField.cell = customCell;

    _textField.autoresizingMask = NSViewMinYMargin;
    _textField.delegate = self;
    _textField.bordered = NO;
    _textField.backgroundColor = [NSColor redColor];
    _textField.editable = NO; // Start in stepper mode
    _textField.alignment = NSTextAlignmentRight;
    _textField.cell.usesSingleLineMode = YES;
    _textField.cell.scrollable = YES;
    _textField.cell.wraps = NO;
    _textField.font =
        [NSFont monospacedDigitSystemFontOfSize:11.0 // TODO pull out to const
                                         weight:NSFontWeightRegular];

    KKNumberFormatter *formatter = [[KKNumberFormatter alloc] init];
    formatter.minValue = _minValue;
    formatter.maxValue = _maxValue;
    _textField.formatter = formatter;

    [self addSubview:_textField];
  }
  return self;
}

- (void)mouseDown:(NSEvent *)event {
  if (event.clickCount == 2) {
    [self enterEditMode];
  } else if (event.clickCount == 1) {
    // Prepare for potential drag
    _dragStartPoint = [self convertPoint:event.locationInWindow fromView:nil];
    _dragStartValue = self.numberValue;
    _didDrag = NO;

    // Store screen position for restore later
    NSPoint windowPoint = [self convertPoint:_dragStartPoint toView:nil];
    NSPoint screenPoint = [self.window convertPointToScreen:windowPoint];
    _dragStartScreenPoint = CGPointMake(
        screenPoint.x,
        CGDisplayBounds(CGMainDisplayID()).size.height - screenPoint.y);
  }
}

- (void)mouseDragged:(NSEvent *)event {
  if (_isStepperMode) {
    NSPoint currentPoint = [self convertPoint:event.locationInWindow
                                     fromView:nil];
    CGFloat deltaX = currentPoint.x - _dragStartPoint.x;
    CGFloat deltaY = currentPoint.y - _dragStartPoint.y;

    // Require at least 4 pixels of movement for drag to count
    // TODO pull into constant/var
    if (!_didDrag && (fabs(deltaY) >= 4.0 || fabs(deltaX) >= 4.0)) {
      _dragAxisIsVertical = fabs(deltaY) > fabs(deltaX);
      _didDrag = YES;
      // TODO hide cursor
      _lastModifierFlags = event.modifierFlags;
    }

    if (_didDrag) {
      // When modifiers change reset drag from current position
      NSEventModifierFlags relevantFlags =
          event.modifierFlags &
          (NSEventModifierFlagShift | NSEventModifierFlagOption);
      NSEventModifierFlags lastRelevantFlags =
          _lastModifierFlags &
          (NSEventModifierFlagShift | NSEventModifierFlagOption);

      if (relevantFlags != lastRelevantFlags) {
        _dragStartPoint = currentPoint;
        _dragStartValue = self.numberValue;
        _lastModifierFlags = event.modifierFlags;

        // Skip this frame to avoid value jump
        return;
      }

      CGFloat effectiveStep =
          [self effectiveStepWithModifiers:event.modifierFlags];

      // TODO pull into constant/var
      // Scale delta: every 1 pixels = 1 step
      CGFloat delta = _dragAxisIsVertical ? deltaY : deltaX;
      CGFloat steps = round(delta / 1.0);
      self.numberValue = _dragStartValue + (steps * effectiveStep);
      _textField.doubleValue = self.numberValue;
    }
  }
}

- (void)mouseUp:(NSEvent *)event {
  if (_didDrag) {
    // TODO show cursor

    // Warp cursor back to drag start point
    // TODO move to helper
    CGAssociateMouseAndMouseCursorPosition(false);
    CGWarpMouseCursorPosition(_dragStartScreenPoint);
    CGAssociateMouseAndMouseCursorPosition(true);
  }

  if (event.clickCount == 1 && _isStepperMode && !_didDrag) {
    _isSelected = YES;
    [self.window makeFirstResponder:self];
    [self updateBackgroundColor];
  }
}

- (void)enterEditMode {
  _isStepperMode = NO;
  _isSelected = YES;
  _textField.editable = YES;
  [self updateBackgroundColor];
  [self.window makeFirstResponder:_textField];
}

- (void)exitEditMode {
  _isStepperMode = YES;
  _isSelected = NO;
  _textField.editable = NO;
  self.numberValue = _textField.doubleValue;

  [self updateBackgroundColor];
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (BOOL)resignFirstResponder {
  // TODO show cursor

  if (_isStepperMode) {
    _isSelected = NO;
    [self updateBackgroundColor];
  }
  return [super resignFirstResponder];
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
  if (event.type == NSEventTypeKeyDown) {
    NSString *chars = event.characters;

    // TODO move to helper - stops arrows controlling timeline scrubber
    if (!_isStepperMode && _textField.currentEditor) {
      NSString *charsIgnoringMods = event.charactersIgnoringModifiers;
      if (charsIgnoringMods.length == 1) {
        unichar c = [charsIgnoringMods characterAtIndex:0];
        if (c == NSUpArrowFunctionKey || c == NSDownArrowFunctionKey ||
            c == NSLeftArrowFunctionKey || c == NSRightArrowFunctionKey) {
          [_textField.currentEditor interpretKeyEvents:@[ event ]];
          return YES;
        }
      }
    }

    // TODO move to helper - enter edit mode with this input
    if (_isSelected && _isStepperMode) {
      if (chars.length > 0) {
        unichar ch = [chars characterAtIndex:0];
        if ((ch >= '0' && ch <= '9') || ch == '-' || ch == '.') {
          [self enterEditMode];
          NSText *fieldEditor = [self.window fieldEditor:YES
                                               forObject:_textField];
          _textField.stringValue = @""; // Clear field
          [fieldEditor insertText:event.charactersIgnoringModifiers];

          return YES; // Consume event
        }
      }

      // TODO move to helper - up/down value adjustment in stepper mode
      // TODO up arrow, really no constants?
      if (event.keyCode == 126 || event.keyCode == 125) {
        CGFloat step = [self effectiveStepWithModifiers:event.modifierFlags];
        if (event.keyCode == 126) {
          self.numberValue += step;
        } else {
          self.numberValue -= step;
        }
        _textField.doubleValue = self.numberValue;
        return YES; // Consume event
      } else if (event.keyCode == 123 || event.keyCode == 124) {
        // Left/right arrows - consume do nothing
        return YES;
      }
    }
  }

  return [super performKeyEquivalent:event];
}

- (void)controlTextDidEndEditing:(NSNotification *)notification {
  [self exitEditMode];
}

- (BOOL)control:(NSControl *)control
               textView:(NSTextView *)textView
    doCommandBySelector:(SEL)commandSelector {
  // Handle return/escape to exit edit mode
  if (commandSelector == @selector(insertNewline:) ||
      commandSelector == @selector(cancelOperation:)) {
    [self.window makeFirstResponder:self];
    return YES;
  }
  return NO;
}

- (CGFloat)effectiveStepWithModifiers:(NSEventModifierFlags)modifierFlags {
  CGFloat effectiveStep = _stepValue;
  if (modifierFlags & NSEventModifierFlagShift) {
    effectiveStep *= 10.0; // TODO pull to property
  }
  if (modifierFlags & NSEventModifierFlagOption) {
    effectiveStep *= 0.1; // TODO pull to property
  }
  return effectiveStep;
}

- (void)setNumberValue:(CGFloat)numberValue {
  double clampedValue = fmax(self.minValue, fmin(numberValue, self.maxValue));

  // Round to 4 decimal places (matches Apple Motion)
  clampedValue = round(clampedValue * 10000.0) / 10000.0;

  _numberValue = clampedValue;
  self.textField.doubleValue = clampedValue;
}

- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];
  NSDictionary *attrs = @{
    // TODO pull out into const vars
    NSFontAttributeName : [NSFont systemFontOfSize:11.0
                                            weight:NSFontWeightRegular],
    NSForegroundColorAttributeName : [NSColor colorWithRed:0xB3 / 255.0
                                                     green:0xB3 / 255.0
                                                      blue:0xB3 / 255.0
                                                     alpha:1.0]
  };

  // TODO pull into helper
  if (self.prefix) {
    NSRect prefixRect =
        // TODO pull out -3.5px into const? its for focus ring overlap
        NSMakeRect(-3.5, KKDecorationVerticalOffset, KKNumberFieldPrefixWidth,
                   self.bounds.size.height);
    [self.prefix drawInRect:prefixRect withAttributes:attrs];
  }

  if (self.suffix) {
    NSRect suffixRect =
        // TODO +2 pull into const - its extra spacing so it does not overlap
        // focus ring
        NSMakeRect(KKNumberFieldPrefixWidth + KKNumberFieldInputWidth + 2.5,
                   KKDecorationVerticalOffset, KKNumberFieldSuffixWidth,
                   self.bounds.size.height);
    [self.suffix drawInRect:suffixRect withAttributes:attrs];
  }
}
// TODO draw focus ring

// TODO this is to become focus drawing
- (void)updateBackgroundColor {
  if (_isSelected) {
    _textField.backgroundColor = [NSColor greenColor];
  } else {
    _textField.backgroundColor = [NSColor redColor];
  }
}

+ (CGFloat)preferredWidth {
  return KKNumberFieldPrefixWidth + KKNumberFieldInputWidth +
         KKNumberFieldSuffixWidth;
}

+ (CGFloat)preferredHeight {
  return KKNumberFieldInputHeight;
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
