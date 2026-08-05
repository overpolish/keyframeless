/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKTimeline.h>

NS_ASSUME_NONNULL_BEGIN

/// Pure data model behind `KKLaneFilterBar`: turns a lane set into grouped pill
/// "compounds" and tracks per-lane visibility + solo. No views - the bar reads
/// the derived arrays and forwards clicks back as mutations.
///
/// A compound is one capsule of segments. Segments are either MASTER (a layer
/// or a category header, toggling every lane it heads) or a plain single lane.
///  - Multi-owner timelines (lanes carry layerKey): ONE compound per layer =
///    [layer | (Category | lane ...) ...], layer in stack order.
///  - Single-owner: each category run / bare lane is its own compound.
@interface KKLaneFilterModel : NSObject

- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes;

/// Rebuild from a new lane set, preserving the visibility of surviving lanes
/// (newly added lanes default to visible). Returns YES when the structure
/// changed and the caller should rebuild its pill views; NO when identical
/// (same labels, layer names, categories, order) so an in-progress edit isn't
/// disturbed.
- (BOOL)applyLanes:(NSArray<KKLane *> *)lanes;

/// Per-compound display labels (localized), for `KKCompoundPillBar`.
@property(nonatomic, readonly) NSArray<NSArray<NSString *> *> *displayLabels;
/// Per-compound index sets of master segments, kept out of the drag-sweep.
@property(nonatomic, readonly) NSArray<NSIndexSet *> *masterExcludedIndices;
/// Per-compound per-segment on/off (a master is on when ANY lane it heads is
/// visible) and warning (soloed) flags - same shape as `displayLabels`.
@property(nonatomic, readonly) NSArray<NSArray<NSNumber *> *> *segmentStates;
@property(nonatomic, readonly) NSArray<NSArray<NSNumber *> *> *segmentWarnings;

/// Hidden lane labels (for the bar's onVisibilityChanged).
@property(nonatomic, readonly) NSSet<NSString *> *hiddenLabels;
/// Soloed lane labels (drawn warning-tinted in the checklist).
@property(nonatomic, readonly) NSSet<NSString *> *soloedLabels;
/// YES when any lane is hidden or a solo is in effect - the only time the
/// reset affordance is meaningful.
@property(nonatomic, readonly) BOOL filterActive;

/// Per-lane visibility toggle for the checklist (ends any active solo).
- (void)setLabel:(NSString *)label visible:(BOOL)visible;
/// Solo a single lane (only it visible). Soloing the active single-lane solo
/// again clears it and shows every lane.
- (void)soloLabel:(NSString *)label;

/// Toggle the lane(s) a segment targets (whole group for a master). Ends any
/// active solo.
- (void)toggleCompound:(NSInteger)ci segment:(NSInteger)seg on:(BOOL)on;
/// Solo the lane/group a segment targets (only it visible). Soloing the active
/// solo again clears it and shows every lane.
- (void)soloCompound:(NSInteger)ci segment:(NSInteger)seg;
/// Clear any solo and make every lane visible.
- (void)showAll;
/// Clear any solo and set visibility so exactly `hidden` is hidden.
- (void)applyHidden:(NSSet<NSString *> *)hidden;

@end

NS_ASSUME_NONNULL_END
