/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKNumberField.h"
#import "KKLog.h"
#import "KKNumberFieldCell.h"
#import "KKNumberFieldInputValidator.h"
#import "KKNumberFormatter.h"
#import "NSColor+KKColors.h"
#import <AppKit/AppKit.h>
#import <FxPlug/FxTypes.h>
#import <math.h>

static const CGFloat kNumberFieldInputWidth = 51.0;
static const CGFloat kNumberFieldPrefixWidth = 5.5;
static const CGFloat kNumberFieldSuffixWidth = 18.5;

static const CGFloat kNumberFieldInputFontSize = 11.0;
static const CGFloat kNumberFieldLabelFontSize = 12.0;
static const CGFloat kDragThreshold = 4.0;

const CGFloat kNumberFieldWidth =
    kNumberFieldPrefixWidth + kNumberFieldInputWidth + kNumberFieldSuffixWidth;
const CGFloat kNumberFieldHeight = 15.0;

@implementation KKNumberField {
  NSTextField *_textField;
  id<PROAPIAccessing> _apiManager;
  KKNumberFieldInputValidator *_inputValidator;

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
    _apiManager = apiManager;
    _log = [KKLog loggerForPlugin:@"co.overpolish.keyframeless"];

    _minValue = -INFINITY;
    _maxValue = INFINITY;
    _stepValue = 1.0;
    _dragScale = 1.0;
    _shiftStepMultiplier = 10.0;
    _optionStepMultiplier = 0.1;
    _isStepperMode = YES;
    _isSelected = NO;

    // TODO clean
    _prefix = @"Y";
    _suffix = @"px";

    [self setupTextField];
  }
  return self;
}

- (void)setupTextField {
  _textField = [[NSTextField alloc] initWithFrame:NSZeroRect];
  KKNumberFieldCell *customCell = [[KKNumberFieldCell alloc] init];
  _textField.cell = customCell;

  _textField.translatesAutoresizingMaskIntoConstraints = NO;
  _textField.delegate = self;
  _textField.bordered = NO;
  _textField.drawsBackground = YES;
  _textField.backgroundColor = [NSColor redColor];
  _textField.textColor = [NSColor labelColor];
  _textField.editable = NO; // Start in stepper mode
  _textField.alignment = NSTextAlignmentRight;
  _textField.cell.usesSingleLineMode = YES;
  _textField.cell.scrollable = YES;
  _textField.cell.wraps = NO;
  _textField.font =
      [NSFont monospacedDigitSystemFontOfSize:kNumberFieldInputFontSize
                                       weight:NSFontWeightRegular];

  KKNumberFormatter *formatter = [[KKNumberFormatter alloc] init];
  formatter.minValue = _minValue;
  formatter.maxValue = _maxValue;
  _textField.formatter = formatter;
  _textField.doubleValue = _numberValue;

  [self addSubview:_textField];

  [NSLayoutConstraint activateConstraints:@[
    [_textField.leadingAnchor constraintEqualToAnchor:self.leadingAnchor
                                             constant:kNumberFieldPrefixWidth],
    [_textField.widthAnchor constraintEqualToConstant:kNumberFieldInputWidth],
    [_textField.centerYAnchor
        constraintEqualToAnchor:self.centerYAnchor
                       constant:1.0], // Offset to match Motion
  ]];
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize(kNumberFieldWidth, kNumberFieldHeight);
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

    if (!_didDrag &&
        (fabs(deltaY) >= kDragThreshold || fabs(deltaX) >= kDragThreshold)) {
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

      CGFloat delta = _dragAxisIsVertical ? deltaY : deltaX;
      CGFloat steps = round(delta / _dragScale);
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
    if ([self handleArrowKeysInEditMode:event]) {
      return YES;
    }

    if (_isSelected && _isStepperMode) {
      if ([self handleNumericKeyInStepperMode:event]) {
        return YES;
      }
      if ([self handleArrowKeyInStepperMode:event]) {
        return YES;
      }
    }
  }

  return [super performKeyEquivalent:event];
}

