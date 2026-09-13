/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */
#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

/// A compact linear value slider used by inspector rows. The track and knob
/// are drawn locally so its appearance does not depend on the host theme.
@interface ICSliderView : NSView

@property(nonatomic, strong, readonly) NSSlider *slider;
@property(nonatomic) double minValue;
@property(nonatomic) double maxValue;
@property(nonatomic) double doubleValue;
@property(nonatomic) BOOL continuous;
@property(nonatomic) BOOL enabled;
@property(nonatomic, strong, nullable) NSColor *trackFillColor;
@property(nonatomic, copy, nullable) void (^onDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onDragEnd)(void);

@property(nonatomic, weak, nullable) id target;
@property(nonatomic, assign, nullable) SEL action;

+ (instancetype)styledSlider;

@end

NS_ASSUME_NONNULL_END
