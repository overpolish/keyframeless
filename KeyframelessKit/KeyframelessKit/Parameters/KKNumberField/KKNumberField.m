/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#import "KKNumberField.h"
#import "KKFocusRingOverlay.h"
#include "KKHostInfo.h"
#import "KKLog.h"
#import "KKNumberFieldCell.h"
#import "KKNumberFieldInputValidator.h"
#import "KKNumberFormatter.h"
#import "NSColor+KKColors.h"
#import <AppKit/AppKit.h>
#import <CoreFoundation/CFCGTypes.h>
#import <CoreGraphics/CGDirectDisplay.h>
#import <CoreMedia/CMTime.h>
#import <Foundation/Foundation.h>
#import <FxPlug/FxPlugSDK.h>
#import <FxPlug/FxTypes.h>
#import <math.h>

static const CGFloat kNumberFieldInputFontSize = 11.0;
static const CGFloat kNumberFieldLabelFontSize = 11.0;
static const CGFloat kDragThreshold = 4.0;
static const CGFloat kMaxDeltaPerEvent = 30.0;
static const CGFloat kScrollStepThreshold = 20.0;

static const CGFloat kNumberFieldInputWidth = 51.0;
static const CGFloat kNumberFieldPrefixWidth = 10.0;
static const CGFloat kNumberFieldSuffixWidth = 20.0;
static const CGFloat kInputBottomMargin = 1.0;
static const CGFloat kInputVerticalShift =
    0.5; // shift text field up within row
static const CGFloat kFocusRingPanelPadding =
    20.0; // room for animate-in expansion
static const CGFloat kFocusRingPostAnimPadding = 5.0; // shrunk after animation

const CGFloat kNumberFieldWidth =
    kNumberFieldPrefixWidth + kNumberFieldInputWidth + kNumberFieldSuffixWidth;
const CGFloat kNumberFieldHeight = 15.0;

@implementation KKNumberField {
  KKLog *_log;

  NSTextField *_textField;
  KKFocusRingOverlay *_focusRingOverlay;
  NSPanel *_focusRingPanel;
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

  BOOL _hasKeyframes;
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
    _isStepperMode = NO;

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
  _textField.focusRingType = NSFocusRingTypeNone;
  _textField.textColor = [NSColor labelColor];
  _textField.editable = NO; // Start in stepper mode
  _textField.alignment = NSTextAlignmentRight;
  _textField.cell.usesSingleLineMode = YES;
  // Has to draw background as otherwise without background the field is
  // slightly too large
  _textField.drawsBackground = YES;
  _textField.backgroundColor = [NSColor clearColor];
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
                       constant:kInputBottomMargin - kInputVerticalShift],
  ]];

  _focusRingOverlay = [[KKFocusRingOverlay alloc]
      initWithColor:[NSColor keyboardFocusIndicator]];

  _focusRingPanel =
      [[NSPanel alloc] initWithContentRect:NSMakeRect(0, 0, 1, 1)
                                 styleMask:NSWindowStyleMaskBorderless |
                                           NSWindowStyleMaskNonactivatingPanel
                                   backing:NSBackingStoreBuffered
                                     defer:NO];
  _focusRingPanel.backgroundColor = [NSColor clearColor];
  _focusRingPanel.opaque = NO;
  _focusRingPanel.hasShadow = NO;
  _focusRingPanel.ignoresMouseEvents = YES;
  _focusRingPanel.hidesOnDeactivate = NO;
  _focusRingPanel.contentView = _focusRingOverlay;

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
  // TODO hover state rather than active state
  // [self updateActiveState];
}

- (void)mouseMoved:(NSEvent *)event {
  BOOL inTextBounds = [self _isMouseInTextBoundsForEvent:event];
  if (inTextBounds != _isHovered) {
    _isHovered = inTextBounds;
    // [self updateActiveState];
  }
}

