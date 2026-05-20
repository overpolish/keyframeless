/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
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
/// Whether the view was constructed in bulk mode (shows a "Bulk Edit"
/// header row).
@property(nonatomic, readonly) BOOL bulkHeader;

@property(nonatomic, copy, nullable) void (^onCurveTypeChanged)
    (NSInteger curveType);
@property(nonatomic, copy, nullable) void (^onIntensityChanged)(double value);
@property(nonatomic, copy, nullable) void (^onFrequencyChanged)(double value);
/// Fires once on slider mouseDown / mouseUp (intensity or frequency). Lets
/// the consumer bracket the entire continuous drag in one undo group, so
/// cmd-Z reverts the drag as a single step rather than per-tick.
@property(nonatomic, copy, nullable) void (^onSliderDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onSliderDragEnd)(void);
@property(nonatomic, copy, nullable) void (^onSeedChanged)(uint32_t newSeed);
@property(nonatomic, copy, nullable) void (^onSeedReroll)(void);
@property(nonatomic, copy, nullable) void (^onLinkedChanged)(BOOL linked);
/// Per-property participation pills (which animatable properties this phase
/// applies to). Multi-select with click-drag sweep; drag-begin/end bracket
/// the gesture for one undo entry. Present only when constructed with
/// non-empty participation labels.
@property(nonatomic, copy, nullable) void (^onParticipationToggled)
    (NSInteger index, BOOL isOn);
@property(nonatomic, copy, nullable) void (^onParticipationDragBegin)(void);
@property(nonatomic, copy, nullable) void (^onParticipationDragEnd)(void);

- (instancetype)initWithKind:(KKSegmentEditKind)kind;
- (instancetype)initWithKind:(KKSegmentEditKind)kind
                 showsLinked:(BOOL)showsLinked;
- (instancetype)initWithKind:(KKSegmentEditKind)kind
                 showsLinked:(BOOL)showsLinked
                  bulkHeader:(BOOL)bulkHeader;
- (instancetype)initWithKind:(KKSegmentEditKind)kind
                 showsLinked:(BOOL)showsLinked
                  bulkHeader:(BOOL)bulkHeader
         participationLabels:(nullable NSArray<NSString *> *)labels
         participationStates:(nullable NSArray<NSNumber *> *)states;

/// Computed height required for the view's content. Caller sizes the
/// containing popover accordingly.
+ (CGFloat)contentHeightForKind:(KKSegmentEditKind)kind
                    showsLinked:(BOOL)showsLinked
                     bulkHeader:(BOOL)bulkHeader;
+ (CGFloat)contentHeightForKind:(KKSegmentEditKind)kind
                    showsLinked:(BOOL)showsLinked
                     bulkHeader:(BOOL)bulkHeader
                  participation:(BOOL)participation;
+ (CGFloat)contentWidth;

@end

NS_ASSUME_NONNULL_END
