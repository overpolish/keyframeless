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
  // Embedded mode (hosted inside another popover, e.g. the gap "Applies to"
  // section): the row stack lives in a capped, internally-scrolling clip and
  // the view owns its own height instead of resizing a popover.
  BOOL _embedded;
  CGFloat _width;
  CGFloat _maxBodyHeight;
  NSView *_bodyScroll; // KKPaddedScrollView (top/bottom fade) when embedded
  NSLayoutConstraint *_heightConstraint;
  NSLayoutConstraint *_bodyHeightConstraint;
}

/// Builds the chrome (search + pill + row stack) sized to `lanes`, but does NOT
/// build rows - the subclass calls `-rebuildRows` after initializing its state.
- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes
                minimumHeight:(CGFloat)minimumHeight;

/// Embedded variant: hosted inside another popover at a fixed `width`, the row
/// list capped at `maxBodyHeight` (scrolls internally beyond it). The view
/// drives its own height constraint instead of resizing a `popover`. Used by
/// the gap popover's "Applies to" section.
- (instancetype)initWithLanes:(NSArray<KKLane *> *)lanes
                        width:(CGFloat)width
                maxBodyHeight:(CGFloat)maxBodyHeight;

/// Set by the host so the list can resize the popover to the visible row count.
@property(nonatomic, weak, nullable) NSPopover *popover;

/// Subclass hook: configure a freshly-created row (`rowLabel` is already set)
/// for `lane` - its checked/warning state and toggle handlers. Default: no-op.
- (void)configureRow:(_KKManageRow *)row forLane:(KKLane *)lane;

/// Create a row (label + category + indent set) and register it with the stack
/// + filtering. The subclass sets its checked state + handlers, then this adds
/// it. Returns the row. `categoryKey` decides which category page it shows on.
/// Used both by the default flat rebuild and by subclasses that build their own
/// rows (e.g. the modulation checklist's master + indented component rows).
- (_KKManageRow *)appendRowWithLabel:(NSString *)label
                         categoryKey:(nullable NSString *)categoryKey
                         indentLevel:(NSInteger)indentLevel;

/// Clear the row stack (call at the start of a `-rebuildRows` override).
- (void)removeAllRows;

/// Re-run search/category filtering and resize to the visible row count
/// (popover or embedded height). Call at the end of a `-rebuildRows` override.
- (void)refilterAndResize;

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
