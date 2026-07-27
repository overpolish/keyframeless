/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>

NS_ASSUME_NONNULL_BEGIN

@class KKLane;

typedef NS_ENUM(NSInteger, KKSegmentEditKind) {
  KKSegmentEditKindHold,
  KKSegmentEditKindTransition,
};

/// Content view for the segment-edit popover. Shows curve/hold-effect pills,
/// Intensity + Frequency value rows (slider + number field), and (for holds) a
/// seed field.
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
/// When YES, pills render easing curves with time mirrored - matches the
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
/// Fires for a typed seed AND for the row's re-roll button - the row rolls the
/// new value itself, so both arrive here.
@property(nonatomic, copy, nullable) void (^onSeedChanged)(uint32_t newSeed);
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

/// Checklist participation variant - the Animated dropdown's content (search +
/// category pill nav + one checkable row per property) embedded as the "Applies
/// to" section instead of a horizontal pill bar, so it scales to many grouped
/// properties. `lanes` carry the category / layer metadata that drives grouping
/// and dedup; `states[i]` is whether `lanes[i]` participates. The
/// `onParticipationToggled` index matches `lanes` order, so downstream callers
/// are unchanged.
- (instancetype)initWithKind:(KKSegmentEditKind)kind
                 showsLinked:(BOOL)showsLinked
                  bulkHeader:(BOOL)bulkHeader
          participationLanes:(nullable NSArray<KKLane *> *)lanes
         participationStates:(nullable NSArray<NSNumber *> *)states;

/// Checklist variant of the compound participation: the Animated dropdown's
/// content (search + category pill nav + checkable rows) with multi-component
/// lanes shown as a master row plus indented per-component sub-rows, instead of
/// the horizontal compound pill bar. `lanes[i]` is the lane behind
/// `compounds[i]` (drives the category pill nav). `onParticipationToggled`'s
/// index is the flattened (compound, segment) position, matching the pill bar.
- (instancetype)initWithKind:(KKSegmentEditKind)kind
                    showsLinked:(BOOL)showsLinked
                     bulkHeader:(BOOL)bulkHeader
     participationCompoundLanes:(nullable NSArray<KKLane *> *)lanes
         participationCompounds:
             (nullable NSArray<NSArray<NSString *> *> *)compoundLabels
    participationCompoundStates:
        (nullable NSArray<NSArray<NSNumber *> *> *)compoundStates;

/// Live-update the participation pill row from a fresh state array. Lets
/// the host refresh after an external timeline mutation (e.g. cmd-Z) so
/// the pills stay in sync without closing the popover.
- (void)applyParticipationCompoundStates:
    (NSArray<NSArray<NSNumber *> *> *)states;

/// Plain (non-compound) participation pill variant of the above. Also refreshes
/// the checklist participation variant.
- (void)applyParticipationStates:(NSArray<NSNumber *> *)states;

/// Replace the checklist participation's lanes + states (a multi-owner host
/// re-scoping the open popover to a newly-selected layer's lanes, in place - no
/// close/reopen). The matching variant for the kind that's shown.
- (void)rescopeParticipationLanes:(NSArray<KKLane *> *)lanes
                           states:(NSArray<NSNumber *> *)states;
- (void)rescopeCompoundParticipationLanes:(NSArray<KKLane *> *)lanes
                                compounds:
                                    (NSArray<NSArray<NSString *> *> *)compounds
                                   states:
                                       (NSArray<NSArray<NSNumber *> *> *)states;

/// The content height changed on its own (the Frequency row collapsing when
/// the picked curve has no frequency). The host re-sizes the popover; without
/// it the row's space would be left blank. Fires only on a real change.
@property(nonatomic, copy, nullable) void (^onContentHeightChanged)(void);

/// Buttons for the popover's title bar - [Reset][Make Default], sitting where
/// the keypose / constants popovers put their size pill. They save this
/// segment's shape as the plugin's default for new segments, and put the
/// segment back to it; both hide while the segment already matches the saved
/// default. Built on first call, then cached.
- (NSView *)defaultsAccessoryView;

/// The view's required content height for the current configuration. Unlike the
/// class method this accounts for the checklist participation section, whose
/// height depends on the (filtered) row count. Falls back to the class-method
/// height when there is no checklist.
- (CGFloat)contentHeight;

/// YES when the "Applies to" section renders as the embedded checklist (its
/// scroll fade marks the bottom edge), so the host can drop its own bottom
/// padding when the checklist is the last element.
@property(nonatomic, readonly) BOOL hasChecklistParticipation;

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
