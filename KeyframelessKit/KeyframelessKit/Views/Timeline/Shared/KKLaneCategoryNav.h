/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKTimingStage.h>

@class KKPillToggleRowView;

NS_ASSUME_NONNULL_BEGIN

// Shared helpers for the property-category navigation that appears across the
// timeline UI (the value-editor popover, the Animated dropdown, the Parameter
// Order list, and the lane-filter bar). A "category" groups a plugin's lanes
// (e.g. Glow's Core and Noise) so the UI can split them into pages/capsules.

/// Ordered, first-seen distinct categories as `@[categoryKey, categorySymbol]`
/// pairs (lanes with no categoryKey are skipped). Empty when there are fewer
/// than two categories - the nav only appears when it actually splits the
/// params.
FOUNDATION_EXPORT NSArray<NSArray<NSString *> *> *
KKOrderedLaneCategories(NSArray<KKLane *> *lanes);

/// Just the ordered category keys (parallel to KKOrderedLaneCategories); empty
/// when there are fewer than two categories.
FOUNDATION_EXPORT NSArray<NSString *> *
KKLaneCategoryKeys(NSArray<KKLane *> *lanes);

/// Map of lane label → categoryKey, for lanes that declare one.
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *
KKLaneCategoryByLabel(NSArray<KKLane *> *lanes);

/// The category to start on: `requested` when it's one of the lanes'
/// categories, otherwise the first; nil when there are fewer than two
/// categories (no nav).
FOUNDATION_EXPORT NSString *_Nullable KKResolveLaneCategory(
    NSArray<KKLane *> *lanes, NSString *_Nullable requested);

/// SF Symbol image for a category symbol, with a fixed-size transparent
/// placeholder when the symbol is unavailable.
FOUNDATION_EXPORT NSImage *
KKCategorySymbolImage(NSString *symbolName,
                      NSString *_Nullable accessibilityKey);

/// A grouped, radio-mode `KKPillToggleRowView` of the lanes' categories (each
/// pill = icon + localized category name), with `selected` pre-highlighted.
/// `onSelect` fires with the picked category key. Returns nil when there are
/// fewer than two categories. The caller owns layout (constraints).
FOUNDATION_EXPORT KKPillToggleRowView *_Nullable KKMakeLaneCategoryPill(
    NSArray<KKLane *> *lanes, NSString *_Nullable selected,
    void (^onSelect)(NSString *categoryKey));

NS_ASSUME_NONNULL_END
