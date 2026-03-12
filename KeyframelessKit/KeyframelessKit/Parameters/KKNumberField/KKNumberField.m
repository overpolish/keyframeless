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
#import <CoreGraphics/CGDirectDisplay.h>
#import <Foundation/Foundation.h>
#import <FxPlug/FxTypes.h>
#import <math.h>

static const CGFloat kNumberFieldInputWidth = 51.0;
static const CGFloat kNumberFieldPrefixWidth = 5.5;
static const CGFloat kNumberFieldSuffixWidth = 18.5;

static const CGFloat kNumberFieldInputFontSize = 11.0;
static const CGFloat kNumberFieldLabelFontSize = 12.0;
static const CGFloat kDragThreshold = 4.0;
static const CGFloat kMaxDeltaPerEvent = 30.0;
static const CGFloat kScrollStepThreshold = 20.0;

const CGFloat kNumberFieldWidth =
    kNumberFieldPrefixWidth + kNumberFieldInputWidth + kNumberFieldSuffixWidth;
const CGFloat kNumberFieldHeight = 15.0;

@implementation KKNumberField {
  KKLog *_log;

  NSTextField *_textField;
  id<PROAPIAccessing> _apiManager;
  KKNumberFieldInputValidator *_inputValidator;

  NSPoint _dragStartPoint;
  CGFloat _dragStartValue;
  BOOL _didDrag;
  CGPoint _dragStartScreenPoint;
  BOOL _dragAxisIsVertical;
  NSEventModifierFlags _lastModifierFlags;
  CGFloat _totalDragDelta;
  CGFloat _preDragDeltaX;
  CGFloat _preDragDeltaY;

  NSCursor *_transparentCursor;
  CGFloat _scrollAccumulator;

  BOOL _mouseDownInInputRect;

  NSTrackingArea *_trackingArea;
  BOOL _isHovered;
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

  [self addTrackingArea:_trackingArea];
}

- (void)updateTrackingArea {
  if (_trackingArea) {
    [self removeTrackingArea:_trackingArea];
  }

  NSRect trackingRect = [self textBounds];
  _trackingArea = [[NSTrackingArea alloc]
      initWithRect:trackingRect
           options:NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways
             owner:self
          userInfo:nil];
  [self addTrackingArea:_trackingArea];
}

- (NSRect)textBounds {
  NSString *displayString = _textField.stringValue;
  NSDictionary *attrs = @{NSFontAttributeName : _textField.font};
  CGFloat textWidth = [displayString sizeWithAttributes:attrs].width;

  CGFloat textStartX =
      kNumberFieldPrefixWidth + kNumberFieldInputWidth - textWidth;

  return NSMakeRect(textStartX, 0, textWidth, self.bounds.size.height);
}

- (BOOL)_isMouseInTextBoundsForEvent:(NSEvent *)event {
  NSPoint localPoint = [self convertPoint:event.locationInWindow fromView:nil];
  return NSPointInRect(localPoint, [self textBounds]);
}

- (void)mouseEntered:(NSEvent *)event {
  _isHovered = [self _isMouseInTextBoundsForEvent:event];
  [self updateBackgroundColor];
}

- (void)mouseMoved:(NSEvent *)event {
  BOOL inTextBounds = [self _isMouseInTextBoundsForEvent:event];
  if (inTextBounds != _isHovered) {
    _isHovered = inTextBounds;
    [self updateBackgroundColor];
  }
}

- (void)mouseExited:(NSEvent *)event {
  _isHovered = NO;
  [self updateBackgroundColor];
}

- (NSSize)intrinsicContentSize {
  return NSMakeSize(kNumberFieldWidth, kNumberFieldHeight);
}

- (void)scrollWheel:(NSEvent *)event {
  if (!_isStepperMode || self.window.firstResponder != self) {
    [super scrollWheel:event];
    return;
  }

  CGFloat step = [self effectiveStepWithModifiers:event.modifierFlags];

  if (event.hasPreciseScrollingDeltas) {
    _scrollAccumulator += event.scrollingDeltaY;
    CGFloat steps = trunc(_scrollAccumulator / kScrollStepThreshold);
    if (steps != 0) {
      _scrollAccumulator -= steps * kScrollStepThreshold;
      self.numberValue -= steps * step;
    }
  } else {
    CGFloat delta = event.scrollingDeltaY;
    if (fabs(delta) >= 1.0) {
      self.numberValue -= (delta > 0 ? 1 : -1) * step;
    }
  }
}

- (NSRect)inputRect {
  return NSMakeRect(kNumberFieldPrefixWidth, 0, kNumberFieldInputWidth,
                    self.bounds.size.height);
}

