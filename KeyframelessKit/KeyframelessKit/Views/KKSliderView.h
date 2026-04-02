/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
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

+ (instancetype)styledSlider;

@end

NS_ASSUME_NONNULL_END