- (void)mouseExited:(NSEvent *)event {
  _isHovered = NO;
  // [self updateActiveState];
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
    // Prepare for potential drag — don't enter stepper mode until mouseUp
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
  // Drag works in any non-edit state
  if (_textField.currentEditor) {
    return;
  }

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
  if (!_mouseDownInInputRect) {
    return;
  }
  if (_didDrag) {
    _didDrag = NO;
    [[NSCursor arrowCursor] set];
    CGWarpMouseCursorPosition(_dragStartScreenPoint);
  } else if (self.window.firstResponder != _textField) {
    // Single click without drag → enter stepper mode
    _isStepperMode = YES;
    [self setNeedsDisplay:YES];
    [self.window makeFirstResponder:self];
    [self updateFocusRingPanelFrameWithPadding:kFocusRingPanelPadding];
    if (self.window && !_focusRingPanel.parentWindow) {
      [self.window addChildWindow:_focusRingPanel ordered:NSWindowAbove];
    }
    [self updateActiveState];
    __weak typeof(self) weak = self;
    dispatch_after(
        dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)),
        dispatch_get_main_queue(), ^{
          __strong typeof(self) strong = weak;
          if (!strong || !strong->_isStepperMode)
            return;
          [strong
              updateFocusRingPanelFrameWithPadding:kFocusRingPostAnimPadding];
        });
  }
}

- (void)updateFocusRingPanelFrameWithPadding:(CGFloat)padding {
  if (!self.window)
    return;
  NSRect frameInWindow = [_textField convertRect:_textField.bounds toView:nil];
  NSRect frameOnScreen = [self.window convertRectToScreen:frameInWindow];
  frameOnScreen.origin.y -= kInputVerticalShift;
  frameOnScreen = NSInsetRect(frameOnScreen, -padding, -padding);
  [_focusRingOverlay setPanelPadding:padding];
  [_focusRingPanel setFrame:frameOnScreen display:NO];
}

- (void)enterEditMode {
  _isStepperMode = NO;
  [self setNeedsDisplay:YES];
  _textField.editable = YES;
  ((KKNumberFormatter *)_textField.formatter).editing = YES;
  _textField.doubleValue = _numberValue;

  [self updateFocusRingPanelFrameWithPadding:kFocusRingPanelPadding];
  if (self.window && !_focusRingPanel.parentWindow) {
    [self.window addChildWindow:_focusRingPanel ordered:NSWindowAbove];
  }
  [_focusRingPanel orderFront:nil];
  [_focusRingOverlay show];

  __weak typeof(self) weak = self;
  dispatch_after(
      dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.30 * NSEC_PER_SEC)),
      dispatch_get_main_queue(), ^{
        __strong typeof(self) strong = weak;
        if (!strong || strong->_isStepperMode)
          return;
        [strong updateFocusRingPanelFrameWithPadding:kFocusRingPostAnimPadding];
      });

  [self.window makeFirstResponder:_textField];
}

- (void)exitEditMode {
  _isStepperMode = NO;
  _textField.editable = NO;
  ((KKNumberFormatter *)_textField.formatter).editing = NO;
  self.numberValue = _textField.doubleValue;
  [self setNeedsDisplay:YES];
  [_focusRingOverlay hide];
  if (_focusRingPanel.parentWindow) {
    [_focusRingPanel.parentWindow removeChildWindow:_focusRingPanel];
  }
  [_focusRingPanel orderOut:nil];
}

- (BOOL)acceptsFirstResponder {
  return YES;
}

