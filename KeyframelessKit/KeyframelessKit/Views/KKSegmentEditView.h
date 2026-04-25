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
/// Whether the linked toggle row is shown (hold segments on multi-component
/// lanes only). When hidden the control has no effect on layout.
@property(nonatomic, readonly) BOOL showsLinked;
@property(nonatomic) BOOL linked;
/// When YES, pills render easing curves with time mirrored — matches the
/// animate-out rendering convention.
@property(nonatomic) BOOL animateOut;

@property(nonatomic, copy, nullable) void (^onCurveTypeChanged)
    (NSInteger curveType);
@property(nonatomic, copy, nullable) void (^onIntensityChanged)(double value);
@property(nonatomic, copy, nullable) void (^onFrequencyChanged)(double value);
@property(nonatomic, copy, nullable) void (^onSeedChanged)(uint32_t newSeed);
@property(nonatomic, copy, nullable) void (^onSeedReroll)(void);
@property(nonatomic, copy, nullable) void (^onLinkedChanged)(BOOL linked);

- (instancetype)initWithKind:(KKSegmentEditKind)kind;
- (instancetype)initWithKind:(KKSegmentEditKind)kind
                 showsLinked:(BOOL)showsLinked;

/// Computed height required for the view's content. Caller sizes the
/// containing popover accordingly.
+ (CGFloat)contentHeightForKind:(KKSegmentEditKind)kind
                    showsLinked:(BOOL)showsLinked;
+ (CGFloat)contentWidth;

@end

NS_ASSUME_NONNULL_END
