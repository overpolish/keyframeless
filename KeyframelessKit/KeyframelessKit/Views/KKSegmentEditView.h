/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

typedef NS_ENUM(NSInteger, KKSegmentEditKind) {
  KKSegmentEditKindHold,
  KKSegmentEditKindTransition,
};

/// Content view for the segment-edit popover. Shows curve/hold-effect pills,
/// intensity + frequency sliders, and (for holds) a seed field.
@interface KKSegmentEditView : NSView

@property(nonatomic, readonly) KKSegmentEditKind kind;
@property(nonatomic) NSInteger curveType;
@property(nonatomic) double intensity;
@property(nonatomic) double frequency;
@property(nonatomic) uint32_t seed;
/// When YES, pills render easing curves with time mirrored — matches the
/// animate-out rendering convention.
@property(nonatomic) BOOL animateOut;

@property(nonatomic, copy, nullable) void (^onCurveTypeChanged)
    (NSInteger curveType);
@property(nonatomic, copy, nullable) void (^onIntensityChanged)(double value);
@property(nonatomic, copy, nullable) void (^onFrequencyChanged)(double value);
@property(nonatomic, copy, nullable) void (^onSeedChanged)(uint32_t newSeed);
@property(nonatomic, copy, nullable) void (^onSeedReroll)(void);

- (instancetype)initWithKind:(KKSegmentEditKind)kind;

/// Computed height required for the view's content. Caller sizes the
/// containing popover accordingly.
+ (CGFloat)contentHeightForKind:(KKSegmentEditKind)kind;
+ (CGFloat)contentWidth;

@end

NS_ASSUME_NONNULL_END