- (BOOL)handleArrowKeysInEditMode:(NSEvent *)event {
  if (_isStepperMode || !_textField.currentEditor) {
    return NO;
  }
  NSString *charsIgnoringMods = event.charactersIgnoringModifiers;
  if (charsIgnoringMods.length == 1) {
    unichar c = [charsIgnoringMods characterAtIndex:0];
    // Stops arrow keys from controlling the timeline scrubber while editing
    if (c == NSUpArrowFunctionKey || c == NSDownArrowFunctionKey ||
        c == NSLeftArrowFunctionKey || c == NSRightArrowFunctionKey) {
      [_textField.currentEditor interpretKeyEvents:@[ event ]];
      return YES;
    }
  }
  return NO;
}

// Enters edit mode and inserts the typed character
- (BOOL)handleNumericKeyInStepperMode:(NSEvent *)event {
  NSString *chars = event.characters;
  if (chars.length == 0) {
    return NO;
  }
  unichar ch = [chars characterAtIndex:0];
  if ((ch >= '0' && ch <= '9') || ch == '-' || ch == '.') {
    [self enterEditMode];
    NSText *fieldEditor = [self.window fieldEditor:YES forObject:_textField];
    _textField.stringValue = @"";
    [fieldEditor insertText:event.charactersIgnoringModifiers];
    return YES;
  }
  return NO;
}

// Handles up/down/left/right arrows in stepper mode
- (BOOL)handleArrowKeyInStepperMode:(NSEvent *)event {
  unichar key = [event.charactersIgnoringModifiers characterAtIndex:0];
  if (key == NSUpArrowFunctionKey || key == NSDownArrowFunctionKey) {
    CGFloat step = [self effectiveStepWithModifiers:event.modifierFlags];
    if (key == NSUpArrowFunctionKey) {
      self.numberValue += step;
    } else {
      self.numberValue -= step;
    }
    _textField.doubleValue = self.numberValue;
    return YES;
  } else if (key == NSLeftArrowFunctionKey || key == NSRightArrowFunctionKey) {
    // Left/right arrows - consume, do nothing
    return YES;
  }
  return NO;
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
    effectiveStep *= _shiftStepMultiplier;
  }
  if (modifierFlags & NSEventModifierFlagOption) {
    effectiveStep *= _optionStepMultiplier;
  }
  return effectiveStep;
}

- (void)setNumberValue:(CGFloat)numberValue {
  double clampedValue = fmax(self.minValue, fmin(numberValue, self.maxValue));

  // Round to 4 decimal places (matches Apple Motion)
  clampedValue = round(clampedValue * 10000.0) / 10000.0;

  _numberValue = clampedValue;
  _textField.doubleValue = clampedValue;
}

- (NSDictionary *)labelTextAttributes {
  return @{
    NSFontAttributeName : [NSFont systemFontOfSize:kNumberFieldLabelFontSize
                                            weight:NSFontWeightLight],
    NSForegroundColorAttributeName : [NSColor inspectorLabel],
  };
}

- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];
  NSDictionary *attrs = [self labelTextAttributes];

  if (self.prefix) {
    NSRect prefixRect =
        NSMakeRect(0, 0, kNumberFieldPrefixWidth, self.bounds.size.height);
    [self.prefix drawInRect:prefixRect withAttributes:attrs];
  }

  if (self.suffix) {
    NSRect suffixRect =
        NSMakeRect(kNumberFieldPrefixWidth + kNumberFieldInputWidth, 0,
                   kNumberFieldSuffixWidth, self.bounds.size.height);
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

- (void)setPrefix:(NSString *)prefix {
  _prefix = [prefix copy];
  [self setNeedsDisplay:YES];
}

- (void)setSuffix:(NSString *)suffix {
  _suffix = [suffix copy];
  [self setNeedsDisplay:YES];
}

@end
