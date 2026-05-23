/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@interface KKSliderView : NSView

@property(nonatomic, strong) NSSlider *slider;
@property(nonatomic, assign) double minValue;
@property(nonatomic, assign) double maxValue;
@property(nonatomic, assign) double doubleValue;
@property(nonatomic, assign) BOOL continuous;
@property(nonatomic, weak, nullable) id target;
@property(nonatomic, assign, nullable) SEL action;

@property(nonatomic, strong, nullable) NSColor *trackFillColor;

/// Fires once when a drag begins on the slider thumb (mouseDown), and once
/// when the drag ends (mouseUp). Use to bracket continuous drags inside a
/// single undo group on the consumer side.
@property(nonatomic, copy, nullable) void (^onDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onDragEnd)(void);

/// Piecewise scale break. When both are > 0, the range [minValue,
/// scaleBreakValue] occupies the first scaleBreakPosition fraction of the
/// track (e.g. 0.8 = 80%), and [scaleBreakValue, maxValue] occupies the rest.
@property(nonatomic, assign) double scaleBreakValue;
@property(nonatomic, assign) double scaleBreakPosition;

+ (instancetype)styledSlider;

/// Screen-space geometry for a guide that drives this slider: the track rect,
/// the knob-centre X for a value, and the value for a screen X. All honour
/// the scale break and knob inset so a guide's target marker and drag map
/// line up exactly with the rendered knob.
- (NSRect)trackScreenRect;
- (CGFloat)screenXForValue:(double)value;
- (double)valueForScreenX:(CGFloat)screenX;

@end

NS_ASSUME_NONNULL_END