- (void)mouseDown:(NSEvent *)event {
  // If global event convert into our coordinate space
  NSPoint screenLocation = [NSEvent mouseLocation];
  NSPoint windowPoint = [self.window convertPointFromScreen:screenLocation];
  NSPoint localPoint = [self convertPoint:windowPoint fromView:nil];

  _mouseDownInInputRect = NSPointInRect(localPoint, [self inputRect]);
  if (!_mouseDownInInputRect) {
    return;
  }
  if (event.clickCount == 2) {
    [self enterEditMode];
  } else if (event.clickCount == 1) {
    [self.window makeFirstResponder:self];
    [self updateBackgroundColor];
    // Prepare for potential drag
    _dragStartValue = self.numberValue;
    _didDrag = NO;
    _preDragDeltaX = 0;
    _preDragDeltaY = 0;
    _totalDragDelta = 0;

    // Store screen position to restore cursor on mouseUp
    NSPoint screenPoint =
        [self.window convertPointToScreen:event.locationInWindow];
    _dragStartScreenPoint = CGPointMake(
        screenPoint.x,
        CGDisplayBounds(CGMainDisplayID()).size.height - screenPoint.y);
  }
}

- (void)mouseDragged:(NSEvent *)event {
  if (!_mouseDownInInputRect) {
    return;
  }
  if (_isStepperMode) {
    if (!_didDrag) {
      if (fabs(event.deltaX) > kMaxDeltaPerEvent ||
          fabs(event.deltaY) > kMaxDeltaPerEvent) {
        return;
      }
      _preDragDeltaX += event.deltaX;
      _preDragDeltaY += event.deltaY;

      if (fabs(_preDragDeltaX) >= kDragThreshold ||
          fabs(_preDragDeltaY) >= kDragThreshold) {
        _dragAxisIsVertical = fabs(_preDragDeltaY) > fabs(_preDragDeltaX);
        _totalDragDelta = 0;
        _didDrag = YES;
        _lastModifierFlags = event.modifierFlags;
        CGWarpMouseCursorPosition(CGPointMake(0, 0));
        return;
      }
    }

    if (_didDrag) {
      [[self transparentCursor] set];
      // Pin to top-left; transparent cursor avoids option-key reveal in FxPlug
      CGWarpMouseCursorPosition(CGPointMake(0, 0));

      // When modifiers change, reset drag from current value
      NSEventModifierFlags relevantFlags =
          event.modifierFlags &
          (NSEventModifierFlagShift | NSEventModifierFlagOption);
      NSEventModifierFlags lastRelevantFlags =
          _lastModifierFlags &
          (NSEventModifierFlagShift | NSEventModifierFlagOption);

      if (relevantFlags != lastRelevantFlags) {
        _dragStartValue = self.numberValue;
        _totalDragDelta = 0;
        _lastModifierFlags = event.modifierFlags;
        return;
      }

      CGFloat axisDelta = _dragAxisIsVertical ? -event.deltaY : event.deltaX;
      if (fabs(axisDelta) > kMaxDeltaPerEvent) {
        return;
      }
      _totalDragDelta += axisDelta;

      CGFloat effectiveStep =
          [self effectiveStepWithModifiers:event.modifierFlags];
      CGFloat steps = round(_totalDragDelta / _dragScale);
      self.numberValue = _dragStartValue + (steps * effectiveStep);
      _textField.doubleValue = self.numberValue;
    }
  }
}

- (NSCursor *)transparentCursor {
  if (!_transparentCursor) {
    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(1, 1)];
    [image lockFocus];
    [[NSColor clearColor] set];
    NSRectFill(NSMakeRect(0, 0, 1, 1));
    [image unlockFocus];
    _transparentCursor = [[NSCursor alloc] initWithImage:image
                                                 hotSpot:NSZeroPoint];
  }
  return _transparentCursor;
}

- (void)mouseUp:(NSEvent *)event {
  if (!_mouseDownInInputRect || !_didDrag) {
    return;
  }
  _didDrag = NO;
  [[NSCursor arrowCursor] set];
  CGWarpMouseCursorPosition(_dragStartScreenPoint);
}

- (void)enterEditMode {
  _isStepperMode = NO;
  _textField.editable = YES;
  [self updateBackgroundColor];
  [self.window makeFirstResponder:_textField];
}

- (void)exitEditMode {
  _isStepperMode = YES;
  _textField.editable = NO;
  self.numberValue = _textField.doubleValue;

  [self updateBackgroundColor];
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (BOOL)resignFirstResponder {
  if (_isStepperMode) {
    _textField.backgroundColor = [NSColor redColor];
  }
  return [super resignFirstResponder];
}

- (BOOL)performKeyEquivalent:(NSEvent *)event {
  if (event.type == NSEventTypeKeyDown) {
    if ([self handleArrowKeysInEditMode:event]) {
      return YES;
    }

    if (_isStepperMode && self.window.firstResponder == self) {
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

  [self updateTrackingArea];
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
  BOOL active = !_isStepperMode || self.window.firstResponder == self;

  if (active) {
    _textField.backgroundColor = [NSColor greenColor];
  } else if (_isHovered) {
    _textField.backgroundColor = [NSColor blueColor];
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
