/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

// Gradient value rows: read the control's current stops, compose them (with the
// optional type/angle prefix) into the flat lane value, and show/hide the angle
// knob for a linear gradient. Split out of KKTimelineStaticValueRow.m; reaches
// row state via the @package ivars in KKTimelineStaticValueRow_Private.h.

#import "KKGradientControl.h"
#import "KKGradientSampling.h" // KKGradientFlatFromStops / KKGradientStopsFromFlat
#import "KKTimelineStaticValueRow_Private.h"

@implementation _KKStaticValueRow (Gradient)

- (NSArray<KKGradientStop *> *)_currentGradientStops {
  NSArray<NSNumber *> *flat = _values;
  if (_gradientWithTypeAngle)
    flat = _values.count > 2
               ? [_values subarrayWithRange:NSMakeRange(2, _values.count - 2)]
               : @[];
  return KKGradientStopsFromFlat(flat);
}

- (NSArray<NSNumber *> *)_composeGradientWithStops:
    (NSArray<KKGradientStop *> *)stops {
  NSArray<NSNumber *> *flat = KKGradientFlatFromStops(stops);
  if (!_gradientWithTypeAngle)
    return flat;
  double type = _values.count >= 1 ? _values[0].doubleValue : 0.0;
  double angle = _values.count >= 2 ? _values[1].doubleValue : 0.0;
  NSMutableArray<NSNumber *> *out = [@[ @(type), @(angle) ] mutableCopy];
  [out addObjectsFromArray:flat];
  return out;
}

- (void)_updateGradientAngleVisibility {
  NSInteger type = _values.count >= 1 ? llround(_values[0].doubleValue) : 0;
  _gradientAngleContainer.hidden = (type != 1); // angle only for Linear
}

- (void)_gradientAngleKnobMoved:(NSSlider *)sender {
  if (!_gradientAngleKnobDragging) {
    [sender.window makeFirstResponder:nil];
    _gradientAngleKnobDragging = YES;
    if (self.onDragBegin)
      self.onDragBegin();
  }
  NSMutableArray<NSNumber *> *v = [_values mutableCopy];
  if (v.count >= 2)
    v[1] = @(sender.doubleValue);
  [self _setValues:v emit:YES];
  if (NSApp.currentEvent.type == NSEventTypeLeftMouseUp) {
    _gradientAngleKnobDragging = NO;
    if (self.onDragEnd)
      self.onDragEnd();
  }
}

- (void)_gradientAngleFieldCommitted:(NSTextField *)sender {
  NSMutableArray<NSNumber *> *v = [_values mutableCopy];
  if (v.count >= 2)
    v[1] = @(sender.doubleValue);
  [self _setValues:v emit:YES];
}

@end
