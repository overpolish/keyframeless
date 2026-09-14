/*
 * SPDX-FileCopyrightText: 2026 overpolish
 * SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0
 */

#pragma once

#import <AppKit/AppKit.h>
#import <KeyframelessKit/KKTimeline.h>

@class KKPillToggleRowView;

NS_ASSUME_NONNULL_BEGIN

// Shared helpers for the property-category navigation that appears across the
// timeline UI (the value-editor popover, the Animated dropdown, the Parameter
// Order list, and the lane-filter bar). A "category" groups a plugin's lanes
// (e.g. `Core` and `Noise`) so the UI can split them into pages/capsules.

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

/// Ordered, first-seen distinct `layerKey`s (lanes carrying none are skipped).
/// Empty for a single-owner plugin, whose lanes declare no layer at all - which
/// is also how a caller tests for the owner nav: it is only worth showing at
/// TWO or more, since one owner is just today's flat list.
FOUNDATION_EXPORT NSArray<NSString *> *
KKLaneLayerKeys(NSArray<KKLane *> *lanes);

/// The layerKeys that have a keypose at `fraction` - the owners a keypose
/// popover opened there can actually edit. `fraction` is SNAPPED to the nearest
/// real keypose time first: a Basic out-end boundary is edge-parked at 1.0
/// while its keypose sits short of the edge, so an exact match would find
/// nothing on any owner. Empty when no lane carries a layerKey (single-owner
/// plugins have no owner to gate).
///
/// The gate a host applies to its own owner switcher (Canvas grays the layer
/// list rows, Mirage the rack boxes) so an owner with nothing at this time
/// can't be selected into an empty editor.
FOUNDATION_EXPORT NSSet<NSString *> *
KKLaneLayerKeysWithKeyposeNearFraction(NSArray<KKLane *> *lanes,
                                       double fraction);

/// Map of layerKey → display name (the first non-empty `layerLabel` wins, the
/// key itself as fallback). Not run through `KKTruncatedLayerName` - callers
/// that show it in a pill do that themselves.
FOUNDATION_EXPORT NSDictionary<NSString *, NSString *> *
KKLaneLayerNames(NSArray<KKLane *> *lanes);

/// A grouped, radio-mode `KKPillToggleRowView` of the lanes' owners, one pill
/// per layer and NO "all owners" segment - a rack entry's / layer's parameter
/// list only means anything per owner. `selected` (an unknown key, or nil)
/// falls back to the first layer. Returns nil below two distinct owners.
/// `onSelect` fires with the picked layerKey. The caller owns layout.
FOUNDATION_EXPORT KKPillToggleRowView *_Nullable KKMakeLaneLayerPill(
    NSArray<KKLane *> *lanes, NSString *_Nullable selected,
    void (^onSelect)(NSString *layerKey));

/// A compact hierarchical summary of `lanes` for a dropdown field:
///  - no groups: `Position, Scale`
///  - categories: `Core > Glow, Radius | Noise > Amount`
///  - layers: `Layer 1 > Core > … | Layer 2 > …`
/// Layers are joined by " | ", category groups within a layer by ", ", and leaf
/// params by ", ". Returns an empty string when `lanes` is empty (the caller
/// supplies its own placeholder). Localizes param/category names; layer names
/// run through `KKTruncatedLayerName`.
FOUNDATION_EXPORT NSString *KKHierarchicalLaneSummary(NSArray<KKLane *> *lanes);

NS_ASSUME_NONNULL_END
