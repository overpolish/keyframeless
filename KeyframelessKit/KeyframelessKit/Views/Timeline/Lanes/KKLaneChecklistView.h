/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKTimingStage.h>

NS_ASSUME_NONNULL_BEGIN

@class _KKManageRow, _KKSearchField, KKPillToggleRowView;

/// Shared chrome for the timeline's searchable, category-navigable checkable
/// lane lists: the Animated "manage" dropdown (`_KKManagePopoverView`) and the
/// lane-visibility filter (`KKLaneFilterChecklistView`). Owns the search field,
/// the category pill nav, the row stack, category+search row filtering and the
/// height/resize math. Subclasses supply ONLY their per-row configuration
/// (which box is checked, what a toggle does) by overriding
/// `-configureRow:forLane:`, and call `-rebuildRows` once their own state is
/// set up.
@interface _KKLaneChecklistView : NSView <NSSearchFieldDelegate> {
@protected
  _KKSearchField *_searchField;
  NSStackView *_rowStack;
  NSMutableArray<_KKManageRow *> *_allRows;
  KKPillToggleRowView *_categoryPill;
  NSString *_selectedCategory;
  NSDictionary<NSString *, NSString *> *_rowCategoryByLabel;
  BOOL _hasPill;
  CGFloat _minimumHeight;
  NSArray<KKLane *> *_lanes;
}

/// Builds the chrome (search + pill + row stack) sized to `lanes`, but does NOT
/// build rows - the subclass calls `-rebuildRows` after initializing its state.
- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes
                minimumHeight:(CGFloat)minimumHeight;

/// Set by the host so the list can resize the popover to the visible row count.
@property(nonatomic, weak, nullable) NSPopover *popover;

/// Subclass hook: configure a freshly-created row (`rowLabel` is already set)
/// for `lane` - its checked/warning state and toggle handlers. Default: no-op.
- (void)configureRow:(_KKManageRow *)row forLane:(KKLane *)lane;

/// Rebuild every row from the current lane set (calls
/// `-configureRow:forLane:`).
- (void)rebuildRows;
/// Replace the lane set (e.g. a multi-owner re-scope) and rebuild.
- (void)setLanes:(NSArray<KKLane *> *)lanes;

/// The row view for `label`, or nil (guide spotlight anchor).
- (nullable NSView *)rowViewForLabel:(NSString *)label;

+ (CGFloat)preferredWidth;
/// Height that hugs the currently-visible rows (>= the minimum height).
- (CGFloat)fittingHeight;

@end

NS_ASSUME_NONNULL_END
