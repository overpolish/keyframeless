/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <Cocoa/Cocoa.h>

NS_ASSUME_NONNULL_BEGIN

@protocol PROAPIAccessing;

@interface KKSliderView : NSView
@property(nonatomic, strong) NSSlider *slider;
@property(nonatomic, assign) double minValue;
@property(nonatomic, assign) double maxValue;
@property(nonatomic, assign) double doubleValue;
@property(nonatomic, assign) BOOL continuous;
@property(nonatomic, weak) id target;
@property(nonatomic, assign) SEL action;

+ (instancetype)styledSlider;

@end

NS_ASSUME_NONNULL_END
