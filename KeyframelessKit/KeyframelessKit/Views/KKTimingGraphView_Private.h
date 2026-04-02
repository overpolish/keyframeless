/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import "KKTimingGraphView.h"

@class KKSliderView;

@interface KKTimingGraphView ()

@property(nonatomic, readonly) NSImageView *graphImageView;
@property(nonatomic, readonly) NSImageView *tickImageView;
@property(nonatomic, readonly) NSImageView *intensityTickImageView;
@property(nonatomic, readonly) NSImageView *frequencyTickImageView;
@property(nonatomic, readonly) KKSliderView *curveSlider;
@property(nonatomic, readonly) NSStackView *midSeedStack;

- (void)renderGraph;
- (void)renderTicks;
- (void)renderIntensityTicks;
- (void)renderFrequencyTicks;

- (NSRect)sectionRectForSection:(KKTimingGraphSection)section
                          width:(CGFloat)totalWidth;

@end