- (BOOL)resignFirstResponder {
  if (_isStepperMode) {
    _isStepperMode = NO;
    [self setNeedsDisplay:YES];
    [_focusRingOverlay hide];
    if (_focusRingPanel.parentWindow) {
      [_focusRingPanel.parentWindow removeChildWindow:_focusRingPanel];
    }
    [_focusRingPanel orderOut:nil];
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

- (void)refreshKeyframeState {
  // Only Motion has the red text if keyframes exist
  if (_parameterId == 0 || [KKHostInfo isRunningInFinalCut]) {
    return;
  }

  id<FxCustomParameterActionAPI_v4> actionAPI =
      [_apiManager apiForProtocol:@protocol(FxCustomParameterActionAPI_v4)];
  if (!actionAPI) {
    return;
  }
  [actionAPI startAction:self];

  id<FxKeyframeAPI_v3> keyframeAPI =
      [_apiManager apiForProtocol:@protocol(FxKeyframeAPI_v3)];

  BOOL hasKeyframes = NO;

  if (_channel != nil) {
    NSUInteger count = 0;
    [keyframeAPI keyframeCount:&count
                  forParameter:_parameterId
                    andChannel:_channel.unsignedIntegerValue];
    hasKeyframes = (count > 0);
  } else {
    // Check all channels if non provided (would be the case for group)
    NSUInteger channelCount = 0;
    [keyframeAPI channelCount:&channelCount forParameter:_parameterId];
    for (NSUInteger i = 0; i < channelCount; i++) {
      NSUInteger count = 0;
      [keyframeAPI keyframeCount:&count forParameter:_parameterId andChannel:i];
      if (count > 0) {
        hasKeyframes = YES;
        break;
      }
    }
  }

  [actionAPI endAction:self];

  if (hasKeyframes != _hasKeyframes) {
    _hasKeyframes = hasKeyframes;
    _textField.textColor =
        _hasKeyframes ? [NSColor error] : [NSColor labelColor];
  }
}

- (void)drawRect:(NSRect)dirtyRect {
  [super drawRect:dirtyRect];
  if (_parameterId != 0) {
    [self refreshKeyframeState];
  }

  if (_isStepperMode) {
    NSString *displayString = _textField.stringValue;
    NSDictionary *textAttrs = @{NSFontAttributeName : _textField.font};
    NSSize textSize = [displayString sizeWithAttributes:textAttrs];
    CGFloat textStartX =
        kNumberFieldPrefixWidth + kNumberFieldInputWidth - textSize.width;
    static CGFloat const kBgHeight = 9.0;
    CGFloat midY = self.bounds.size.height / 2.0;
    NSRect bgRect = NSMakeRect(textStartX - 2.5, midY - kBgHeight / 2.0 - 1.0,
                               textSize.width + 1.5, kBgHeight);
    NSBezierPath *bg = [NSBezierPath bezierPathWithRoundedRect:bgRect
                                                       xRadius:1.0
                                                       yRadius:1.0];
    [[NSColor colorWithRed:0x23 / 255.0
                     green:0x3e / 255.0
                      blue:0x66 / 255.0
                     alpha:1.0] setFill];
    [bg fill];
  }

  NSDictionary *attrs = [self labelTextAttributes];

  static CGFloat const kBottomMargin =
      1.0; // Apple Motion/FCP decorations off-center

  if (self.prefix) {
    NSRect prefixRect = NSMakeRect(0, kBottomMargin, kNumberFieldPrefixWidth,
                                   self.bounds.size.height);
    [self.prefix drawInRect:prefixRect withAttributes:attrs];
  }

  if (self.suffix) {
    static CGFloat const kSuffixLeftMargin = 4.0;
    NSRect suffixRect = NSMakeRect(
        kNumberFieldPrefixWidth + kNumberFieldInputWidth + kSuffixLeftMargin,
        kBottomMargin, kNumberFieldSuffixWidth, self.bounds.size.height);
    [self.suffix drawInRect:suffixRect withAttributes:attrs];
  }
}

- (void)updateActiveState {
  BOOL active = _textField.isEditable ||
                (_isStepperMode && self.window.firstResponder == self);

  if (active) {
    // TODO show focus
    [_focusRingPanel orderFront:nil];
    _focusRingPanel.ignoresMouseEvents = YES;
    [_focusRingOverlay animateIn];
  } else if (_isHovered) {
    // TODO only when either not active or in stepper mode, NOT EDIT MODE
    _textField.backgroundColor = [NSColor blueColor];
  } else {
    [_focusRingOverlay hide];
    if (_focusRingPanel.parentWindow) {
      [_focusRingPanel.parentWindow removeChildWindow:_focusRingPanel];
    }
    [_focusRingPanel orderOut:nil];
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
