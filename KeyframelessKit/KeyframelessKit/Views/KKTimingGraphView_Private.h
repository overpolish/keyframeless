/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import "../Style/KKTokens.h"
#import "KKTimingGraphView.h"

@class KKCurvePillView;
@class KKSliderView;

static const CGFloat kTopPadding __attribute__((unused)) = KKPaddingMD;
static const CGFloat kPillRowHeight __attribute__((unused)) = 24.0;
static const CGFloat kGraphHeight __attribute__((unused)) = 60.0;
static const CGFloat kLabelRowHeight __attribute__((unused)) = 20.0;
static const CGFloat kSliderRowHeight __attribute__((unused)) = 28.0;
static const CGFloat kTickHeight __attribute__((unused)) = 16.0;
static const CGFloat kDurationTickHeight __attribute__((unused)) = 10.0;
static const CGFloat kCheckboxSize __attribute__((unused)) = 12.0;
static const NSInteger kDurationTickCount __attribute__((unused)) = 3;
static const double kDurationTickValues[]
    __attribute__((unused)) = {0.0, 1.0, 2.0};
static const NSInteger kIntensityTickCount __attribute__((unused)) = 3;
static const NSInteger kFrequencyTickCount __attribute__((unused)) = 3;

@interface KKTimingGraphView ()

@property(nonatomic, readonly) KKCurvePillView *curvePillView;
@property(nonatomic, readonly) KKSliderView *durationSlider;
@property(nonatomic, readonly) NSImageView *durationTickImageView;
@property(nonatomic, readonly) NSImageView *graphImageView;
@property(nonatomic, readonly) NSImageView *intensityTickImageView;
@property(nonatomic, readonly) NSImageView *frequencyTickImageView;
@property(nonatomic, readonly) NSStackView *holdSeedStack;

- (void)renderGraph;
- (void)renderCurvePills;
- (void)renderDurationTicks;
- (void)renderIntensityTicks;
- (void)renderFrequencyTicks;

- (NSRect)sectionRectForSection:(KKTimingGraphSection)section
                          width:(CGFloat)totalWidth;

@end
